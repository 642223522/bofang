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

    /// 诊断事件插入（R5-9）：直接 DispatchQueue.main.async——主队列是串行
    /// 队列，GCD 保证入队顺序，插入顺序即 record() 调用顺序。R4-7 的串行
    /// 队列 + Task { @MainActor in } 不保证顺序（无结构 Task 在 MainActor
    /// 上的执行顺序没有 FIFO 契约）；删掉 recordQueue 也去掉了 Swift 6
    /// 下的跨隔离访问（@MainActor 类上的 static let 不能从 nonisolated
    /// 代码里读，属编译风险）。
    nonisolated static func record(_ event: NetworkDiagEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let store = NetworkDiagnostics.shared
                store.events.insert(event, at: 0)
                if store.events.count > Self.maxEvents {
                    store.events.removeLast()
                }
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
        // DoH/代理路径没有 metrics（tx 为 nil），最终 URL 从响应里取（F17）。
        let finalURL = tx?.request.url ?? response?.url ?? request.url
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
            // F8：NSURLErrorDomain 的码全是负数，+1 在该域里不存在——27c1c34
            // 把 code==1 限到 NSURLErrorDomain 等于关掉了真正的 CFNetwork
            // code 1 补强。真正的 +1 是 kCFErrorDomainCFNetwork 域的
            // kCFHostErrorHostNotFound（DNS 解析失败），必须按域分开判。
            let needsDetail = (nsErr.domain == NSURLErrorDomain && nsErr.code == URLError.unsupportedURL.rawValue)
                || (nsErr.domain == (kCFErrorDomainCFNetwork as String) && nsErr.code == DiagnosticHTTPClient.cfHostErrorHostNotFound)
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
            // F13：DoH 解析失败分三种信号（NXDOMAIN / 解析商全不可达 /
            // 答案全被污染过滤拒绝），不再一律判成 .cannotFindHost 的 DNS 失败。
            if let dohErr = error as? DoHResolutionError {
                switch dohErr {
                case .nxdomain:
                    return (.dns, "DNS 域名不存在 (NXDOMAIN)")
                case .resolversUnreachable:
                    return (.dns, "DoH 解析商均未返回可用 A 记录")
                case .allCandidatesRejected:
                    return (.dns, "DoH 解析答案全部被污染过滤拒绝")
                }
            }
            // F16：Swift CancellationError 不是 URLError（.cancelled 码只认
            // URLError）：不先判这里会被 inferPhaseFromMetrics 标成 unknown。
            if error is CancellationError {
                return (.cancelled, "请求被取消")
            }
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
    /// 上次建会话时的代理状态：代理开关 NWPathMonitor 捕捉不到，resolveSessionLocked()
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
    /// 上次已落地的路径签名（F10）：去抖窗口内抖回去（Wi-Fi→蜂窝→Wi-Fi）
    /// 时，debounced 的 work item 带的签名与它相同，直接跳过，不触发轮换。
    /// 只在 pathMonitorQueue 上读写。
    private var lastSettledPathSignature = ""
    /// 路径去抖：接口抖动时只排一次轮换（~0.5 秒内多次变化合并成一次）。
    /// 只在 pathMonitorQueue 上读写（path 回调的串行队列）。
    private var pathDebounceWorkItem: DispatchWorkItem?

    private init() {
        self.session = URLSession(configuration: Self.makeSessionConfig())
        self.lastProxyState = ActiveSystemProxy.current()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = "wifi=\(path.usesInterfaceType(.wifi))|cell=\(path.usesInterfaceType(.cellular))|wired=\(path.usesInterfaceType(.wiredEthernet))|other=\(path.usesInterfaceType(.other))|ok=\(path.status == .satisfied)"
            if self.lastPathSignature.isEmpty {
                self.lastPathSignature = signature
                // R3-8：首次回调同时初始化 lastSettledPathSignature，否则
                // 第一次抖回（Wi-Fi→蜂窝→Wi-Fi）会拿 settledSignature 与 ""
                // 比较，误触发一次轮换 + 清 Cookie + DoH 重置。
                self.lastSettledPathSignature = signature
                return
            }
            if signature != self.lastPathSignature {
                self.lastPathSignature = signature
                self.scheduleNetworkTransition()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// 去抖调度：0.5 秒内再有变化就取消重排，只执行最后一次。
    /// work item 里带上调度当时的路径签名，执行时若与上次已落地的签名相同
    /// 则跳过（F10：窗口内抖回去不触发轮换）。
    private func scheduleNetworkTransition() {
        pathDebounceWorkItem?.cancel()
        let signature = lastPathSignature
        let item = DispatchWorkItem { [weak self] in
            self?.handleNetworkTransition(settledSignature: signature)
        }
        pathDebounceWorkItem = item
        pathMonitorQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// 网络切换：世代 +1、熔断器清零、DoH 缓存清、会话轮换、Cookie 清。
    /// 注意：隧道内换节点不改变接口签名，不触发这里——那种残留死连接靠
    /// data() 里的复用重置重试（rotate + 重试一次）兜底。
    /// F10：epoch+1、breaker 清空、清 Cookie、轮换（preserveCookies: false，
    /// 新 session 用空 Cookie Storage）在一次 sessionLock 内完成——
    /// 否则并发的 makeDataTask 可能在清与轮换之间插进来，
    /// 把未清的 Cookie 拷进新会话，清 Cookie 的动作就被架空了。
    private func handleNetworkTransition(settledSignature: String) {
        // 窗口内抖回去了：签名与上次已落地的相同，不触发轮换。
        guard settledSignature != lastSettledPathSignature else { return }
        lastSettledPathSignature = settledSignature
        sessionLock.lock()
        networkEpoch &+= 1
        breaker.removeAll()
        // 先清当前会话的 Cookie 再轮换（轮换不继承 Cookie）。
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
        rotateSessionLocked(preserveCookies: false)
        // R7-1：DoH 重置移到锁内——ND 状态（epoch/清 breaker/轮换）与
        // DoH 状态（世代/IP 缓存/偏好）必须一起落地，否则并发请求能在
        // 新 epoch 下读到旧网 DoH 缓存（ChatGPT R8 P1-2）。锁顺序安全：
        // DoHFallbackClient 从不调 NetworkDiagnostics、不拿 sessionLock，
        // sessionLock -> DoH 锁是唯一顺序，无反向嵌套、无死锁。
        DoHFallbackClient.shared.resetForNetworkChange()
        sessionLock.unlock()
    }

    /// 锁内解析当前 session（代理变化时轮换，与旧 currentSession() 同一套
    /// 判定）。调用方必须已持有 sessionLock；F7 的 makeDataTask 在同一把
    /// 锁内解析 session 并建任务，建任务与轮换之间插不进一次 rotate。
    /// 返回代理是否刚变化——变化时 DoH 重置由 makeDataTask 在锁内补调
    ///（R7-1：resetForNetworkChange() 在持有 sessionLock 时调，见 R7-1
    /// 的锁顺序证明；R5-7 的“绝不在持锁时调”已废止）。
    private func resolveSessionLocked() -> (session: URLSession, proxyChanged: Bool) {
        let nowProxy = ActiveSystemProxy.current()
        var proxyChanged = false
        if nowProxy != lastProxyState {
            proxyChanged = true
            lastProxyState = nowProxy
            networkEpoch &+= 1
            breaker.removeAll()
            // F9：代理变化触发的轮换不清 Cookie 不行——代理后的网络与之前
            // 是不同出口，直连时沾上的 WAF 坏 Cookie 不能带过去；同时清 DoH 缓存。
            rotateSessionLocked(preserveCookies: false)
        }
        return (session, proxyChanged)
    }

    /// 同步代理状态 + 网络世代（R5-7）：data() 入口调一次，替代原来先读
    /// startEpoch、后在 Branch 3 才发现代理变了的做法。代理切换不触发
    /// NWPathMonitor，只能靠 ActiveSystemProxy.current() 与 lastProxyState
    /// 对比；若等到 Branch 3 才同步，入口抓的 startEpoch 是旧世代，换代理后
    /// 第一个请求的 tripBreaker 会被 epoch 不符静默丢弃，且 Branch 1 的
    /// isBreakerTripped 会拿旧 epoch 把 host 困在 DoH 路上、永远走不到同步。
    /// 代理变化时在锁内做 epoch+1、清 breaker、轮换（不继承 Cookie），
    /// resetForNetworkChange() 也在同一把锁内调（R7-1：ND 与 DoH 状态
    /// 一起落地；R5-7 的“解锁后才调”已废止，锁顺序见 handleNetworkTransition）。
    /// 幂等：第二次调时 nowProxy == lastProxyState，什么都不做，不重复 +1。
    private func syncProxyStateAndEpoch() -> (proxy: ActiveSystemProxy, epoch: UInt64) {
        var changed = false
        sessionLock.lock()
        // R6-11：代理快照必须在锁内读——锁外读到的可能是旧值，拿旧值
        // 回写 lastProxyState 会把刚同步好的状态滚回去。
        let nowProxy = ActiveSystemProxy.current()
        if nowProxy != lastProxyState {
            changed = true
            lastProxyState = nowProxy
            networkEpoch &+= 1
            breaker.removeAll()
            rotateSessionLocked(preserveCookies: false)
        }
        let epoch = networkEpoch
        // R7-1：DoH 重置移到锁内（见 handleNetworkTransition 的注释）。
        if changed {
            DoHFallbackClient.shared.resetForNetworkChange()
        }
        sessionLock.unlock()
        return (nowProxy, epoch)
    }

    private func rotateSession(preserveCookies: Bool = true) {
        // R3-7：代理变化不能在这里被吞掉——旧实现无条件更新 lastProxyState，
        // 导致 stale-socket 重试时（唯一调用方）把代理变化藏起来：直连 Cookie
        // 被拷进新代理会话，且下次 resolveSessionLocked() 看不到变化，F9
        //（epoch+1、清 breaker、DoH 重置）永远不触发。
        var proxyChanged = false
        var effectivePreserveCookies = preserveCookies
        sessionLock.lock()
        // R6-11：代理快照必须在锁内读（同 syncProxyStateAndEpoch）。
        let nowProxy = ActiveSystemProxy.current()
        if nowProxy != lastProxyState {
            proxyChanged = true
            lastProxyState = nowProxy
            networkEpoch &+= 1
            breaker.removeAll()
            effectivePreserveCookies = false
        } else {
            lastProxyState = nowProxy
        }
        rotateSessionLocked(preserveCookies: effectivePreserveCookies)
        // R7-1：DoH 重置移到锁内（见 handleNetworkTransition 的注释）。
        if proxyChanged {
            DoHFallbackClient.shared.resetForNetworkChange()
        }
        sessionLock.unlock()
    }

    private func rotateSessionLocked(preserveCookies: Bool) {
        let old = session
        // 轮换保留 Cookie：ephemeral 会话一轮换就丢掉全部 host 的 Cookie，
        // WAF 通行证（如 cf_clearance）没了就得重新过墙；只拷未过期的。
        // preserveCookies == false 时新 session 用空 Cookie Storage
        //（代理变化 / 网络切换：旧网的 Cookie 不许带到新网）。
        // 在途任务可能随后又写 Cookie，那几条丢了也无妨（下次请求重建）。
        let carriedCookies: [HTTPCookie]
        if preserveCookies {
            carriedCookies = (old.configuration.httpCookieStorage?.cookies ?? [])
                .filter { $0.expiresDate == nil || $0.expiresDate! > Date() }
        } else {
            carriedCookies = []
        }
        let newConfig = Self.makeSessionConfig()
        if let storage = newConfig.httpCookieStorage {
            for cookie in carriedCookies {
                storage.setCookie(cookie)
            }
        }
        session = URLSession(configuration: newConfig)
        old.finishTasksAndInvalidate()
    }

    /// 清掉会话的 Cookie（网络切换后调；也可以手动调）。
    /// F10：清理时全程持锁——先抓 session 再解锁清的做法会让并发轮换
    /// 把未清的 Cookie 拷进新会话。
    func resetCookies() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
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
    /// R4-11：只在 networkEpoch == ifEpoch 时写——中途换网/换代理后，旧网的
    /// 失败不再把新网的 breaker 跳闸 10 分钟（epoch 隔离）。
    private func tripBreaker(host: String?, ifEpoch expectedEpoch: UInt64) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard networkEpoch == expectedEpoch else { return }
        breaker[host] = (epoch: networkEpoch, until: Date().addingTimeInterval(600))
    }

    /// 清掉某 host 的熔断器（R5-12/R6-5）：熔断 host 在 DoH 上失败后回退到
    /// URLSession 时清掉，否则该 host 永远钉在 Branch 1 的 DoH 路上。
    /// 强制 host（模块声明）不走这条路，不清。只在 networkEpoch ==
    /// ifEpoch 时清（与 tripBreaker 同一套世代隔离——中途换网后，
    /// 旧网的失败不再清掉新网的熔断器）。
    private func clearBreaker(host: String?, ifEpoch expectedEpoch: UInt64) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard networkEpoch == expectedEpoch else { return }
        breaker.removeValue(forKey: host)
    }

    /// kCFHostErrorHostNotFound 的数值（CFNetworkErrors：1 = DNS 解析失败）。
    /// iOS 27 SDK 里 CFHost.h 的符号已不在 Swift 可见范围（run #32 构建报错
    /// cannot find 'kCFHostErrorHostNotFound' in scope），只能用字面值；
    /// 三处调用都先判了域是 kCFErrorDomainCFNetwork，所以 1 不会跟别的域撞。
    /// internal（非 private）：NetworkDiagnostics.makeEvent 也要引用它
    ///（R3-1：private 会让 makeEvent 的 Self.cfHostErrorHostNotFound 编译不过）。
    static let cfHostErrorHostNotFound = 1

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
    /// timeout：单次请求总超时（秒，默认 12s；显式值钳制在 (0, 30]s——<=0 直接
    /// 报超时，不设下限，nil 时默认 12s）——这是真正的总预算，用 deadline
    /// 任务赛跑实现；request.timeoutInterval 只作字节间空闲定时器，慢速滴漏
    ///（tarpit）再也拖不到 25s。
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
        // R3-3：3 秒下限只在 timeout == nil 时用（外部默认 12s）。显式传进来
        // 的 timeout 是上层算好的剩余预算（WordPress 的 remaining()），绝不能
        // 再放大——否则整条 WP 请求会超总预算（0.5s 剩 → 3s，超约 2.5s）。
        // R4-2：0.2 下限也不要——显式预算 <0.2s 时把它抬到 0.2s 仍违一本账
        //（WP 剩 0.1s 传进来，底层能跑 0.2s）。<=0 直接报超时，不设下限。
        let totalDeadline: TimeInterval
        if let timeout {
            guard timeout > 0 else { throw URLError(.timedOut) }
            totalDeadline = min(timeout, 30)
            request.timeoutInterval = totalDeadline
        } else {
            totalDeadline = 12
            if request.timeoutInterval <= 0 || request.timeoutInterval >= 60 {
                request.timeoutInterval = 12
            }
        }
        // 绝对 deadline：一本账，整条请求链（URLSession + 兜底 + 救援）共用；
        // 各层只拿剩余时间，不再每层重起一份全额预算（26.238s 就是这么来的）。
        let deadline = Date().addingTimeInterval(totalDeadline)
        // R5-7：入口先同步代理状态 + 网络世代（R4-11 的 startEpoch 由它返回）——
        // 代理切换不触发 NWPathMonitor，只能靠对比；若等到 Branch 3 才同步，
        // 入口抓的 startEpoch 是旧世代，换代理后第一个请求的跳闸会被丢弃，
        // Branch 1 也会拿旧 epoch 把 host 困在 DoH 路上。
        let (proxy, startEpoch) = syncProxyStateAndEpoch()
        // R5-6：流式 body（httpBodyStream）不走 DoH/强制传输——DoH 自研栈只读
        // httpBody，流会被丢掉；有流的请求直接走 URLSession（原生处理流）。
        // 只要 httpBodyStream 非空就是流式请求（即使 httpBody 也填了，
        // URLSession 也是用流，不用 httpBody）。
        let hasStreamBody = rawRequest.httpBodyStream != nil
        // R5-3/R6-6：本请求是否已试过传输兜底（DoH 直连或代理）——
        // Branch 2 失败后 Branch 3 不许再回传输（否则 DoH→URLSession→
        // DoH 乒乓，还把 10 分钟熔断器钉到刚失败的路上；代理下同理，
        // Branch 1 走代理失败后 Branch 3 不能再试同一条代理路）。
        var triedTransport = false

        // 1. 强制 host（已知 URLSession 不可靠）与熔断 host：代理感知 NWConnection。
        // PAC-only 时 NWConnection 执行不了 JS PAC，回落系统 URLSession。
        // 只对 https（DoH 客户端只做 https；http 请求直接走 URLSession）。
        if !hasStreamBody,
           url.scheme?.lowercased() == "https",
           isForcedTransportHost(url.host) || isBreakerTripped(host: url.host) {
            if !proxy.isPACOnly {
                // R6-6：Branch 1 一走传输就记下来（不论直连 DoH 还是代理），
                // Branch 2/3 不再重复试同一条路。
                triedTransport = true
                // R6-4：抓偏好快照——熔断 host 失败回退时要条件撤销偏好
                //（与 Branch 2 同一套版本号围栏）。
                let branch1PrefRevision = DoHFallbackClient.shared.doHPreferenceSnapshot(for: url.host)
                // R5-12：熔断 host 的 DoH 失败要清闸回退——否则一个站
                // 在 DoH 上一挂就永远钉在 Branch 1；强制 host（模块声明）
                // 保持原样，不清闸、不回退。
                do {
                    return try await performViaProxyAwareTransport(
                        request: request,
                        source: source,
                        preservedHeaders: preservedHeaders,
                        timeout: max(0, deadline.timeIntervalSinceNow),
                        proxy: proxy,
                        preserveResponseStarted: true
                    )
                } catch let failure as DoHResponseStartedFailure {
                    // R5-4e：已收到响应头后 body 失败——直接抛原错，不清闸、
                    // 不回退（重发会复制请求）。
                    throw failure.underlying
                } catch {
                    if error is CancellationError { throw error }
                    if isForcedTransportHost(url.host) { throw error }
                    // R7-3：预算守卫从入口移到这里（与 Branch 2 对齐）——
                    // 预算耗尽（<=0.2s）时直接抛 DoH 原错，不清闸、不撤销、
                    // 不回退（回退只会起一个 0ms 的 URLSession 任务，记一条
                    // 假超时事件，还把 DoH 原错盖掉）。
                    if deadline.timeIntervalSinceNow <= 0.2 { throw error }
                    clearBreaker(host: url.host, ifEpoch: startEpoch)
                    if let snap = branch1PrefRevision {
                        DoHFallbackClient.shared.removeDoHPreferred(host: url.host, ifGeneration: snap.generation, ifRevision: snap.revision)
                    }
                }
            }
        }

        // 2. DoH 偏好 host（之前走 DoH 成功过）：仅无显式代理时直连 DoH；
        // 代理开着时由代理做 DNS（远程解析本来就是干净的），走 URLSession。
        //（系统 DNS 给的是被污染的 Facebook IP，TCP 黑洞 12 秒。）
        // R5-12/R6-6：Branch 1 已试过传输（triedTransport）时不再重复试。
        if !hasStreamBody,
           !triedTransport,
           proxy == .none,
           DoHFallbackClient.shared.isDoHPreferred(for: url.host),
           url.scheme?.lowercased() == "https" {
            // R5-4/R5-2：DoH 偏好失效就撤销——取消原样抛；已收到响应头
            // 的错（DoHResponseStartedFailure）直接抛原错，不撤销、不回退
            //（重发会复制请求）；预算耗尽（<=0.2s）也直接抛 DoH 原错，
            // 不撤销、不回退（回退只会起一个 0ms 的 URLSession 任务，
            // 记一条假超时事件，还把 DoH 原错盖掉）。其余错按版本号
            // 条件撤销（R5-5），再落入下方 URLSession 路径（同一绝对
            // deadline，不另起预算），不让一个站因 DoH 一挂就持续失败到切网。
            let prefRevision = DoHFallbackClient.shared.doHPreferenceSnapshot(for: url.host)
            triedTransport = true
            do {
                return try await performViaDoH(request: request, source: source, preservedHeaders: preservedHeaders, timeout: max(0, deadline.timeIntervalSinceNow), preserveResponseStarted: true)
            } catch let failure as DoHResponseStartedFailure {
                throw failure.underlying
            } catch {
                if error is CancellationError { throw error }
                if deadline.timeIntervalSinceNow <= 0.2 { throw error }
                if let snap = prefRevision {
                    DoHFallbackClient.shared.removeDoHPreferred(host: url.host, ifGeneration: snap.generation, ifRevision: snap.revision)
                }
            }
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
            // 剩余预算从绝对 deadline 算（不再 max(3, ...) 垫底——deadline
            // 到了就是到了，0 秒超时直接报，不再多拖 3 秒）。
            let remaining = max(0, deadline.timeIntervalSinceNow)
            // R5-2：预算耗尽时不再起任务——0 秒超时的 runURLSessionOnce 只会
            // 立即取消、白记一条假超时事件并盖掉真正的上游错误（Branch 2
            // 的 DoH 原错）。到这里预算已用完，直接报超时。
            guard remaining > 0 else { throw URLError(.timedOut) }
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
                // R6-8：metrics 等待按剩余预算给上限（最多 150ms），绝不推出
                // 绝对 deadline；有预算就等（metrics 还负责 F2 的已响应判定，
                // 超时错也不能一律跳过等，否则 F2 拿不到指标会误回退）。
                let remainingForMetrics = max(0, deadline.timeIntervalSinceNow)
                let metrics = await delegate.takeMetricsSoon(for: error, maxWait: min(0.15, remainingForMetrics))
                // R7-6：总超时时 remainingForMetrics == 0，metrics 几乎必为 nil
                //（task.cancel() 刚发出，didFinishCollecting 还没回调），诊断
                // 账本会丢掉 DNS/TCP/TLS/TTFB。data() 仍零等待立即返回；仅在
                // metrics == nil 且非取消时，用脱离当前请求的 Task.detached
                // 后台等最多 150ms 补采完再记事件（只影响诊断记账，不阻塞调用方）。
                // F2 与兜底逻辑仍用这里的（可能为 nil 的）metrics，不等补采。
                // 事件恰好记一次（if/else，二选一）。
                if metrics == nil, !(error is CancellationError) {
                    Task.detached {
                        let lateMetrics = await delegate.takeMetricsSoon(for: error, maxWait: 0.15)
                        let lateEvent = NetworkDiagnostics.makeEvent(
                            source: source,
                            request: request,
                            response: nil,
                            bodyData: nil,
                            error: error,
                            metrics: lateMetrics,
                            fallbackDurationMs: elapsedMs,
                            networkClass: networkClassAtStart
                        )
                        NetworkDiagnostics.record(lateEvent)
                    }
                } else {
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
                }
                // F11：剩余预算守门——<= 0.2s 时直接重抛原错，不重试、不 fallback、
                // 不写假 DoH 事件、不跳闸（-1002 救援与 TTFB 保护在它之前判，
                // 它们不依赖预算；下面的重试/fallback 路径共用这一道门）。
                let remainingNow = deadline.timeIntervalSinceNow
                // R4-11/R7-5：catch 里重读当前代理——入口抓的 proxy 可能已过期
                //（中途开了/关了代理）；救援与兜底都用最新的代理（仍受 !isPACOnly
                // 守卫）。R7-5：改调 syncProxyStateAndEpoch() 而不是裸读——
                // 中途切代理时它会涨 networkEpoch（让 tripBreaker 的 startEpoch
                // 围栏失效）、清旧会话 Cookie、重置 DoH；未变时只是锁内相等比较。
                let (currentProxy, _) = syncProxyStateAndEpoch()
                // R6-6：本请求已试过传输（Branch 1/2）时，-1002 救援与传输
                // 兜底都不再试——否则同一条路会被反复试，还会把熔断器钉到
                // 刚失败的路上。这里算一次，后面两处共用。
                let canFallbackTransport = !triedTransport
                // R5-6：流式 body 的请求到这里直接抛原错，不重试、不救援、
                // 不回退——第一遍 URLSession 已把 InputStream 读掉（再试
                // 是空流），DoH 自研栈又只读 httpBody（nil），回退只会
                // 悄悄发一个 0 字节空 body。这一道检查同时拦住下面三条路。
                if hasStreamBody { throw error }
                // F12：-1002 救援先于 TTFB 保护判——-1002 是 URL 问题，不是传输
                // 问题，不应被“已收到响应头”拦住。预算不够时不救，直接抛原错。
                if canFallbackTransport, url.scheme?.lowercased() == "https", isStrict1002Rescue(error: error, request: request), !currentProxy.isPACOnly {
                    guard remainingNow > 0.2 else { throw error }
                    return try await performViaProxyAwareTransport(
                        request: request,
                        source: source,
                        preservedHeaders: preservedHeaders,
                        timeout: max(0, remainingNow),
                        proxy: currentProxy
                    )
                }
                // F2：响应已开始（收到过任何一跳响应头）后再失败：不再回退到 DoH
                // 传输——CDN 已应答、body 慢、被总超时杀掉时，兜底只会把请求踢进
                // 另一条坏掉的路（jav.pub 那几条 0.6s TTFB 却 -1001 的记录
                // 就是这么来的）。信号是 metrics 的全部 transaction
                //（任一 transaction 的 responseStartDate 非空即算已收到响应头；
                // completion-handler 任务的数据回调不走 task.delegate，
                // delegate 标记这条路走不通，不再用它）。原错直接抛回，不跳闸熔断器。
                let receivedAnyResponse = metrics?.transactionMetrics.contains { $0.responseStartDate != nil } ?? false
                if receivedAnyResponse {
                    throw error
                }
                guard remainingNow > 0.2 else { throw error }
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
                    // R6-6：本请求已试过传输时不跳闸、不回传输（canFallbackTransport
                    // 在 catch 顶部已算过）——DoH 本请求已失败，再试是乒乓，还会把
                    // 10 分钟熔断器钉到刚失败的路上；直接抛原错。
                    if canFallbackTransport, shouldTripBreaker(error: error, metrics: metrics) {
                        tripBreaker(host: host, ifEpoch: startEpoch)
                    }
                    if canFallbackTransport, !currentProxy.isPACOnly {
                        return try await performViaProxyAwareTransport(
                            request: request,
                            source: source,
                            preservedHeaders: preservedHeaders,
                            timeout: max(0, deadline.timeIntervalSinceNow),
                            proxy: currentProxy
                        )
                    }
                    throw error
                }
                throw error
            }
        }
    }

    /// 单次 URLSession 尝试：deadline 赛跑（超时/取消立即取消底层任务，不滞留连接池）。
    /// 旧实现用 withThrowingTaskGroup 赛跑——超时方先返回时，作用域退出还要
    /// 等被取消的 URLSession 子任务排空，12 秒超时能拖到 26 秒（run #33 回归）。
    /// 27c1c34 改成非结构化 worker + RaceBox，但 worker 里调 session.data(for:delegate:)
    /// 仍有崩溃竞态：worker 取 session 与 async 取数之间若有轮换调用
    /// finishTasksAndInvalidate()，async  machinery 与失效的会话抢状态会崩。
    /// 这里改成同步建 dataTask（completion handler 调 box.finish）：建任务与
    /// 会话解析在同一把 sessionLock 内完成（makeDataTask），建好后再轮换也
    /// 安全——finishTasksAndInvalidate 只等在途任务跑完，不杀已建好的任务。
    /// PerRequestDelegate（重定向拦截、metrics）经 task.delegate
    /// 继续工作（task 级 delegate 方法会走到它；数据走 completion handler）。
    private func runURLSessionOnce(
        request: URLRequest,
        delegate: PerRequestDelegate,
        timeout: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let box = URLSessionRaceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                // F25：已 finish（父任务在进 continuation 前已被取消，onCancel
                // 先跑）时 installContinuation 返回 false 并已把 pending 结果
                // 补恢复——直接返回，什么都不创建、不排计时器。
                guard box.installContinuation(continuation) else { return }
                let task = makeDataTask(request: request, delegate: delegate, box: box)
                box.installTask(task)
                let timer = DispatchWorkItem {
                    box.finish(.failure(URLError(.timedOut)), cancelTask: true)
                }
                box.installTimer(timer)
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeout),
                    execute: timer
                )
                task.resume()
            }
        } onCancel: {
            box.finish(.failure(CancellationError()), cancelTask: true)
        }
    }

    /// 在 sessionLock 保护下解析当前 session（走 resolveSessionLocked 的代理
    /// 判定）并同步创建 dataTask：delegate 挂 task 上，completion 里调 box.finish。
    /// 建任务与轮换之间不能插进一次 rotate，否则任务挂在旧会话上还被
    /// finishTasksAndInvalidate 拖住（F7 的崩溃竞态）。
    private func makeDataTask(
        request: URLRequest,
        delegate: PerRequestDelegate,
        box: URLSessionRaceBox
    ) -> URLSessionDataTask {
        sessionLock.lock()
        let (s, proxyChanged) = resolveSessionLocked()
        let task = s.dataTask(with: request) { data, response, error in
            if let error {
                box.finish(.failure(error), cancelTask: false)
            } else if let data, let response {
                box.finish(.success((data, response)), cancelTask: false)
            } else {
                box.finish(.failure(URLError(.badServerResponse)), cancelTask: false)
            }
        }
        task.delegate = delegate
        // R7-1：DoH 重置移到锁内（见 handleNetworkTransition 的注释）。
        if proxyChanged {
            DoHFallbackClient.shared.resetForNetworkChange()
        }
        sessionLock.unlock()
        return task
    }

    /// 代理感知 NWConnection：无代理时走 DoH 直连；显式代理时经代理协议；
    /// PAC-only 不应调到这里（调用方已排除）。
    private func performViaProxyAwareTransport(
        request: URLRequest,
        source: String,
        preservedHeaders: [String: String],
        timeout: TimeInterval,
        proxy: ActiveSystemProxy,
        preserveResponseStarted: Bool = false
    ) async throws -> (Data, URLResponse) {
        switch proxy {
        case .none:
            return try await performViaDoH(request: request, source: source, preservedHeaders: preservedHeaders, timeout: timeout, preserveResponseStarted: preserveResponseStarted)
        case .http, .socks5:
            return try await performViaProxy(request: request, source: source, preservedHeaders: preservedHeaders, timeout: timeout, proxy: proxy, preserveResponseStarted: preserveResponseStarted)
        case .pacOnly:
            throw URLError(.unsupportedURL)
        }
    }

    /// 经 DoH 客户端发请求（直连 DoH 解析出的 IP）：成功记偏好，
    /// 失败记一条诊断事件后把错抛回调用方。
    /// preserveResponseStarted（R5-4）：true 时已收到响应头后 body 失败
    /// 的包装（DoHResponseStartedFailure）原样抛给调用方（Branch 2 靠它
    /// 区分“可回退”与“不可重发”）；false（默认）时解开抛原错，包装绝不
    /// 漏出 data()。
    private func performViaDoH(
        request: URLRequest,
        source: String,
        preservedHeaders: [String: String],
        timeout: TimeInterval,
        preserveResponseStarted: Bool = false
    ) async throws -> (Data, URLResponse) {
        let started = Date()
        let networkClassAtStart = PlaybackLedger.networkClass
        // R6-2：调 perform() 前抓世代——成功后记偏好时用它做围栏；
        // 若中途切了网（世代变了），这次成功不记偏好，不污染新网。
        let gen = DoHFallbackClient.shared.currentGeneration()
        do {
            let (data, http, _) = try await DoHFallbackClient.shared.perform(
                request: request,
                preservedHeaders: preservedHeaders,
                timeout: timeout
            )
            // R6-2：偏好只在这里记（perform() 内不再逐跳记——逐跳记会把
            // 本次请求的版本号顶上去，导致本次失败时 Branch 2 的条件撤销
            // 静默失效、host 永久钉在已失败的 DoH 路上）。成功才记，
            // 且只在 host 非空时记。代理路不记（performViaProxy 不调它）。
            if let host = request.url?.host, !host.isEmpty {
                DoHFallbackClient.shared.markDoHPreferred(host: host, ifGeneration: gen)
            }
            recordTransportEvent(source: source, request: request, response: http, bodyData: data, error: nil, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            return (data, http)
        } catch let failure as DoHResponseStartedFailure {
            // R5-4：已收到响应头后 body 失败——诊断事件记原错；调用方
            // 要区分时（Branch 2）原样抛包装，不要时（代理感知传输）
            // 解开抛原错。
            recordTransportEvent(source: source, request: request, response: nil, bodyData: nil, error: failure.underlying, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: networkClassAtStart)
            if preserveResponseStarted {
                throw failure
            }
            throw failure.underlying
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
        proxy: ActiveSystemProxy,
        preserveResponseStarted: Bool = false
    ) async throws -> (Data, URLResponse) {
        let started = Date()
        do {
            let (data, http, _) = try await DoHFallbackClient.shared.perform(
                request: request,
                preservedHeaders: preservedHeaders,
                timeout: timeout,
                viaProxy: proxy
            )
            // F18：明确经代理，网络类别直接记 "proxy"，不要依赖
            // PlaybackLedger.networkClass 或 metrics 推断（NWConnection 路径
            // 没有 metrics，tx 为 nil 时类别会被记错）。
            recordTransportEvent(source: source, request: request, response: http, bodyData: data, error: nil, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: "proxy")
            return (data, http)
        } catch let failure as DoHResponseStartedFailure {
            recordTransportEvent(source: source, request: request, response: nil, bodyData: nil, error: failure.underlying, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: "proxy")
            if preserveResponseStarted {
                throw failure
            }
            throw failure.underlying
        } catch {
            recordTransportEvent(source: source, request: request, response: nil, bodyData: nil, error: error, elapsedMs: Int(Date().timeIntervalSince(started) * 1000), networkClass: "proxy")
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

/// runURLSessionOnce 的一次性完成盒（ChatGPT R2）：dataTask / 定时器 / 父取消
/// 三路抢一个 continuation，只恢复一次；先到的结果在 continuation 还没装好
/// 时暂存 pending，装好立刻补恢复。锁保护全部状态，调用方超时不等 worker 排空。
private final class URLSessionRaceBox: @unchecked Sendable {
    typealias Output = (Data, URLResponse)
    typealias Completion = CheckedContinuation<Output, Error>

    private let lock = NSLock()
    private var continuation: Completion?
    private var pending: Result<Output, Error>?
    private var task: URLSessionTask?
    private var timer: DispatchWorkItem?
    private var finished = false

    /// 装 continuation；已 finish 时返回 false（调用方什么都不创建直接返回）。
    /// false 时 pending 里的结果已在这里补恢复，continuation 不会悬空。
    @discardableResult
    func installContinuation(_ value: Completion) -> Bool {
        lock.lock()
        if finished {
            let result = pending
            lock.unlock()
            if let result {
                value.resume(with: result)
            } else {
                // 防御：finished 但 pending 为空不应发生（finish 总是把结果
                // 写进 pending）；真发生了也别让 continuation 永久挂住。
                value.resume(throwing: CancellationError())
            }
            return false
        }
        continuation = value
        lock.unlock()
        return true
    }

    /// 存 dataTask；已 finish 时立即取消它（调用方在 install 后 resume，
    /// 已取消的任务 resume 后会立刻以 -999 完成，completion 里 finish 是 no-op）。
    func installTask(_ value: URLSessionTask) {
        lock.lock()
        let cancel = finished
        if !cancel {
            task = value
        }
        lock.unlock()
        if cancel {
            value.cancel()
        }
    }

    func installTimer(_ value: DispatchWorkItem) {
        lock.lock()
        let cancel = finished
        if !cancel {
            timer = value
        }
        lock.unlock()
        if cancel {
            value.cancel()
        }
    }

    /// 完成：超时/取消时 cancelTask == true，同步取消底层 URLSessionTask
    ///（F7：dataTask 的 cancel 是同步的，不像 async worker 那样要等排空）。
    func finish(_ result: Result<Output, Error>, cancelTask: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        let timer = self.timer
        self.timer = nil
        if continuation == nil {
            pending = result
        }
        lock.unlock()
        timer?.cancel()
        if cancelTask {
            task?.cancel()
        }
        continuation?.resume(with: result)
    }
}

private final class PerRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originURL: URL?
    private let preservedHeaders: [String: String]
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?
    // 注意：不要加 URLSessionDataDelegate 做 TTFB 标记——completion-handler
    // 任务的数据回调（didReceive）由内部 delegate 接管，不会走到 task.delegate，
    // 标记永远置不了位；TTFB 只靠 metrics 的 responseStartDate（见 F2）。

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
    /// 等一小会儿（默认最多 ~150ms，F26：metrics 还负责 TTFB 判定，
    /// 150ms 足够它到；不再等 300ms），把超时请求的 DNS/TCP/TLS 停滞指标也拿回来；
    /// 已有 metrics 时立即返回，不多等。错误是 CancellationError 时同步拿现有的，
    /// 不等（取消了就别拖着调用方）。maxWait（R6-8）：调用方按剩余预算给上限，
    /// 0 即不等——metrics 等待绝不推出绝对 deadline。
    func takeMetricsSoon(for error: Error? = nil, maxWait: TimeInterval = 0.15) async -> URLSessionTaskMetrics? {
        if let m = takeMetrics() { return m }
        if error is CancellationError { return nil }
        // R6-8e（复审补）：向下取整——等待绝不超过 maxWait；向上取整会多等
        // 最多一个 25ms 周期， technically 推出 deadline。
        let iterations = max(0, Int(maxWait / 0.025))
        if iterations <= 0 { return takeMetrics() }
        return await Task.detached { [weak self] in
            guard let self else { return nil }
            for _ in 0..<iterations {
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
/// - 请求合并：同一 method+URL+请求头+timeout 在途时只发一次，后到的等同一结果；
///   按 waiter id 幂等释放（等待者取消只摘自己的 id，不直接断底层），
///   最后一个等待者走光才取消底层请求；
/// - 底层仍是 DiagnosticHTTPClient（长寿命 URLSession + URLSessionTaskMetrics，
///   不另起会话；metrics 由它记进 NetworkDiagnostics）。
final class WordPressHTTP: @unchecked Sendable {
    static let shared = WordPressHTTP()

    private let lock = NSLock()
    private struct InFlight {
        var task: Task<(Data, HTTPURLResponse), Error>
        /// 在途等待者 id 集合（waiter 取消时按 id 幂等释放，保证每个 waiter
        /// 只减一次；计数归零时才取消底层 Task）。
        var waiterIDs: Set<UUID>
        /// 每 waiter 的 continuation（R7-7）：等待者不再裸 await task.value
        ///（不响应等待者取消），而是挂自己的 continuation；底层 Task 完成
        /// 时批量恢复，等待者取消时立即以 CancellationError 恢复自己的。
        /// 与 waiterIDs 同步增减；恢复前必先从字典摘掉（恰好恢复一次）。
        var continuations: [UUID: CheckedContinuation<(Data, HTTPURLResponse), Error>]
        /// 条目 id（R3-15）：底层 Task 完成时按 id 摘条目，绝不摘掉复用
        /// 同一 key 的新条目。
        let id: UUID
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

    /// 挑战判定（G1，收紧）：cf-mitigated 含 challenge 即挑战；或
    /// 403/503 + Content-Type 含 text/html + Cloudflare 信号（cf-ray 头
    /// 或 server 头含 cloudflare）。WP 自身 500 HTML 错误页、nginx 默认页、
    /// 维护页不再误判成挑战（以前任意 text/html 都算挑战并开 60 秒断路器）。
    /// 其余一律不当挑战，走正常的 429/5xx 重试或直接返回响应。
    static func isChallenge(response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if let mitigated = http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased(),
           mitigated.contains("challenge") {
            return true
        }
        let status = http.statusCode
        guard status == 403 || status == 503 else { return false }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("text/html") else { return false }
        if http.value(forHTTPHeaderField: "cf-ray") != nil { return true }
        if let server = http.value(forHTTPHeaderField: "server")?.lowercased(),
           server.contains("cloudflare") { return true }
        return false
    }

    /// 发一个 WordPress GET（调用方已拼好 URL 与请求头；只用于 GET）。
    /// 返回原始 body 与 HTTP 响应；挑战/断路器抛 WordPressHTTPError。
    /// 请求合并 key = method + URL + 影响响应的请求头 + timeout（F27/G2：
    /// 不同头、不同方法、不同 timeout 的请求不合并）。
    /// 等待者取消（R7-7）：每 waiter 挂自己的 CheckedContinuation（不再裸
    /// `await task.value`——它不响应等待者取消，Grok 最小复现钉死），
    /// onCancel 里把该 waiter 的 continuation 摘掉并立即以 CancellationError
    /// 恢复；只有最后一个 waiter 离开时才 cancel 底层（可能还有别的 waiter
    /// 在等）。底层 Task 完成时批量恢复剩余 waiter 的 continuation。
    func fetch(_ request: URLRequest, source: String, timeout: TimeInterval = 12) async throws -> (Data, HTTPURLResponse) {
        // R4-14：已取消的调用方直接出——不加锁、不建 Task、不进 inFlight。
        try Task.checkCancellation()
        guard let url = request.url else { throw URLError(.badURL) }
        let key = Self.dedupKey(for: request, timeout: timeout)
        let waiterID = UUID()
        // R7-7：加入与挂 continuation 在同一把锁内一次完成（continuation
        // 闭包里做）——条目在加入与挂之间不可能被摘（completeInFlight/
        // cancelWaiter 都要同一把锁），也就没有“任务已完成但 continuation
        // 还没挂上”的窗口。
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                    lock.lock()
                    // 挂之前先看是否已取消——取消发生在挂之前时直接恢复，
                    // 不进字典（否则 onCancel 已跑过，continuation 永无恢复者）。
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if var entry = inFlight[key] {
                        entry.waiterIDs.insert(waiterID)
                        entry.continuations[waiterID] = continuation
                        inFlight[key] = entry
                    } else {
                        // R3-15：条目带 id，底层 Task 完成时按 id 摘条目，
                        // 绝不摘掉复用同一 key 的新条目。
                        let entryID = UUID()
                        let created = Task<(Data, HTTPURLResponse), Error> {
                            do {
                                let result = try await self.perform(request, source: source, timeout: timeout)
                                self.completeInFlight(key: key, id: entryID, result: .success(result))
                                return result
                            } catch {
                                self.completeInFlight(key: key, id: entryID, result: .failure(error))
                                throw error
                            }
                        }
                        inFlight[key] = InFlight(task: created, waiterIDs: [waiterID], continuations: [waiterID: continuation], id: entryID)
                    }
                    lock.unlock()
                }
            } onCancel: {
                self.cancelWaiter(key: key, waiterID: waiterID)
            }
            release(key: key, waiterID: waiterID)
            return result
        } catch {
            release(key: key, waiterID: waiterID)
            throw error
        }
    }

    /// 去重 key：method + URL + 影响响应的请求头（全部请求头按小写名排序后
    /// 拼起来；Cookie/Authorization/自定义头不同 → 不同响应，不能合并；
    /// 合并方向只求不错合，不过合只是少省一次请求）+ timeout。
    private static func dedupKey(for request: URLRequest, timeout: TimeInterval) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        // R3-12：长度前缀编码——"&"/"=" 拼接会碰撞（X: a&y=b 与 X: a + Y: b
        // 拼出来都是 x=a&y=b），不同请求会错合并。
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted(by: { $0.key.lowercased() < $1.key.lowercased() })
            .map { pair -> String in
                let name = pair.key.lowercased()
                return "\(name.utf8.count):\(name)\(pair.value.utf8.count):\(pair.value)"
            }
            .joined()
        return "\(method) \(url) | \(headers) | timeout=\(timeout)"
    }

    /// 一个等待者离开：按 waiter id 从集合里摘掉（已摘过则 no-op，保证
    /// 每个 waiter 只减一次）；减到 0 就从表里摘掉并取消底层请求
    ///（还有等待者时底层请求继续跑，不因某一路取消而断）。
    private func release(key: String, waiterID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = inFlight[key] else { return }
        guard entry.waiterIDs.remove(waiterID) != nil else { return }
        if entry.waiterIDs.isEmpty {
            inFlight.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            inFlight[key] = entry
        }
    }

    /// R7-7：等待者取消——把它的 continuation 从字典摘掉（若在），并把
    /// waiter id 从 waiterIDs 摘掉；摘到空时取消底层 Task、摘条目。
    /// 摘掉的 continuation 在锁外以 CancellationError 恢复（恰好一次；
    /// completeInFlight 抢先摘走时这里拿不到，就不恢复——结果已先到）。
    private func cancelWaiter(key: String, waiterID: UUID) {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        lock.lock()
        if var entry = inFlight[key] {
            continuation = entry.continuations.removeValue(forKey: waiterID)
            if entry.waiterIDs.remove(waiterID) != nil, entry.waiterIDs.isEmpty {
                inFlight.removeValue(forKey: key)
                entry.task.cancel()
            } else {
                inFlight[key] = entry
            }
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    /// 底层 Task 完成时摘条目（id 匹配才摘，绝不摘掉复用同一 key 的新条目）：
    /// 新调用方不再挂到已完成的 Task 上拿陈旧结果（R3-15）。幂等，与
    /// release() 的空集摘除互不冲突（release 在条目已摘时直接 no-op）。
    /// R7-7：摘条目时把全部剩余 continuation 一并带走，锁外按结果逐个恢复
    ///（恰好一次；cancelWaiter 已摘走的不在其中）。
    private func completeInFlight(key: String, id: UUID, result: Result<(Data, HTTPURLResponse), Error>) {
        var continuations: [CheckedContinuation<(Data, HTTPURLResponse), Error>] = []
        lock.lock()
        if let entry = inFlight[key], entry.id == id {
            inFlight.removeValue(forKey: key)
            continuations = Array(entry.continuations.values)
        }
        lock.unlock()
        for continuation in continuations {
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    /// 真正发请求（含单次可控重试）。断路器打开时直接报，不发请求。
    /// F6：一本 deadline——429/5xx/超时重试与 Retry-After/退避全部消耗
    /// 同一个预算，不再每次调 data() 重起一份全额 timeout。
    private func perform(_ request: URLRequest, source: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        // R3-13：请求开始时间——recordSuccess 只清这个时间点之前记的挑战。
        let startedAt = Date()
        let host = request.url?.host?.lowercased() ?? ""
        let deadline = Date().addingTimeInterval(timeout)
        /// 剩余预算；<= 0 时直接抛 .timedOut，不再重试。
        func remaining() throws -> TimeInterval {
            let value = deadline.timeIntervalSinceNow
            guard value > 0 else { throw URLError(.timedOut) }
            return value
        }
        /// 退避等待（R4-12）：只有剩余够睡 + 再发一次（remaining > seconds + 0.5）
        /// 才睡，返回 true；否则返回 false，调用方直接返回响应（429/5xx）或
        /// 重抛原错——不再睡光预算再报个假 .timedOut。
        func backoff(_ seconds: TimeInterval) async throws -> Bool {
            let remainingNow = deadline.timeIntervalSinceNow
            guard remainingNow > seconds + 0.5 else { return false }
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            // R5-11：睡醒再复核一次预算——Task.sleep 可能因定时器合并 /
            // 应用切后台而睡过 deadline；预算没了返回 false，调用方
            // 返回 429/5xx 响应 / 重抛原错，不再继续抛一个假 .timedOut。
            guard deadline.timeIntervalSinceNow > 0.5 else { return false }
            return true
        }
        var attempt = 0
        while true {
            attempt += 1
            // R4-13：断路器每次 attempt 前都重查——并发请求可能在退避睡眠期间
            // 刚撞上挑战开闸；醒来不能直接撞进挑战里。
            lock.lock()
            let lastChallenge = lastChallengeAt[host]
            lock.unlock()
            if let lastChallenge, Date().timeIntervalSince(lastChallenge) < circuitOpenSeconds {
                throw WordPressHTTPError.circuitOpen(host: host)
            }
            // 预算到了就停，不再发起新尝试（直接抛 .timedOut，不进 catch 的重试分支）。
            _ = try remaining()
            do {
                let (data, response) = try await DiagnosticHTTPClient.shared.data(
                    for: request,
                    source: source,
                    preservedHeaders: request.allHTTPHeaderFields ?? [:],
                    timeout: try remaining()
                )
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if Self.isChallenge(response: response) {
                    recordChallenge(host: host)
                    throw WordPressHTTPError.challenge(host: host)
                }
                let status = http.statusCode
                if status == 429, attempt == 1 {
                    let wait = min(retryAfterSeconds(from: http) ?? retryBackoffSeconds, maxRetryAfterSeconds)
                    if try await backoff(wait) { continue }
                    return (data, http)
                }
                if (500...599).contains(status), attempt == 1 {
                    if try await backoff(retryBackoffSeconds) { continue }
                    return (data, http)
                }
                // G3：只有最终 2xx 成功才清挑战记录——429/5xx/超时重试路径
                // 不调，并发里一条重试路径的 recordSuccess 会把另一条刚记下
                // 的挑战记录清掉；404 等非 2xx 也不清（没证明挑战已过）。
                if (200...299).contains(status) {
                    recordSuccess(host: host, requestStartedAt: startedAt)
                }
                return (data, http)
            } catch {
                // 取消立即出，不重试；挑战类错误也不重试。
                if error is CancellationError { throw error }
                if let wpError = error as? WordPressHTTPError { throw wpError }
                // 超时/断连重试 1 次；别的传输错误不重试。
                // R4-12：预算不够睡时 backoff 返回 false，直接重抛原错
                //（不睡、不把原错换成假 .timedOut）。
                if attempt == 1, let urlError = error as? URLError,
                   urlError.code == .timedOut || urlError.code == .networkConnectionLost {
                    if try await backoff(retryBackoffSeconds) { continue }
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

    /// R3-13：只清掉本请求开始之前记的挑战——慢请求 A 的 2xx 不能清掉
    /// 后发的请求 B 刚记下的挑战（否则断路器被慢并发打穿）。
    private func recordSuccess(host: String, requestStartedAt: Date) {
        guard !host.isEmpty else { return }
        lock.lock()
        if let challengeAt = lastChallengeAt[host], challengeAt <= requestStartedAt {
            lastChallengeAt.removeValue(forKey: host)
        }
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
