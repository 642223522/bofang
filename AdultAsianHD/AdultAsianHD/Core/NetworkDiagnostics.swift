import Foundation
import Network

/// 单次网络请求的死因/结果分层：区分 DNS / TCP / TLS / HTTP / WAF，定位真机无节点失败点。
enum NetworkDiagPhase: String, Codable, Sendable {
    case ok
    case dns
    case tcp
    case tls
    case http
    case waf
    case cancelled
    case unknown

    var label: String {
        switch self {
        case .ok: return "正常"
        case .dns: return "DNS 失败"
        case .tcp: return "TCP 连接失败"
        case .tls: return "TLS/SNI 握手失败"
        case .http: return "HTTP 响应异常/超时"
        case .waf: return "WAF/CF 挑战拦截"
        case .cancelled: return "已取消"
        case .unknown: return "未知网络错误"
        }
    }
}

/// 一条隐私安全的网络诊断事件（只存 host + 脱敏路径，不存 query/token/Cookie）。
struct NetworkDiagEvent: Identifiable, Codable, Sendable {
    let id: UUID
    let at: Date
    /// 发起方：widget / wp-direct / selfcheck / hlsloader / proxy
    let source: String
    let method: String
    let host: String
    /// 重定向前的原始 host（与 host 不同时才有值；同 host 时为 nil）。
    /// host/path 一律按最终重定向落点记，原始 host 只留作对照。
    let originalHost: String? = nil
    let sanitizedPath: String
    /// direct / proxy（发起时的网络类）
    let networkClass: String
    let phase: NetworkDiagPhase
    let statusCode: Int?
    let errorDomain: String?
    let errorCode: Int?
    let errorSummary: String?
    let remoteAddress: String?
    let protocolName: String?
    let reusedConnection: Bool
    let proxyConnection: Bool
    let dnsMs: Int?
    let tcpMs: Int?
    let tlsMs: Int?
    let ttfbMs: Int?
    let totalMs: Int

    var timingSummary: String {
        var parts: [String] = []
        if let dnsMs { parts.append("DNS \(dnsMs)ms") }
        if let tcpMs { parts.append("TCP \(tcpMs)ms") }
        if let tlsMs { parts.append("TLS \(tlsMs)ms") }
        if let ttfbMs { parts.append("TTFB \(ttfbMs)ms") }
        parts.append("总 \(totalMs)ms")
        return parts.joined(separator: " · ")
    }

    /// 脱敏路径：去 query/fragment，并将疑似 token/签名的超长段（>=24 字符）替换成 <tok>。
    /// 含点号的段也脱敏：视频 CDN 常把长签名放文件名里（<64hex>.m3u8、<token>.m4s）
    /// 或 JWT 段（eyJ….eyJ….sig）里，旧逻辑见点就放过，等于把签名原样传上去了。
    static func sanitizePath(from url: URL?) -> String {
        guard let url else { return "/" }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
            let s = String(seg)
            guard s.count >= 24 else { return s }
            // 带扩展名的长签名文件名：<64hex>.m3u8 → <tok>.m3u8（扩展名保留，签名值不留）
            if let dot = s.lastIndex(of: ".") {
                let stem = String(s[..<dot])
                let ext = String(s[s.index(after: dot)...])
                if stem.count >= 24 && ext.count <= 8 {
                    return "<tok>.\(ext)"
                }
            }
            // JWT 段与其他超长段：一律 <tok>
            return "<tok>"
        }
        let joined = parts.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }
}

/// 全局网络诊断缓冲（最近 80 条），供 DiagnosticsView 展示，并随 PlaybackLedger.snapshotJSON() 上传。
@MainActor
final class NetworkDiagnostics: ObservableObject {
    static let shared = NetworkDiagnostics()
    static let maxEvents = 80

    @Published private(set) var events: [NetworkDiagEvent] = []

    private init() {}

