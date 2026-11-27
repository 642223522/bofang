import Foundation
import Network
import CFNetwork

/// 单次网络请求的死因/结果分层：区分 DNS / TCP / TLS / HTTP / WAF，定位真机无节点失败点。
/// 404 归 .http（"HTTP 响应异常"），超时归 .timeout，连接中途丢归 .transport——
/// 404 再也不会被写成“超时”，账本/检测页的死因才对得上。
enum NetworkDiagPhase: String, Codable, Sendable {
    case ok
    case dns
    case tcp
    case tls
    case http
    case timeout
    case transport
    case waf
    case cancelled
    case unknown

    var label: String {
        switch self {
        case .ok: return "正常"
        case .dns: return "DNS 失败"
        case .tcp: return "TCP 连接失败"
        case .tls: return "TLS/SNI 握手失败"
        case .http: return "HTTP 响应异常"
        case .timeout: return "请求超时"
        case .transport: return "传输层失败"
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
    /// 注意：声明上不带 = nil——let 在声明里给了初值就不能在 init 里再赋值
    ///（run #15 教训）；默认值放在下面显式 init 的参数上。
    let originalHost: String?
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

    /// 显式成员初始化器：新增带默认值的字段时，合成的 memberwise init
    /// 在本工程的 Swift 6 编译下不接受该字段的显式传参（run #14 构建报错
    /// extra argument 'originalHost'），写死一份最稳妥；originalHost 默认 nil，
    /// 不传它的旧调用点（WebViewPlayer）不受影响。
    init(
        id: UUID,
        at: Date,
        source: String,
        method: String,
        host: String,
        originalHost: String? = nil,
        sanitizedPath: String,
        networkClass: String,
        phase: NetworkDiagPhase,
        statusCode: Int?,
        errorDomain: String?,
        errorCode: Int?,
        errorSummary: String?,
        remoteAddress: String?,
        protocolName: String?,
        reusedConnection: Bool,
        proxyConnection: Bool,
        dnsMs: Int?,
        tcpMs: Int?,
        tlsMs: Int?,
        ttfbMs: Int?,
        totalMs: Int
    ) {
        self.id = id
        self.at = at
        self.source = source
        self.method = method
        self.host = host
        self.originalHost = originalHost
        self.sanitizedPath = sanitizedPath
        self.networkClass = networkClass
        self.phase = phase
        self.statusCode = statusCode
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorSummary = errorSummary
        self.remoteAddress = remoteAddress
        self.protocolName = protocolName
        self.reusedConnection = reusedConnection
        self.proxyConnection = proxyConnection
        self.dnsMs = dnsMs
        self.tcpMs = tcpMs
        self.tlsMs = tlsMs
        self.ttfbMs = ttfbMs
        self.totalMs = totalMs
    }

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
        // -1002 / code 1 的诊断补强：失败 URL（脱敏）+ 事务数 + 取指方式 +
        // 代理状态 + 错误链，写进 summary 供检测页查看（不新增事件字段，
        // run #14 教训：NetworkDiagEvent 的显式 init 不接受新字段的旧调用点）。
        let enrichedSummary: String? = {
            guard let error else { return summary }
            let nsErr = error as NSError
            let needsDetail = (nsErr.domain == NSURLErrorDomain && nsErr.code == URLError.unsupportedURL.rawValue)
                || nsErr.code == 1
            guard needsDetail else { return summary }
            var parts: [String] = []
            if let failing = nsErr.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
               let failingURL = URL(string: failing) {
                parts.append("fail=\(failingURL.host ?? "?")\(NetworkDiagEvent.sanitizePath(from: failingURL))")
            }
            let txs = metrics?.transactionMetrics ?? []
            parts.append("tx=\(txs.count)")
            if let fetchType = txs.last?.resourceFetchType {
                parts.append("fetch=\(fetchType)")
            }
            parts.append("proxy=\(ActiveSystemProxy.current().label)")
            let chain = DiagnosticHTTPClient.underlyingErrorChain(nsErr)
                .prefix(3)
                .map { "\($0.domain):\($0.code)" }
                .joined(separator: ",")
            parts.append("chain=[\(chain)]")
            let detail = parts.joined(separator: " ")
            if let summary, !summary.isEmpty {
                return "\(summary) | \(detail)"
            }
            return detail
        }()
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
            errorSummary: enrichedSummary,
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
            // 连 metrics 都没有：按错误码分——超时就是超时，连接丢失就是传输层失败，
            // 不再一律判未知/HTTP。
            if code == URLError.timedOut.rawValue {
                return (.timeout, "请求超时 [\(code)] \(description)")
            }
            if code == URLError.networkConnectionLost.rawValue {
                return (.transport, "连接丢失 [\(code)] \(description)")
            }
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
            if code == URLError.timedOut.rawValue {
                return (.timeout, "等待首字节超时 [\(code)]")
            }
            return (.transport, "等待首字节时连接重置 [\(code)]")
        }
        // 什么都没启动就失败（如离线/代理不可达）：不判 DNS，判未知。
        if tx.domainLookupStartDate == nil && tx.connectStartDate == nil {
            return (.unknown, "未启动解析/建连，可能离线或代理不可达 [\(code)]")
        }
        return (.transport, "传输中断 [\(code)] \(description)")
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

    /// 会话配置工厂：每次轮换都用同一份配置。
    /// urlCache = nil：.ephemeral 仍带内存 URLCache，会 0ms 命中缓存的
    /// 301/302 重定向（坏 Location 直接报 -1002）与旧 HLS 播单；我们不要任何缓存。
    private static func makeSessionConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        // 资源超时是最后防线（30s）；真正的总预算由 data() 里的 deadline 赛跑管，
        // 不再让 request.timeoutInterval（字节间空闲定时器）冒充总超时。
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 8
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        return config
    }

