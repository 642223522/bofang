import Foundation

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

    /// 脱敏路径：去 query/fragment，并将疑似 token/签名的超长段（>=24 字符）替换成 <id>。
    static func sanitizePath(from url: URL?) -> String {
        guard let url else { return "/" }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
            let s = String(seg)
            if s.count >= 24 && !s.contains(".") {
                return "<tok>"
            }
            return s
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
    nonisolated static func makeEvent(
        source: String,
        request: URLRequest,
        response: URLResponse?,
        bodyData: Data?,
        error: Error?,
        metrics: URLSessionTaskMetrics?,
        fallbackDurationMs: Int
    ) -> NetworkDiagEvent {
        let tx = metrics?.transactionMetrics.last
        let http = (response as? HTTPURLResponse) ?? (tx?.response as? HTTPURLResponse)
        let statusCode = http?.statusCode

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
            host: request.url?.host ?? "",
            sanitizedPath: NetworkDiagEvent.sanitizePath(from: request.url),
            networkClass: PlaybackLedger.networkClass,
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
                case .timedOut, .networkConnectionLost, .notConnectedToInternet:
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
        // DNS 开始了但没结束，或还没进 TCP connect
        if tx.domainLookupStartDate != nil && tx.domainLookupEndDate == nil {
            return (.dns, "DNS 解析超时/失败 [\(code)]")
        }
        // DNS 已结束，TCP 没建起来（常见于 DNS 污染到黑洞 IP 或 IP 封锁）
        if tx.connectStartDate != nil && tx.connectEndDate == nil && tx.secureConnectionStartDate == nil {
            let ip = tx.remoteAddress ?? "?"
            return (.tcp, "TCP 建连超时/失败 (IP: \(ip)) [\(code)]")
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
        // DNS 都没开始就失败（如离线/代理不可达）
        if tx.domainLookupStartDate == nil && tx.connectStartDate == nil {
            return (.dns, "未完成解析或网络不可达 [\(code)]")
        }
        return (.http, "传输中断 [\(code)] \(description)")
    }

    private nonisolated static func isWAFResponse(http: HTTPURLResponse, bodyData: Data?) -> Bool {
        let cfMitigated = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() ?? ""
        if cfMitigated.contains("challenge") { return true }

        let server = http.value(forHTTPHeaderField: "server")?.lowercased() ?? ""
        let status = http.statusCode
        let snippet: String = {
            guard let bodyData, !bodyData.isEmpty else { return "" }
            return String(decoding: bodyData.prefix(4096), as: UTF8.self).lowercased()
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
        if wafMarkers.contains(where: { snippet.contains($0) }) {
            return true
        }
        if (status == 403 || status == 429 || status == 503),
           (server.contains("cloudflare") || server.contains("ddos-guard") || server.contains("sucuri")),
           snippet.contains("<html") {
            return true
        }
        return false
    }
}

/// 专用 HTTP 客户端：
/// - 独立 ephemeral 会话（不污染 URLSession.shared，也不跨重启保留陈旧的 WAF 坏 Cookie）；
/// - 禁用盲目 HTTP/3 (QUIC)，规避无节点网络下 UDP 443 丢包/黑洞；
/// - 跨域 301/302 重定向保留 Referer / UA / 模块自定义头（Authorization 仅同源保留）；
/// - 每次请求采集 URLSessionTaskMetrics，自动记入 NetworkDiagnostics；
/// - 随 Swift Task 取消立即取消底层 URLSessionTask，不滞留连接池。
final class DiagnosticHTTPClient: @unchecked Sendable {
    static let shared = DiagnosticHTTPClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
    }

    /// 发请求并采集 URLSessionTaskMetrics。
    /// timeout：单次请求超时（秒，默认 12s，钳制在 3...30s，避免单个被墙镜像卡死 30s 导致回退镜像跑不到）。
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

        let delegate = PerRequestDelegate(
            originHost: request.url?.host?.lowercased(),
            preservedHeaders: preservedHeaders
        )
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let event = NetworkDiagnostics.makeEvent(
                source: source,
                request: request,
                response: response,
                bodyData: data,
                error: nil,
                metrics: delegate.takeMetrics(),
                fallbackDurationMs: elapsedMs
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
                metrics: delegate.takeMetrics(),
                fallbackDurationMs: elapsedMs
            )
            NetworkDiagnostics.record(event)
            throw error
        }
    }
}

private final class PerRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originHost: String?
    private let preservedHeaders: [String: String]
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    init(originHost: String?, preservedHeaders: [String: String]) {
        self.originHost = originHost
        self.preservedHeaders = preservedHeaders
    }

    func takeMetrics() -> URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return metrics
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
        let newHost = redirected.url?.host?.lowercased()
        let sameOrigin = (originHost != nil && originHost == newHost)
        for (key, value) in preservedHeaders {
            let lower = key.lowercased()
            if lower == "authorization" && !sameOrigin { continue }
            if lower == "host" || lower == "content-length" { continue }
            if redirected.value(forHTTPHeaderField: key) == nil {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirected)
    }
}