    nonisolated static func record(_ event: NetworkDiagEvent) {
        Task { @MainActor in
            let store = NetworkDiagnostics.shared
            store.events.insert(event, at: 0)
            if store.events.count > Self.maxEvents {
                store.events.removeLast()
            }
        }
    }

    func clear() {
        events.removeAll()
    }

    /// 根据 URLSessionTaskMetrics + HTTPURLResponse + body 前缀 + Error 判定精确死在哪一层。
    /// networkClass：调用方在请求开始时抓的值（不传则现测）；交易实际走了代理时以 tx 为准。
    nonisolated static func makeEvent(
        source: String,
        request: URLRequest,
        response: URLResponse?,
        bodyData: Data?,
        error: Error?,
        metrics: URLSessionTaskMetrics?,
        fallbackDurationMs: Int,
        networkClass: String? = nil
    ) -> NetworkDiagEvent {
        let tx = metrics?.transactionMetrics.last
        let http = (response as? HTTPURLResponse) ?? (tx?.response as? HTTPURLResponse)
        let statusCode = http?.statusCode
        // 重定向时 host/path 按最终落点记（tx 是最后一跳），原始 host 另存 originalHost。
        let finalURL = tx?.request.url ?? request.url
        let originalHost: String? = {
            let o = request.url?.host, f = finalURL?.host
            return (o != nil && o != f) ? o : nil
        }()
        // 交易实际走了代理连接时，网络类以 tx 为准（开始时抓的可能已过时）。
        let resolvedNetworkClass = (tx?.isProxyConnection == true) ? "proxy" : (networkClass ?? PlaybackLedger.networkClass)

        func ms(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return max(0, Int(end.timeIntervalSince(start) * 1000))
        }

        let dnsMs = ms(tx?.domainLookupStartDate, tx?.domainLookupEndDate)
        let tcpEnd = tx?.secureConnectionStartDate ?? tx?.connectEndDate
        let tcpMs = ms(tx?.connectStartDate, tcpEnd)
        let tlsMs = ms(tx?.secureConnectionStartDate, tx?.secureConnectionEndDate)
        let ttfbMs = ms(tx?.requestStartDate, tx?.responseStartDate)
        let totalMs: Int = {
            if let interval = metrics?.taskInterval {
                return max(0, Int(interval.duration * 1000))
            }
            return max(0, fallbackDurationMs)
        }()

        let (phase, summary) = classify(
            tx: tx,
            http: http,
            bodyData: bodyData,
            error: error
        )
        let nsError = error as NSError?
        return NetworkDiagEvent(
            id: UUID(),
            at: Date(),
            source: source,
            method: request.httpMethod ?? "GET",
            host: finalURL?.host ?? "",
            originalHost: originalHost,
            sanitizedPath: NetworkDiagEvent.sanitizePath(from: finalURL),
            networkClass: resolvedNetworkClass,
            phase: phase,
            statusCode: statusCode,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            errorSummary: summary,
            remoteAddress: tx?.remoteAddress,
            protocolName: tx?.networkProtocolName,
            reusedConnection: tx?.isReusedConnection ?? false,
            proxyConnection: tx?.isProxyConnection ?? false,
            dnsMs: dnsMs,
            tcpMs: tcpMs,
            tlsMs: tlsMs,
            ttfbMs: ttfbMs,
            totalMs: totalMs
        )
    }