    private var session: URLSession
    private let sessionLock = NSLock()
    /// 上次建会话时的代理状态：代理开关 NWPathMonitor 捕捉不到，currentSession()
    /// 前的检查是兜底（隧道内换节点不触发 path 回调，靠失败重试兜底）。
    private var lastProxyState: ActiveSystemProxy
    /// 网络世代：切网/代理变化时 +1，熔断器按世代清零（旧网的失败不污染新网）。
    private var networkEpoch: UInt64 = 0
    /// 传输熔断器：host → （跳闸世代，强制走 NWConnection 到期时间）。
    private var breaker: [String: (epoch: UInt64, until: Date)] = [:]
    /// 模块声明的强制传输 host（由各模块的 WidgetMetadata.forceTransportHosts
    /// 登记，宿主代码里不硬编码任何 host）。注册是累加的、去重的；应用重启
    /// 后清空，各源首次使用时重新登记。删源/改声明后的旧条目无害（强制 TCP
    /// 本来就是合法传输，只是少走 URLSession）。
    private var moduleForcedHosts: Set<String> = []
    /// 网络切换监听：接口变了（Wi-Fi↔蜂窝、VPN 开关）就清 Cookie，
    /// 直连时沾上的 WAF 坏 Cookie 不许带到 VPN 后。
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.netdiag.path")
    private var lastPathSignature = ""