    private nonisolated static func classify(
        tx: URLSessionTaskTransactionMetrics?,
        http: HTTPURLResponse?,
        bodyData: Data?,
        error: Error?
    ) -> (NetworkDiagPhase, String?) {
        if let error {
            let nsErr = error as NSError
            if let urlErr = error as? URLError {
                switch urlErr.code {
                case .cancelled:
                    return (.cancelled, "请求被取消")
                case .cannotFindHost, .dnsLookupFailed:
                    return (.dns, "域名解析失败 (\(urlErr.code.rawValue))")
                case .secureConnectionFailed,
                     .serverCertificateHasBadDate,
                     .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateNotYetValid,
                     .clientCertificateRejected,
                     .clientCertificateRequired,
                     .appTransportSecurityRequiresSecureConnection:
                    return (.tls, "TLS 握手失败 (\(urlErr.code.rawValue))")
                case .cannotConnectToHost:
                    return (.tcp, "TCP 连接被拒或不可达 (\(urlErr.code.rawValue))")
                case .notConnectedToInternet:
                    // 离线不是 DNS 失败：以前走 inferPhaseFromMetrics 会被误判成 .dns。
                    return (.unknown, "设备离线/无网络连接 (\(urlErr.code.rawValue))")
                case .timedOut, .networkConnectionLost:
                    return inferPhaseFromMetrics(tx: tx, code: urlErr.code.rawValue, description: urlErr.localizedDescription)
                default:
                    return inferPhaseFromMetrics(tx: tx, code: urlErr.code.rawValue, description: urlErr.localizedDescription)
                }
            }
            return inferPhaseFromMetrics(tx: tx, code: nsErr.code, description: nsErr.localizedDescription)
        }

        if let http {
            if isWAFResponse(http: http, bodyData: bodyData) {
                return (.waf, "HTTP \(http.statusCode)（疑似 Cloudflare/WAF 挑战）")
            }
            if (200...299).contains(http.statusCode) {
                return (.ok, nil)
            }
            return (.http, "HTTP \(http.statusCode)")
        }

        return (.unknown, "无 HTTP 响应")
    }

    private nonisolated static func inferPhaseFromMetrics(
        tx: URLSessionTaskTransactionMetrics?,
        code: Int,
        description: String
    ) -> (NetworkDiagPhase, String) {
        guard let tx else {
            return (.unknown, "[\(code)] \(description)")
        }
        // DNS 开始了但没结束
        if tx.domainLookupStartDate != nil && tx.domainLookupEndDate == nil {
            return (.dns, "DNS 解析超时/失败 [\(code)]")
        }
        // DNS 已完成，TCP 还没开始（解析出的 IP 不可路由、代理连不上）：
        // 旧逻辑这里全部分支都落空，最后掉进 .http，明明 TCP 从未建立却报 HTTP 失败。
        if tx.domainLookupEndDate != nil && tx.connectStartDate == nil {
            let ip = tx.remoteAddress ?? "?"
            return (.tcp, "DNS 已解析但 TCP 未发起 (IP: \(ip)) [\(code)]")
        }
        // TCP 开始了但没建起来（常见于 DNS 污染到黑洞 IP 或 IP 封锁）
        if tx.connectStartDate != nil && tx.connectEndDate == nil && tx.secureConnectionStartDate == nil {
            let ip = tx.remoteAddress ?? "?"
            return (.tcp, "TCP 建连超时/失败 (IP: \(ip)) [\(code)]")
        }
        // TCP 已建立，TLS 还没开始（对端在 secureConnectionStartDate 被记录前就重置了）
        if tx.connectEndDate != nil && tx.secureConnectionStartDate == nil && tx.requestStartDate == nil {
            let ip = tx.remoteAddress ?? "?"
            return (.tls, "TCP 已连上但 TLS 未开始/被重置 (IP: \(ip)) [\(code)]")
        }
        // TLS 开始了但没完成（常见于 SNI 阻断 / RST）
        if tx.secureConnectionStartDate != nil && tx.secureConnectionEndDate == nil {
            let ip = tx.remoteAddress ?? "?"
            return (.tls, "TLS/SNI 握手中断或超时 (IP: \(ip)) [\(code)]")
        }
        // TLS 完成了、请求已发，但未收到响应头（服务端丢包/慢响应/WAF 静默丢弃）
        if tx.requestStartDate != nil && tx.responseStartDate == nil {
            return (.http, "等待首字节超时/连接重置 [\(code)]")
        }
        // 什么都没启动就失败（如离线/代理不可达）：不判 DNS，判未知。
        if tx.domainLookupStartDate == nil && tx.connectStartDate == nil {
            return (.unknown, "未启动解析/建连，可能离线或代理不可达 [\(code)]")
        }
        return (.http, "传输中断 [\(code)] \(description)")
    }

    private nonisolated static func isWAFResponse(http: HTTPURLResponse, bodyData: Data?) -> Bool {
        let cfMitigated = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() ?? ""
        if cfMitigated.contains("challenge") { return true }

        let server = http.value(forHTTPHeaderField: "server")?.lowercased() ?? ""
        let status = http.statusCode
        let contentType = http.value(forHTTPHeaderField: "content-type")?.lowercased() ?? ""
        // 200 JSON 正常响应不扫特征词：视频标题/描述里提到 ddos-guard 也不算 WAF。
        let isJSON = contentType.contains("application/json") || contentType.contains("text/json")
        if isJSON && (200...299).contains(status) { return false }

        // 403/429/503 + Cloudflare/DDoS-Guard 服务端头即判 WAF（body 为 nil 时也不漏报）。
        if (status == 403 || status == 429 || status == 503),
           server.contains("cloudflare") || server.contains("ddos-guard") || server.contains("sucuri") {
            return true
        }

        let snippet: String = {
            guard let bodyData, !bodyData.isEmpty else { return "" }
            // 前 16KB：挑战页在挑战片段前常有超过 4KB 的内联 CSS/meta，4KB 不够。
            return String(decoding: bodyData.prefix(16384), as: UTF8.self).lowercased()
        }()

        let wafMarkers = [
            "just a moment...",
            "cf-browser-verification",
            "challenge-platform",
            "checking your browser",
            "attention required! | cloudflare",
            "ddos-guard",
            "enable javascript and cookies to continue"
        ]
        // 特征词只在非 2xx 响应上扫：2xx 的正常页面（哪怕提到挑战字样）也不判 WAF。
        if !(200...299).contains(status), wafMarkers.contains(where: { snippet.contains($0) }) {
            return true
        }
        return false
    }
}

/// 专用 HTTP 客户端：
/// - 独立 ephemeral 会话（不污染 URLSession.shared，也不跨重启保留陈旧的 WAF 坏 Cookie）；
/// - 禁用盲目 HTTP/3 (QUIC)，规避无节点网络下 UDP 443 丢包/黑洞；
/// - 跨域 301/302 重定向保留 Referer / UA / 模块自定义头（凭据头仅同源保留）；
/// - 每次请求采集 URLSessionTaskMetrics，自动记入 NetworkDiagnostics；
/// - 随 Swift Task 取消立即取消底层 URLSessionTask，不滞留连接池。
final class DiagnosticHTTPClient: @unchecked Sendable {
    static let shared = DiagnosticHTTPClient()