    private init() {
        self.session = URLSession(configuration: Self.makeSessionConfig())
        self.lastProxyState = ActiveSystemProxy.current()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = "wifi=\(path.usesInterfaceType(.wifi))|cell=\(path.usesInterfaceType(.cellular))|wired=\(path.usesInterfaceType(.wiredEthernet))|other=\(path.usesInterfaceType(.other))|ok=\(path.status == .satisfied)"
            if self.lastPathSignature.isEmpty {
                self.lastPathSignature = signature
                return
            }
            if signature != self.lastPathSignature {
                self.lastPathSignature = signature
                self.handleNetworkTransition()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// 网络切换：世代 +1、熔断器清零、DoH 缓存清、会话轮换、Cookie 清。
    /// 注意：隧道内换节点不改变接口签名，不触发这里——那种残留死连接靠
    /// data() 里的复用重置重试（rotate + 重试一次）兜底。
    private func handleNetworkTransition() {
        sessionLock.lock()
        networkEpoch &+= 1
        breaker.removeAll()
        sessionLock.unlock()
        rotateSession()
        resetCookies()
        // 切网：DoH 解析出的 IP 与偏好表一起清空（新网络下
        // 旧 IP 可能不可达，下一请求重新解析）。
        DoHFallbackClient.shared.resetForNetworkChange()
    }

    /// 取当前会话：代理状态变了就轮换（代理开关不触发 path 回调）。
    /// 轮换是原子的：旧会话 finishTasksAndInvalidate()，在途任务跑完才释放；
    /// 并发请求不会互相打断。
    private func currentSession() -> URLSession {
        let nowProxy = ActiveSystemProxy.current()
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if nowProxy != lastProxyState {
            lastProxyState = nowProxy
            networkEpoch &+= 1
            breaker.removeAll()
            rotateSessionLocked()
        }
        return session
    }

    private func rotateSession() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        lastProxyState = ActiveSystemProxy.current()
        rotateSessionLocked()
    }

    private func rotateSessionLocked() {
        let old = session
        session = URLSession(configuration: Self.makeSessionConfig())
        old.finishTasksAndInvalidate()
    }

    /// 清掉会话的 Cookie（网络切换后调；也可以手动调）。
    func resetCookies() {
        sessionLock.lock()
        let s = session
        sessionLock.unlock()
        s.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
    }

    // MARK: - 严格 URL 校验与错误分类

    /// 严格 URL 校验（原生入口）：scheme 必须是 http/https、host 非空且不含
    /// 空白/换行/反斜杠、整个 URL 不含 ASCII 控制字符（≤0x20 或 0x7F）。
    /// iOS 17+ 的 URL(string:) 会接受 trim 后仍非法（如内部 \n、反斜杠、
    /// 空 host）的字符串，那些进 URLSession 是 0ms -1002；这里直接拒掉，
    /// 给出明确错误，不让它进诊断里冒充网络失败。
    static func isStrictlyValidHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\\" })
        else { return false }
        return !url.absoluteString.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F })
    }

    /// 递归拆 NSUnderlyingErrorKey 链（去重防环），顶层错误在第一位。
    static func underlyingErrorChain(_ error: NSError) -> [NSError] {
        var result: [NSError] = []
        var seen = Set<String>()
        var current: NSError? = error
        while let e = current {
            let key = "\(e.domain):\(e.code)"
            guard seen.insert(key).inserted else { break }
            result.append(e)
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    /// 登记模块声明的强制传输 host（WidgetHost 建好时调，幂等）。
    func registerForcedTransportHosts(_ hosts: [String]) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        for h in hosts {
            let clean = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty else { continue }
            moduleForcedHosts.insert(clean)
        }
    }

    /// 是否强制走 TCP/HTTP/1.1（模块声明的 host）：后缀匹配 + 精确边界。
    private func isForcedTransportHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return moduleForcedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 熔断器是否跳闸（同世代 + 未过期）。
    private func isBreakerTripped(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let entry = breaker[host], entry.epoch == networkEpoch else { return false }
        return entry.until > Date()
    }

    /// 跳闸：该 host 10 分钟内直降代理感知 NWConnection。
    private func tripBreaker(host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        breaker[host] = (epoch: networkEpoch, until: Date().addingTimeInterval(600))
    }

    /// kCFHostErrorHostNotFound 的数值（CFNetworkErrors：1 = DNS 解析失败）。
    /// iOS 27 SDK 里 CFHost.h 的符号已不在 Swift 可见范围（run #32 构建报错
    /// cannot find 'kCFHostErrorHostNotFound' in scope），只能用字面值；
    /// 两处调用都先判了域是 kCFErrorDomainCFNetwork，所以 1 不会跟别的域撞。
    private static let cfHostErrorHostNotFound = 1

    /// 传输兜底资格：域 + 码双查（顶层 + underlying 链）。
    /// 不进：-1002（URL/协议分发问题，见 -1002 守卫救援）、-999、CancellationError。
    /// 进：原 6 个 URLError、POSIX 54/53/60/61/1、kCFHostErrorHostNotFound
    ///（域必须是 kCFErrorDomainCFNetwork，数字 1 本身在不同域含义不同）。
    /// POSIX 61/1 只是有条件可恢复（本地代理拒绝 ≠ 源站拒绝）：这里先按“进”
    /// 处理，代理判定在调用方把关，直连被拒时原错返回。
    private func isTransportFallbackEligible(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let chain = Self.underlyingErrorChain(error as NSError)
        if chain.contains(where: {
            $0.domain == NSURLErrorDomain &&
            ($0.code == URLError.cancelled.rawValue || $0.code == URLError.unsupportedURL.rawValue)
        }) {
            return false
        }
        for e in chain {
            if e.domain == NSURLErrorDomain {
                switch e.code {
                case URLError.timedOut.rawValue, URLError.cannotFindHost.rawValue,
                     URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue,
                     URLError.dnsLookupFailed.rawValue, URLError.secureConnectionFailed.rawValue:
                    return true
                default:
                    break
                }
            }
            if e.domain == NSPOSIXErrorDomain {
                switch e.code {
                case Int(ECONNRESET), Int(ECONNABORTED), Int(ETIMEDOUT),
                     Int(ECONNREFUSED), Int(EPERM):
                    return true
                default:
                    break
                }
            }
            if e.code == Self.cfHostErrorHostNotFound,
               e.domain == (kCFErrorDomainCFNetwork as String) {
                return true
            }
        }
        return false
    }

    /// 残留死 socket 重置：复用连接 + 重置类错误（POSIX 54/53 或 -1005）。
    /// 隧道内换节点/代理切换后，旧池化连接就是这么死的；只轮换会话重试一次，
    /// 不跳闸熔断器（host 本身没坏）。
    private func isStaleSocketReset(error: Error, metrics: URLSessionTaskMetrics?) -> Bool {
        guard metrics?.transactionMetrics.last?.isReusedConnection == true else { return false }
        let chain = Self.underlyingErrorChain(error as NSError)
        return chain.contains { e in
            (e.domain == NSPOSIXErrorDomain && (e.code == Int(ECONNRESET) || e.code == Int(ECONNABORTED)))
            || (e.domain == NSURLErrorDomain && e.code == URLError.networkConnectionLost.rawValue)
        }
    }

    /// 该失败是否值得跳闸熔断器：h3 参与、EPERM、kCFHostErrorHostNotFound，
    /// 或非复用连接的重置类失败。复用重置已走 rotate + 重试，不到这里。
    private func shouldTripBreaker(error: Error, metrics: URLSessionTaskMetrics?) -> Bool {
        let txs = metrics?.transactionMetrics ?? []
        if txs.contains(where: { $0.networkProtocolName == "h3" }) { return true }
        let chain = Self.underlyingErrorChain(error as NSError)
        if chain.contains(where: { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EPERM) }) { return true }
        if chain.contains(where: {
            $0.domain == (kCFErrorDomainCFNetwork as String) && $0.code == Self.cfHostErrorHostNotFound
        }) { return true }
        let reused = txs.last?.isReusedConnection ?? false
        if !reused {
            return chain.contains { e in
                (e.domain == NSPOSIXErrorDomain && (e.code == Int(ECONNRESET) || e.code == Int(ECONNABORTED) || e.code == Int(ETIMEDOUT)))
                || (e.domain == NSURLErrorDomain && e.code == URLError.networkConnectionLost.rawValue)
            }
        }
        return false
    }

    /// -1002 守卫救援：URLSession 对通过严格校验的 URL 仍报 -1002（iOS 17
    /// CFURL 怪癖、损坏的内存缓存重定向、坏 PAC 等）时才救一次；非法 URL
    /// 早被入口校验拦下，绝不会走到这里。
    private func isStrict1002Rescue(error: Error, request: URLRequest) -> Bool {
        guard let url = request.url, Self.isStrictlyValidHTTPURL(url) else { return false }
        let chain = Self.underlyingErrorChain(error as NSError)
        return chain.contains { $0.domain == NSURLErrorDomain && $0.code == URLError.unsupportedURL.rawValue }
    }

    /// 发请求并采集 URLSessionTaskMetrics。
    /// timeout：单次请求总超时（秒，默认 12s，钳制在 3...30s）——这是真正的总预算，
    /// 用 deadline 任务赛跑实现；request.timeoutInterval 只作字节间空闲定时器，
    /// 慢速滴漏（tarpit）再也拖不到 25s。
    /// 路由顺序：严格校验 → 强制 host/熔断 host（代理感知 NWConnection，
    /// PAC-only 时回落 URLSession）→ DoH 偏好 host（仅无显式代理时）→
    /// URLSession（残留 socket 一次重试）→ 传输兜底 / -1002 守卫救援。
    func data(
        for rawRequest: URLRequest,
        source: String,
        preservedHeaders: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> (Data, URLResponse) {
        // 0. 严格 URL 校验（原生入口）：非法 URL 直接拒掉，不进 URLSession
        // 冒充 -1002 网络失败。
        guard let url = rawRequest.url, Self.isStrictlyValidHTTPURL(url) else {
            throw URLError(.badURL)
        }
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
        let proxy = ActiveSystemProxy.current()

        // 1. 强制 host（已知 URLSession 不可靠）与熔断 host：代理感知 NWConnection。
        // PAC-only 时 NWConnection 执行不了 JS PAC，回落系统 URLSession。
        // 只对 https（DoH 客户端只做 https；http 请求直接走 URLSession）。
        if url.scheme?.lowercased() == "https",
           isForcedTransportHost(url.host) || isBreakerTripped(host: url.host) {
            if !proxy.isPACOnly {
                return try await performViaProxyAwareTransport(
                    request: request,
                    source: source,
                    preservedHeaders: preservedHeaders,
                    timeout: totalDeadline,
                    proxy: proxy
                )
            }
        }

        // 2. DoH 偏好 host（之前走 DoH 成功过）：仅无显式代理时直连 DoH；
        // 代理开着时由代理做 DNS（远程解析本来就是干净的），走 URLSession。
        //（系统 DNS 给的是被污染的 Facebook IP，TCP 黑洞 12 秒。）
        if proxy == .none,
           DoHFallbackClient.shared.isDoHPreferred(for: url.host),
           url.scheme?.lowercased() == "https" {
            return try await performViaDoH(request: request, source: source, preservedHeaders: preservedHeaders, timeout: totalDeadline)
        }

        // 3. URLSession 尝试：残留 socket 一次重试 → 传输兜底 → -1002 守卫救援。
        let started = Date()
        // 网络类在请求开始时抓（完成时再读可能已经换网了）。
        let networkClassAtStart = PlaybackLedger.networkClass
        var attempt = 0
        while true {
            let delegate = PerRequestDelegate(
                originURL: request.url,
                preservedHeaders: preservedHeaders
            )
            let remaining = max(3, totalDeadline - Date().timeIntervalSince(started))
            do {
                let (data, response) = try await runURLSessionOnce(
                    request: request,
                    delegate: delegate,
                    timeout: remaining
                )
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
                let metrics = await delegate.takeMetricsSoon()
                let event = NetworkDiagnostics.makeEvent(
                    source: source,
                    request: request,
                    response: nil,
                    bodyData: nil,
                    error: error,
                    metrics: metrics,
                    fallbackDurationMs: elapsedMs,
                    networkClass: networkClassAtStart
                )
                NetworkDiagnostics.record(event)
                // 残留死 socket：轮换会话重试一次，不跳闸（host 本身没坏）。
                if attempt == 0, isStaleSocketReset(error: error, metrics: metrics) {
                    attempt += 1
                    rotateSession()
                    continue
                }
                // 系统 DNS/TCP/TLS/超时失败：传输兜底（只对 https + 有 host 的请求；
                // HTTP 4xx/5xx 是服务端正常响应，不进 catch；离线/证书信任失败/
                // 取消不走兜底，DoH 也救不了）。
                if url.scheme?.lowercased() == "https",
                   let host = url.host, !host.isEmpty,
                   isTransportFallbackEligible(error) {
                    if shouldTripBreaker(error: error, metrics: metrics) {
                        tripBreaker(host: host)
                    }
                    if !proxy.isPACOnly {
                        return try await performViaProxyAwareTransport(
                            request: request,
                            source: source,
                            preservedHeaders: preservedHeaders,
                            timeout: totalDeadline,
                            proxy: proxy
                        )
                    }
                    throw error
                }
                // -1002 守卫救援：通过严格校验的 URL 仍报 -1002，救一次，不跳闸。
                if isStrict1002Rescue(error: error, request: request), !proxy.isPACOnly {
                    return try await performViaProxyAwareTransport(
                        request: request,
                        source: source,
                        preservedHeaders: preservedHeaders,
                        timeout: totalDeadline,
                        proxy: proxy
                    )
                }
                throw error
            }
        }
    }

    /// 单次 URLSession 尝试：deadline 赛跑（Task 取消立即取消底层任务，不滞留连接池）。
    private func runURLSessionOnce(
        request: URLRequest,
        delegate: PerRequestDelegate,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let session = currentSession()
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request, delegate: delegate) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            group.cancelAll()
            return first
        }
    }

    /// 代理感知 NWConnection：无代理时走 DoH 直连；显式代理时经代理协议；
    /// PAC-only 不应调到这里（调用方已排除）。
    private func performViaProxyAwareTransport(
        request: URLRequest,
        source: String,
        preservedHeaders: [String: String],
        timeout: TimeInterval,
        proxy: ActiveSystemProxy
    ) async throws -> (Data, URLResponse) {
        switch proxy {
        case .none:
            return try await performViaDoH(request: request, source: source, preservedHeaders: preservedHeaders, timeout: timeout)
        case .http, .socks5:
            return try await performViaProxy(request: request, source: source, preservedHeaders: preservedHeaders, timeout: timeout, proxy: proxy)
        case .pacOnly:
            throw URLError(.unsupportedURL)
        }
    }

    /// 经 DoH 客户端发请求（直连 DoH 解析出的 IP）：成功记偏好，
    /// 失败记一条诊断事件后把错抛回调用方。
    private func performViaDoH(
        request: URLRequest,
        source: String,
        preservedHeaders: [String: String],
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let started = Date()
        let networkClassAtStart = PlaybackLedger.networkClass
        do {
            let (data, http, _) = try await DoHFallbackClient.shared.perform(
                request: request,
                preservedHeaders: preservedHeaders,
                timeout: timeout
            )
            recordTransportEvent(source: source, request: request, response: http, bodyData: data, error: nil, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            return (data, http)
        } catch {
            recordTransportEvent(source: source, request: request, response: nil, bodyData: nil, error: error, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            throw error
        }
    }

    /// 经系统代理发请求（DoH 客户端 + ProxyConfiguration）：代理负责 DNS + TCP，
    /// 成功不记 DoH 偏好（不是 DoH 的功劳），失败记一条诊断事件后把错抛回调用方。
    private func performViaProxy(
        request: URLRequest,
        source: String,
        preservedHeaders: [String: String],
        timeout: TimeInterval,
        proxy: ActiveSystemProxy
    ) async throws -> (Data, URLResponse) {
        let started = Date()
        let networkClassAtStart = PlaybackLedger.networkClass
        do {
            let (data, http, _) = try await DoHFallbackClient.shared.perform(
                request: request,
                preservedHeaders: preservedHeaders,
                timeout: timeout,
                viaProxy: proxy
            )
            recordTransportEvent(source: source, request: request, response: http, bodyData: data, error: nil, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            return (data, http)
        } catch {
            recordTransportEvent(source: source, request: request, response: nil, bodyData: nil, error: error, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            throw error
        }
    }

    /// 传输层（DoH/代理）尝试的诊断事件记录。
    private func recordTransportEvent(
        source: String,
        request: URLRequest,
        response: URLResponse?,
        bodyData: Data?,
        error: Error?,
        elapsedMs: Int,
        networkClass: String
    ) {
        let event = NetworkDiagnostics.makeEvent(
            source: source,
            request: request,
            response: response,
            bodyData: bodyData,
            error: error,
            metrics: nil,
            fallbackDurationMs: elapsedMs,
            networkClass: networkClass
        )
        NetworkDiagnostics.record(event)
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
        // 拒非 http(s) 重定向目标：直接交回 3xx 响应，别让 CFNetwork 对
        // javascript:/file:///intent: 之类报 -1002。
        guard let targetURL = request.url,
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.assumesHTTP3Capable = false
        // 同源 = scheme + host + 端口全同：跨域或 HTTPS→HTTP 降级时，
        // Authorization / Cookie / API key 一律不跟过去（旧逻辑只比 host，
        // 降级时 Authorization 会明文泄漏，Cookie 会原样发去外国域名）。
        let sameOrigin = NetConstants.isSameOrigin(originURL, redirected.url)
        for (key, value) in preservedHeaders {
            let lower = key.lowercased()
            if !sameOrigin && NetConstants.isSensitiveHeader(key) { continue }
            // Host/Content-Length 由 CFNetwork 自己管；跳步头（Connection/
            // Transfer-Encoding/Keep-Alive/Proxy-Connection/Upgrade）上 H2/H3
            // 会违反 RFC 9113/9114，直接 RST_STREAM。
            if lower == "host" || lower == "content-length" || lower == "connection"
                || lower == "transfer-encoding" || lower == "keep-alive"
                || lower == "proxy-connection" || lower == "upgrade" { continue }
            if redirected.value(forHTTPHeaderField: key) == nil {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        completionHandler(redirected)
    }
}

// MARK: - WordPress 请求层（run #20：B 查询 + 挑战检测 + 单次可控重试 + 请求合并）

/// WordPress API 请求的错误：挑战（Cloudflare）与断路器打开。
/// 结构不兼容（B 查询不被支持）不抛错——调用方在拿到响应后用
/// WPQueryOptimizer.isStructuralFailure 判定并一次性回退原查询。
enum WordPressHTTPError: Error, LocalizedError {
    case challenge(host: String)
    case circuitOpen(host: String)

    var errorDescription: String? {
        switch self {
        case .challenge(let host):
            return "Cloudflare 验证中（\(host)），请稍后再试或开节点"
        case .circuitOpen(let host):
            return "刚撞上 Cloudflare 验证（\(host)），60 秒内不再重试"
        }
    }

    /// 挑战类错误（挑战本身 / 断路器打开）：调用方不要再走拦截器兜底，
    /// 同一端点再发一次也只会撞上同一面墙。
    var isChallengeLike: Bool {
        switch self {
        case .challenge, .circuitOpen: return true
        }
    }
}

/// WordPress API 的统一请求层（run #20）：
/// - 挑战检测：cf-mitigated: challenge 响应头，或 Content-Type: text/html
///   （JSON 接口绝不该返回 HTML）；挑战不重试、不当 JSON、不当空列表；
/// - 单次可控重试：429 遵 Retry-After（最多等 10 秒）重试 1 次；
///   5xx/超时退避 1 秒重试 1 次；挑战用断路器（同一 host 60 秒内直接报，不再发请求）；
/// - 请求合并：同一 URL 在途时只发一次，后到的等同一结果；按等待者计数取消，
///   最后一个等待者走光才取消底层请求；
/// - 底层仍是 DiagnosticHTTPClient（长寿命 URLSession + URLSessionTaskMetrics，
///   不另起会话；metrics 由它记进 NetworkDiagnostics）。
final class WordPressHTTP: @unchecked Sendable {
    static let shared = WordPressHTTP()

    private let lock = NSLock()
    private struct InFlight {
        var task: Task<(Data, HTTPURLResponse), Error>
        var waiters: Int
    }
    private var inFlight: [String: InFlight] = [:]
    /// 断路器：host → 上次撞挑战的时间（60 秒内不再发请求）。
    private var lastChallengeAt: [String: Date] = [:]
    private let circuitOpenSeconds: TimeInterval = 60
    /// 429 Retry-After 最多等这么久（再大也不等，列表不能卡死）。
    private let maxRetryAfterSeconds: TimeInterval = 10
    /// 5xx/超时重试前的退避。
    private let retryBackoffSeconds: TimeInterval = 1

    private init() {}

    /// 挑战判定：cf-mitigated 响应头含 challenge，或 Content-Type 是 text/html。
    /// 只认这两个信号（规范定死）；body 不参与判定。
    static func isChallenge(response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if let mitigated = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased(),
           mitigated.contains("challenge") {
            return true
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            return true
        }
        return false
    }

    /// 发一个 WordPress GET（调用方已拼好 URL 与请求头；只用于 GET）。
    /// 返回原始 body 与 HTTP 响应；挑战/断路器抛 WordPressHTTPError。
    func fetch(_ request: URLRequest, source: String, timeout: TimeInterval = 12) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let key = url.absoluteString
        let task: Task<(Data, HTTPURLResponse), Error>
        lock.lock()
        if var entry = inFlight[key] {
            entry.waiters += 1
            inFlight[key] = entry
            task = entry.task
            lock.unlock()
        } else {
            let created = Task<(Data, HTTPURLResponse), Error> {
                try await self.perform(request, source: source, timeout: timeout)
            }
            inFlight[key] = InFlight(task: created, waiters: 1)
            task = created
            lock.unlock()
        }
        do {
            let result = try await task.value
            release(key: key)
            return result
        } catch {
            release(key: key)
            throw error
        }
    }

    /// 一个等待者离开：在途表里减数；减到 0 就从表里摘掉并取消底层请求
    ///（还有等待者时底层请求继续跑，不因某一路取消而断）。
    private func release(key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = inFlight[key] else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlight[key] = entry
        }
    }

    /// 真正发请求（含单次可控重试）。断路器打开时直接报，不发请求。
    private func perform(_ request: URLRequest, source: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host?.lowercased() ?? ""
        lock.lock()
        let lastChallenge = lastChallengeAt[host]
        lock.unlock()
        if let lastChallenge, Date().timeIntervalSince(lastChallenge) < circuitOpenSeconds {
            throw WordPressHTTPError.circuitOpen(host: host)
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await DiagnosticHTTPClient.shared.data(
                    for: request,
                    source: source,
                    preservedHeaders: request.allHTTPHeaderFields ?? [:],
                    timeout: timeout
                )
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if Self.isChallenge(response: response) {
                    recordChallenge(host: host)
                    throw WordPressHTTPError.challenge(host: host)
                }
                recordSuccess(host: host)
                let status = http.statusCode
                if status == 429, attempt == 1 {
                    let wait = min(retryAfterSeconds(from: http) ?? retryBackoffSeconds, maxRetryAfterSeconds)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                if (500...599).contains(status), attempt == 1 {
                    try await Task.sleep(nanoseconds: UInt64(retryBackoffSeconds * 1_000_000_000))
                    continue
                }
                return (data, http)
            } catch {
                // 取消立即出，不重试；挑战类错误也不重试。
                if error is CancellationError { throw error }
                if let wpError = error as? WordPressHTTPError { throw wpError }
                // 超时/断连重试 1 次；别的传输错误不重试。
                if attempt == 1, let urlError = error as? URLError,
                   urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                    try await Task.sleep(nanoseconds: UInt64(retryBackoffSeconds * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private func recordChallenge(host: String) {
        guard !host.isEmpty else { return }
        lock.lock()
        lastChallengeAt[host] = Date()
        lock.unlock()
    }

    private func recordSuccess(host: String) {
        guard !host.isEmpty else { return }
        lock.lock()
        lastChallengeAt.removeValue(forKey: host)
        lock.unlock()
    }

    /// Retry-After 头：整数秒；解析不出按 1 秒算（HTTP-date 形式不展开，
    /// 直接退回默认退避，不让列表卡死）。
    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

/// WordPress B 查询（run #20）：把模块发出的 /posts?_embed=1 改写成
/// _embed=wp:featuredmedia&_fields=id,title,slug,link,_links,_embedded，
/// 只留模块真正读的 5 个字段（id / title.rendered / slug / link /
/// _embedded["wp:featuredmedia"][0].source_url）。沙箱实测：484KB→129KB，
/// TTFB 4.9→2.99s，总 5.8→3.55s，24 条全、封面齐全。
/// 只改写 /wp-json/wp/v2/posts 且带 _embed=1 的 GET；别的 URL 一律不动。
/// 兼容性回退：某 host 的 B 查询被证实结构不支持时记一笔（TTL 24 小时），
/// 期间该 host 不再改写，走原 _embed=1 查询；挑战不算结构失败。
enum WPQueryOptimizer {
    static let slimFields = "id,title,slug,link,_links,_embedded"

    /// B 改写后的 URL；不适用（不是 /posts、没带 _embed=1、已有 _fields、
    /// 该 host 的 B 已被证实不支持）返回 nil。
    static func bRewrittenURL(for urlString: String) -> String? {
        guard var comps = URLComponents(string: urlString),
              comps.path == "/wp-json/wp/v2/posts",
              let host = comps.host, !host.isEmpty,
              WPQueryCapability.isBEnabled(for: host),
              let items = comps.queryItems,
              items.contains(where: { $0.name == "_embed" && $0.value == "1" }),
              !items.contains(where: { $0.name == "_fields" }) else { return nil }
        var newItems: [URLQueryItem] = []
        for item in items {
            if item.name == "_embed" {
                newItems.append(URLQueryItem(name: "_embed", value: "wp:featuredmedia"))
            } else {
                newItems.append(item)
            }
        }
        newItems.append(URLQueryItem(name: "_fields", value: slimFields))
        comps.queryItems = newItems
        return comps.url?.absoluteString
    }

    /// B 查询用的 query items（直调路径拼 URL 用；与桥里改写同一款查询）。
    static func bQueryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "_embed", value: "wp:featuredmedia"),
            URLQueryItem(name: "_fields", value: slimFields),
        ]
    }

    /// 结构失败判定（B 查询本身不被支持的信号）：
    /// - 400 且 body 含 rest_invalid_param（无效查询参数；注意页码超出的 400
    ///   是 rest_invalid_page_number，不算）；
    /// - 200 但 body 不是 JSON 数组；
    /// - 200 且数组非空、首条缺 id/title/link（字段被裁坏了）。
    /// 空数组 [] 是合法空结果，不是失败；别的 4xx/5xx 是服务端问题，不是 B 不兼容；
    /// HTML 体（挑战页/错误页）也不是 B 的结构问题。
    static func isStructuralFailure(status: Int, bodyData: Data) -> Bool {
        if status == 400 {
            if let text = String(data: bodyData, encoding: .utf8),
               text.contains("rest_invalid_param") {
                return true
            }
            return false
        }
        guard status == 200 else { return false }
        // 空体是传输异常（WP /posts 永远回数组，至少是 []），不是 B 的结构问题。
        guard !bodyData.isEmpty else { return false }
        if let text = String(data: bodyData.prefix(32), encoding: .utf8),
           text.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) else { return true }
        guard let array = json as? [Any] else { return true }
        guard let first = array.first as? [String: Any] else { return false }
        return first["id"] == nil || first["title"] == nil || first["link"] == nil
    }
}

/// B 查询的兼容性记录：按 host 记，TTL 24 小时。
/// 只记失败（B 被证实不支持）；成功不写盘（只清掉已有的失败记录），
/// 避免每次列表加载都写一次 UserDefaults。
/// 没记录 / 记录过期 → B 默认开。
enum WPQueryCapability {
    private static let lock = NSLock()
    /// host（小写）→ B 失败的时间。
    private static var memory: [String: Date] = [:]
    private static let ttl: TimeInterval = 24 * 3600

    private static func defaultsKey(for host: String) -> String {
        "wp.bquery.failed." + host.lowercased()
    }

    static func isBEnabled(for host: String) -> Bool {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let failedAt = memory[key] {
            return Date().timeIntervalSince(failedAt) >= ttl
        }
        if let stored = UserDefaults.standard.object(forKey: defaultsKey(for: host)) as? Date {
            if Date().timeIntervalSince(stored) < ttl {
                memory[key] = stored
                return false
            }
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: host))
        }
        return true
    }

    static func record(host: String, works: Bool) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if works {
            memory.removeValue(forKey: key)
            UserDefaults.standard.removeObject(forKey: defaultsKey(for: host))
        } else {
            let now = Date()
            memory[key] = now
            UserDefaults.standard.set(now, forKey: defaultsKey(for: host))
        }
    }
}