    private let session: URLSession
    /// 网络切换监听：接口变了（Wi-Fi↔蜂窝、VPN 开关）就清 Cookie，
    /// 直连时沾上的 WAF 坏 Cookie 不许带到 VPN 后。
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.netdiag.path")
    private var lastPathSignature = ""

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        // 资源超时是最后防线（30s）；真正的总预算由 data() 里的 deadline 赛跑管，
        // 不再让 request.timeoutInterval（字节间空闲定时器）冒充总超时。
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = "wifi=\(path.usesInterfaceType(.wifi))|cell=\(path.usesInterfaceType(.cellular))|wired=\(path.usesInterfaceType(.wiredEthernet))|other=\(path.usesInterfaceType(.other))|ok=\(path.status == .satisfied)"
            if self.lastPathSignature.isEmpty {
                self.lastPathSignature = signature
                return
            }
            if signature != self.lastPathSignature {
                self.lastPathSignature = signature
                self.resetCookies()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// 清掉会话的 Cookie（网络切换后调；也可以手动调）。
    func resetCookies() {
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    /// 发请求并采集 URLSessionTaskMetrics。
    /// timeout：单次请求总超时（秒，默认 12s，钳制在 3...30s）——这是真正的总预算，
    /// 用 deadline 任务赛跑实现；request.timeoutInterval 只作字节间空闲定时器，
    /// 慢速滴漏（tarpit）再也拖不到 25s。
    func data(
        for rawRequest: URLRequest,
        source: String,
        preservedHeaders: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> (Data, URLResponse) {
        var request = rawRequest
        request.assumesHTTP3Capable = false
        request.allowsExpensiveNetworkAccess = true
        request.allowsConstrainedNetworkAccess = true
        if let timeout {
            request.timeoutInterval = min(max(timeout, 3), 30)
        } else if request.timeoutInterval <= 0 || request.timeoutInterval >= 60 {
            request.timeoutInterval = 12
        }
        let totalDeadline = timeout ?? 12

        let delegate = PerRequestDelegate(
            originURL: request.url,
            preservedHeaders: preservedHeaders
        )
        let started = Date()
        // 网络类在请求开始时抓（完成时再读可能已经换网了）。
        let networkClassAtStart = PlaybackLedger.networkClass
        do {
            let (data, response): (Data, URLResponse) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await self.session.data(for: request, delegate: delegate) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(totalDeadline * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                guard let first = try await group.next() else { throw URLError(.timedOut) }
                group.cancelAll()
                return first
            }
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let event = NetworkDiagnostics.makeEvent(
                source: source,
                request: request,
                response: response,
                bodyData: data,
                error: nil,
                metrics: await delegate.takeMetricsSoon(),
                fallbackDurationMs: elapsedMs,
                networkClass: networkClassAtStart
            )
            NetworkDiagnostics.record(event)
            return (data, response)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let event = NetworkDiagnostics.makeEvent(
                source: source,
                request: request,
                response: nil,
                bodyData: nil,
                error: error,
                metrics: await delegate.takeMetricsSoon(),
                fallbackDurationMs: elapsedMs,
                networkClass: networkClassAtStart
            )
            NetworkDiagnostics.record(event)
            throw error
        }
    }
}

private final class PerRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originURL: URL?
    private let preservedHeaders: [String: String]
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    init(originURL: URL?, preservedHeaders: [String: String]) {
        self.originURL = originURL
        self.preservedHeaders = preservedHeaders
    }

    func takeMetrics() -> URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    /// 取消/超时时 didFinishCollecting 可能还没跑：用脱离取消上下文的 detached 任务
    /// 等一小会儿（最多 ~300ms），把超时请求的 DNS/TCP/TLS 停滞指标也拿回来；
    /// 已有 metrics 时立即返回，不多等。
    func takeMetricsSoon() async -> URLSessionTaskMetrics? {
        if let m = takeMetrics() { return m }
        return await Task.detached { [weak self] in
            guard let self else { return nil }
            for _ in 0..<12 {
                if let m = self.takeMetrics() { return m }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return self.takeMetrics()
        }.value
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        redirected.assumesHTTP3Capable = false
        // 同源 = scheme + host + 端口全同：跨域或 HTTPS→HTTP 降级时，
        // Authorization / Cookie / API key 一律不跟过去（旧逻辑只比 host，
        // 降级时 Authorization 会明文泄漏，Cookie 会原样发去外国域名）。
        let sameOrigin = NetConstants.isSameOrigin(originURL, redirected.url)
        for (key, value) in preservedHeaders {
            let lower = key.lowercased()
            if !sameOrigin && NetConstants.isSensitiveHeader(key) { continue }
            if lower == "host" || lower == "content-length" { continue }
            if redirected.value(forHTTPHeaderField: key) == nil {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirected)
    }
}
