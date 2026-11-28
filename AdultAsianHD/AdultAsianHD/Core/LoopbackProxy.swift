import Foundation
import Network

// MARK: - 回环代理（Loopback Proxy，P 路）
//
// 梯子 D → P → J 里的一级：只有直接原生播放（D，含拦截器）失败、
// 且失败信号说明代理能帮上忙（分片需头 / 拦截被绕过）时才升级到这里，
// 绝不做默认路线。今天能直连播通的线一律不受影响。
//
// 形态：本机 HTTP 服务器，127.0.0.1 随机端口，路径里带不可猜的 token。
// AVPlayer 只拿到 http://127.0.0.1:<port>/<sessionToken>/<urlToken> 这种地址；
// 代理用自己的 URLSession 去取上游，DNS、出口、身份（UA/Referer/模块头/Cookie）
// 全统一。播单里所有含 URI 的属性与裸 URI 行一律改写成回环地址，
// 密钥、分片、变体、MAP、字幕全部经代理，不留 AVPlayer 直取上游的口子。
//
// 关键点（Claude Q5 定稿，逐项兑现）：
// - 重定向：代理自己跟随上游 3xx，绝不把 Location 交给 AVPlayer；
//   跨域 302 会丢自定义头，重定向请求上把身份头补回去（同 DiagnosticHTTPClient
//   的 PerRequestDelegate 的做法）。
// - 流式转发：分片边收边发，不先下完再回（AVPlayer 首字节预算约 3.5 秒，二手说法，
//   宁可信其有）；播单/密钥小响应先收齐（要改写/要原样服务），再一次发出。
// - 一次性 token：首次真实请求即嗅探，不另做预检 GET；小响应（≤8MB）
//   缓存下来原样服务，AVPlayer 重复请求同一 token 时不再碰上游；
//   大分片不缓存（内存），重试时可能重取上游，一次性 token 会失效——
//   这是已知取舍，账本里能看到（actual 里同一 token 出现两次即说明重取了）。
// - 生命周期：监听挂了（进程挂起、端口冲突）就地重建监听（新随机端口，
//   同一 token、同一缓存），ViewModel 收到 onRestart 后重新生成入口 URL，
//   播放器重建 item、同 generation 下按当前进度续播。
// - 安全：token 不可猜（UUID），Host 头只认 127.0.0.1；回环上任何本机 App
//   理论上都能连，token 就是唯一门禁，不要把 token 写进任何日志。
// - ATS：本机回环 http 不需要额外例外——已编好的包里 NSAppTransportSecurity
//   NSAllowsArbitraryLoads=true（workflow 在 .app 上修的），这里不改 plist。
// - 不做的事：不碰 AirPlay（接收端够不到回环）；不做系统级拦截（NEPacketTunnelProvider
//   属 VPN 类能力，涉及权限与合规）；不给 AVPlayer 喂 WebView 的 cf_clearance。
//
// 线程：NWListener/URLSession 回调各在自己的队列；共享状态（映射、缓存、账本）
// 全由 stateLock 保护；发包只在各连接自己的串行队列上做，不持锁发包。

/// 回环代理的资源种类（账本分类 + 服务方式：播单/变体/密钥先收齐再发，分片/MAP 流式发）。
/// 与 PlaybackLedger.BookKind 共用同一类型（同模块，不另定义）。

/// 代理上游映射：一个 token 对应一个上游 URL。
private struct ProxyMapping {
    let token: String
    let upstream: URL
    let kind: BookKind
}

/// 缓存下来的完整响应（小响应专用）：重试/等候者原样服务，不再碰上游。
private struct CachedResponse {
    let status: Int
    let contentType: String
    /// 只转发白名单里的上游响应头（Content-Range / Accept-Ranges / Cache-Control / ETag / Last-Modified）。
    let headers: [String: String]
    let body: Data
}

/// 一次上游拉取的上下文（一个 URLSessionDataTask 对应一个）。
/// headersSent 前是“还没给 AVPlayer 发过任何字节”：失败时还能改发 502；
/// 一旦发过头，失败只能断连（AVPlayer 自己按失败走）。
private final class ProxyFetchContext {
    let connection: NWConnection
    let queue: DispatchQueue
    let mapping: ProxyMapping
    /// 发起这次拉取的 AVPlayer 请求带的 Range（缓存键的一部分；206 局部响应
    /// 绝不能不分 Range 地发给别的请求）。
    let requestRange: String?
    /// 拉取开始时的网络类（直连/代理）：完成时再读可能已经换网了，诊断要记开始时的。
    let networkClassAtStart: String
    var response: HTTPURLResponse?
    var receivedBytes = 0
    /// 小响应才攒 body（播单要改写、密钥要原样服务）；超 8MB 即放弃缓存、只流式转发。
    var body = Data()
    var cacheable = true
    var headersSent = false
    /// 流式模式（分片/MAP）：头一到就发、body 边收边发；缓冲模式（播单/变体/密钥）：
    /// 收齐再改写/再发。
    let streamMode: Bool
    /// 流式响应的确定长度（上游 Content-Length 有效，或 206 从 Content-Range
    /// 算出）：非 nil 时响应头发 Content-Length、不写 chunked，body 裸发、
    /// 收尾直接断连（P1-1；CoreMedia 对 206 要求 Content-Length，chunked
    /// 会让 seek 后卡死）；nil 时沿用 chunked 流式。
    /// 只在 URLSession 串行回调里读写（didReceive response 里定、data/
    /// didComplete 里读），不用锁（同本类其余字段）。
    var streamContentLength: Int?
    /// 同一 token 已在取、后来又到的连接：取完后从缓存统一服务。
    /// range 各自记着：等候者只配拿自己 Range 对应的响应。
    var waiters: [(connection: NWConnection, queue: DispatchQueue, range: String?)] = []
    /// 流式模式里已经收到响应头的等候者（中途上游断了只能断连，不能再塞 502）。
    var headSentWaiters: [NWConnection] = []
    /// didFinishCollecting 暂存的 metrics（最终分类由 didCompleteWithError 结合
    /// task.error 做，不在收集时就下结论——那时 task.error 常为 nil）。
    var stashedMetrics: URLSessionTaskMetrics?
    /// 响应体前 16KB（WAF 嗅探用；流模式下 body 不全也够判挑战页）。
    var sniffPrefix = Data()

    init(connection: NWConnection, queue: DispatchQueue, mapping: ProxyMapping, requestRange: String? = nil) {
        self.connection = connection
        self.queue = queue
        self.mapping = mapping
        self.requestRange = requestRange
        self.networkClassAtStart = PlaybackLedger.networkClass
        self.streamMode = (mapping.kind == .segment || mapping.kind == .map)
    }
}

final class LoopbackProxyServer: NSObject {

    /// 单个响应可缓存的上限（播单/密钥/小分片都在内；超了只流式转发、不缓存）。
    static let maxCacheableBytes = 8 * 1024 * 1024
    /// 全局缓存上限（FIFO 淘汰最旧的）。
    static let maxCacheBytes = 64 * 1024 * 1024
    /// 监听重建最多试几次（进程挂起后端口没了才重建；一直失败就停，不死循环）。
    static let maxRestartAttempts = 3

    /// 监听起来后 ViewModel 才能生成入口 URL；失败时走梯子下一级。
    /// 只调一次（就绪或重试耗尽）。
    typealias StartCompletion = (Bool) -> Void

    private let headers: [String: String]
    private let listenerQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.loopback.listener", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.loopback.work", qos: .userInitiated)

    private let stateLock = NSLock()
    private var session: URLSession?
    private var listener: NWListener?
    private var boundPort: Int = 0
    private var started = false
    private var startCompletion: StartCompletion?
    private var startCompleted = false
    private var restartAttempts = 0
    private var stopped = false
    /// 本次播放尝试的 session token（URL 路径第一段；stop 即作废）。
    private var sessionToken: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// token → 上游映射。
    private var mappings: [String: ProxyMapping] = [:]
    /// 首个注册的上游 URL（入口播单）：跨源判定锚点。startUpstreamFetch
    /// 里跨源上游不带凭据头（P1-9）；第一个映射就是入口，由 ViewModel
    /// 经 entryURL(for:) 注册。stop 不清映射，这里也不清（同 mappings）。
    private var originURL: URL?
    /// 上游 URL → token（同一上游只注册一次；监听重启换端口时复用 token，
    /// 缓存才不会丢——一次性 token 经不起第二次上游拉取）。
    private var mappingsByUpstream: [String: String] = [:]
    /// 期望账本：改写时记“应该有这个请求”（token、种类、host、路径模板哈希）。
    private var expectedBook: [LedgerBookEntry] = []
    /// 实际账本：真实收到的请求（token、种类、上游状态、字节数、是否走缓存）。
    private var actualBook: [LedgerBookEntry] = []
    /// 响应缓存（token → 完整响应）。
    private var cache: [String: CachedResponse] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes: Int = 0
    /// taskIdentifier → 拉取上下文。
    private var activeTasks: [Int: ProxyFetchContext] = [:]
    /// cacheKey(token:range:) → 在途拉取上下文（从登记占位到拉取收尾；
    /// didCompleteWithError 结束才撤，不然撤掉到进缓存的窗口里后到的请求会再发
    /// 一次上游、烧掉一次性 token）。键必须含 Range：同一 token 的全量与
    /// Range 请求是两次不同的上游拉取，共用一个占位会把 Range 请求错当成
    /// “已在途”挂等候、最后拿到错误长度的响应。
    private var inFlightByKey: [String: ProxyFetchContext] = [:]
    /// 正在服务的连接（stop 时一并断掉）。数组 + 身份比对：
    /// NWConnection 不是 Hashable，不能放 Set；去重与删除都按对象身份（===）。
    private var connections: [NWConnection] = []
    /// 改写后残留的非回环绝对 URL 个数（lint：改写漏了的口子，账本里只记个数）。
    private var rewriteGapCountValue: Int = 0
    /// skd://（FairPlay）：播单里见到了，ViewModel 据此报明确错误（同拦截器）。
    /// 锁保护的写（见 rewriteMatches）与读（写在 URLSession 回调，读在主线程）。
    private var encounteredFairPlay = false

    /// 播单里是否见过 skd://（FairPlay）：锁保护的读。
    func hasEncounteredFairPlay() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return encounteredFairPlay
    }
    /// 监听重启回调（端口变了）：ViewModel 重新生成入口 URL，播放器重建 item 续播。
    private var restartHandler: (() -> Void)?

    /// headers：拦截器同款身份头（iPhone UA + Referer + 模块自定义头 + Cookie），
    /// 代理给每个上游请求带；AVPlayer 只认回环地址，看不到这些头。
    init(headers: [String: String]) {
        self.headers = headers
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - 启动 / 停止

    /// 起监听（随机端口）。就绪调 completion(true)；起不来调 completion(false)，
    /// 调用方直接走梯子下一级，不在这里重试到天荒地老。
    func start(completion: @escaping StartCompletion) {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        startCompletion = completion
        session = URLSession(configuration: ephemeralConfiguration(), delegate: self, delegateQueue: nil)
        stateLock.unlock()
        bindListener()
    }

    private func ephemeralConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        // P1-6：显式关掉缓存与“等网络恢复”——ephemeral 默认无持久缓存，
        // 但 urlCache 不写死 nil 仍可能被上游响应写盘；waitsForConnectivity
        // 默认 false，写死防以后默认值变了把 AVPlayer 的首字节预算拖死。
        config.urlCache = nil
        config.waitsForConnectivity = false
        // 上游慢就早点死，别让 AVPlayer 在首字节预算里空等。
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return config
    }

    /// 监听重启回调：端口变了才调（ViewModel 重新生成入口 URL）。
    func setRestartHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        restartHandler = handler
    }

    /// 停掉一切：监听、会话、在途连接；映射与缓存随 server 一起释放。
    /// ViewModel 换线/停播时调；deinit 也会调（defensive）。
    func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let listener = self.listener
        let session = self.session
        let connections = self.connections
        self.listener = nil
        self.session = nil
        self.connections = []
        stateLock.unlock()
        listener?.cancel()
        session?.invalidateAndCancel()
        for connection in connections {
            connection.cancel()
        }
    }

    /// 绑定监听（随机端口）。就绪后记端口、调 start completion；
    /// 失败则按 maxRestartAttempts 重建（新随机端口），耗尽才报失败。
    /// 只绑回环接口（requiredInterfaceType = .loopback）：不占局域网地址，
    /// 不触发 iOS 本地网络权限提示；AVPlayer 只连 127.0.0.1，本来就不需要别的接口。
    private func bindListener() {
        // P1-6：stop() 后 1 秒重试的 asyncAfter 可能还排着——stop 之后
        // 才跑到这里必须直接收手，不然会起一个没人管的僵尸监听
        //（onListenerFailed 只在失败那一刻查 stopped，1 秒窗口里 stop 拦不住）。
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped else { return }
        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: 0))
        } catch {
            completeStart(success: false)
            return
        }
        stateLock.lock()
        // TOCTOU：NWListener 构造期间 stop() 可能已跑过，第二次加锁写
        // self.listener 前再查一次 stopped，已停就取消刚建的监听直接收手。
        guard !stopped else {
            stateLock.unlock()
            listener.cancel()
            return
        }
        self.listener = listener
        stateLock.unlock()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onListenerReady(listener: listener)
            case .failed:
                self.onListenerFailed()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: listenerQueue)
    }

    private func onListenerReady(listener: NWListener) {
        let port = Int(listener.port?.rawValue ?? 0)
        // port == 0 必须在改状态之前就拦住：旧代码先把 startCompleted 置 true
        // 再调 completeStart(success: false)，后者被 startCompleted 守卫直接
        // 拦回，start 的 completion 永远不回调、调用方永久挂起。
        guard port > 0 else {
            completeStart(success: false)
            return
        }
        stateLock.lock()
        let wasBound = boundPort != 0
        boundPort = port
        let handler = restartHandler
        let completion = startCompletion
        let completed = startCompleted
        if !completed {
            startCompleted = true
            startCompletion = nil
        }
        restartAttempts = 0
        stateLock.unlock()
        // 第一次就绪是“能力已证实”；之后是监听重启换端口。
        PlaybackCapabilities.hasLoopbackProxy = true
        if !completed {
            completion?(true)
        } else if wasBound {
            handler?()
        }
    }

    private func onListenerFailed() {
        stateLock.lock()
        let attempts = restartAttempts
        restartAttempts += 1
        let stopped = stopped
        stateLock.unlock()
        // 已主动 stop（换线/停播）就别再重建、也别再报失败——调用方早已放手。
        guard !stopped else { return }
        guard attempts < Self.maxRestartAttempts else {
            completeStart(success: false)
            return
        }
        // 1 秒后重建监听（新随机端口）；旧监听已死，不用 cancel。
        workQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.bindListener()
        }
    }

    private func completeStart(success: Bool) {
        stateLock.lock()
        guard !startCompleted else {
            stateLock.unlock()
            return
        }
        startCompleted = true
        let completion = startCompletion
        startCompletion = nil
        stateLock.unlock()
        completion?(success)
    }

    // MARK: - 入口 URL 与映射

    /// 入口 URL：把原始播单/媒体 URL 注册成一个 token，返回回环地址。
    /// 同一上游只注册一次（监听重启换端口时复用 token，缓存不丢）。
    /// 调用方（ViewModel）把这个 URL 交给 AVPlayer；没起监听时返回 nil。
    func entryURL(for originalURL: URL) -> URL? {
        let kind: BookKind = isPlaylistURL(originalURL) ? .playlist : .segment
        return loopbackURL(for: originalURL, kind: kind)
    }

    /// 上游 URL → 回环 URL（注册映射 + 记期望账本）。
    private func loopbackURL(for upstream: URL, kind: BookKind) -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard boundPort > 0 else { return nil }
        if originURL == nil { originURL = upstream }
        let key = upstream.absoluteString
        if let token = mappingsByUpstream[key] {
            return URL(string: "http://127.0.0.1:\(boundPort)/\(sessionToken)/\(token)")
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        mappings[token] = ProxyMapping(token: token, upstream: upstream, kind: kind)
        mappingsByUpstream[key] = token
        expectedBook.append(LedgerBookEntry(
            token: String(token.prefix(8)),
            kind: kind,
            host: upstream.host ?? "",
            pathTemplateHash: PlaybackLedger.templateHash(for: key),
            upstreamStatus: nil,
            bytes: nil,
            servedFromCache: false
        ))
        return URL(string: "http://127.0.0.1:\(boundPort)/\(sessionToken)/\(token)")
    }

    private func mapping(for token: String) -> ProxyMapping? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mappings[token]
    }

    /// 入口 URL 快照（跨源判定锚点，锁保护的读）。
    private func snapshotOriginURL() -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return originURL
    }

    private func isPlaylistURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.lowercased().contains(".m3u8")
    }

    // MARK: - 账本快照（ViewModel 终局时取）

    /// 期望账本 + 实际账本的快照（线程安全）。终局时由 ViewModel 合并进账本。
    func bookSnapshot() -> (expected: [LedgerBookEntry], actual: [LedgerBookEntry]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (expectedBook, actualBook)
    }

    /// 期望账本里的路径模板哈希集合（绕过判定用：errorLog 指向其中之一即被绕过）。
    func expectedTemplateHashes() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Set(expectedBook.map { $0.pathTemplateHash })
    }

    /// 改写后残留的非回环绝对 URL 个数（lint 计数，只记个数、不记 URL）。
    func rewriteGapCount() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rewriteGapCountValue
    }

    private func recordActual(mapping: ProxyMapping, status: Int?, bytes: Int, servedFromCache: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        actualBook.append(LedgerBookEntry(
            token: String(mapping.token.prefix(8)),
            kind: mapping.kind,
            host: mapping.upstream.host ?? "",
            pathTemplateHash: PlaybackLedger.templateHash(for: mapping.upstream.absoluteString),
            upstreamStatus: status,
            bytes: bytes,
            servedFromCache: servedFromCache
        ))
    }

    // MARK: - 连接处理

    private func trackConnection(_ connection: NWConnection) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !connections.contains(where: { $0 === connection }) {
            connections.append(connection)
        }
    }

    private func untrackConnection(_ connection: NWConnection) {
        stateLock.lock()
        defer { stateLock.unlock() }
        connections.removeAll { $0 === connection }
    }

    private func closeConnection(_ connection: NWConnection) {
        untrackConnection(connection)
        connection.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let queue = DispatchQueue(label: "com.liudehen.xiaoshipin.loopback.conn")
        trackConnection(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.readRequestHead(connection: connection, queue: queue, buffer: Data())
            case .failed, .cancelled:
                self.untrackConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// 读请求头（读到 \r\n\r\n 为止，最多 16KB；AVPlayer 只发 GET、无 body）。
    private func readRequestHead(connection: NWConnection, queue: DispatchQueue, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                self.closeConnection(connection)
                return
            }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handleRequest(connection: connection, queue: queue, headData: Data(buf[..<range.lowerBound]))
                return
            }
            if buf.count > 16384 || isComplete {
                self.closeConnection(connection)
                return
            }
            self.readRequestHead(connection: connection, queue: queue, buffer: buf)
        }
    }

    /// 请求分发：只认 GET + Host 127.0.0.1 + 路径 /<sessionToken>/<urlToken>。
    /// 缓存命中直接原样服务；同一 token 正在取则挂等候；否则发起上游拉取。
    private func handleRequest(connection: NWConnection, queue: DispatchQueue, headData: Data) {
        guard let head = String(data: headData, encoding: .utf8) else {
            sendSimpleResponse(connection: connection, queue: queue, status: 400, body: "Bad Request")
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendSimpleResponse(connection: connection, queue: queue, status: 400, body: "Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendSimpleResponse(connection: connection, queue: queue, status: 405, body: "Method Not Allowed")
            return
        }
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        // Host 校验：只认回环（别的 host 来的请求一律 404，token 再对也白搭）。
        // Host 带端口（127.0.0.1:PORT）是常态；只认 127.0.0.1 本身或带端口的形式，
        // 不认 127.0.0.10 这种前缀擦边的地址。
        let host = headers["host"] ?? ""
        guard host == "127.0.0.1" || host.hasPrefix("127.0.0.1:") else {
            sendSimpleResponse(connection: connection, queue: queue, status: 404, body: "Not Found")
            return
        }
        let components = path.split(separator: "/").map(String.init)
        stateLock.lock()
        let token = sessionToken
        stateLock.unlock()
        guard components.count == 2, components[0] == token else {
            sendSimpleResponse(connection: connection, queue: queue, status: 404, body: "Not Found")
            return
        }
        let urlToken = components[1]
        guard let mapping = mapping(for: urlToken) else {
            sendSimpleResponse(connection: connection, queue: queue, status: 404, body: "Not Found")
            return
        }
        // 缓存命中、等候挂靠、还是新起上游拉取：一次锁里定（检查与登记原子化，
        // 两连接同时到同一 token 时只有一个能发起上游请求，一次性 token 不被重复消费）。
        switch decideFetch(mapping: mapping, range: headers["range"], connection: connection, queue: queue) {
        case .serveCached(let cached):
            recordActual(mapping: mapping, status: cached.status, bytes: cached.body.count, servedFromCache: true)
            serveCached(connection: connection, queue: queue, mapping: mapping, cached: cached)
        case .attached:
            return
        case .send502:
            recordActual(mapping: mapping, status: nil, bytes: 0, servedFromCache: false)
            sendSimpleResponse(connection: connection, queue: queue, status: 502, body: "Bad Gateway")
        case .startFetch(let context):
            startUpstreamFetch(context: context)
        }
        return
    }

    // MARK: - 上游拉取（URLSessionDataDelegate 流式转发）

    /// 取数决策（一次锁里完成：查缓存 → 查在途 → 登记占位）。
    /// 返回后调用方在锁外行动（发包/建 task 都不在锁里做，不持锁发包）。
    private enum FetchDecision {
        case serveCached(CachedResponse)
        case attached
        case send502
        case startFetch(ProxyFetchContext)
    }

    private func decideFetch(mapping: ProxyMapping, range: String?, connection: NWConnection, queue: DispatchQueue) -> FetchDecision {
        stateLock.lock()
        // 1. 缓存命中（键 = token + Range：206 局部响应只服务同 Range 的请求）。
        let key = cacheKey(token: mapping.token, range: range)
        if let cached = cache[key] {
            stateLock.unlock()
            return .serveCached(cached)
        }
        // 2. 同一 token + 同 Range 正在取。
        if let context = inFlightByKey[key] {
            if !context.headersSent {
                context.waiters.append((connection: connection, queue: queue, range: range))
                stateLock.unlock()
                return .attached
            }
            // 已发过头：缓存有（同 Range）就原样服务，否则 502（重复请求错过了直播流）。
            if let cached = cache[key] {
                stateLock.unlock()
                return .serveCached(cached)
            }
            stateLock.unlock()
            return .send502
        }
        // 3. 没人取：登记占位（建 task 前就占住，别的连接再来只能挂等候）。
        let context = ProxyFetchContext(connection: connection, queue: queue, mapping: mapping, requestRange: range)
        inFlightByKey[key] = context
        stateLock.unlock()
        return .startFetch(context)
    }

    private func startUpstreamFetch(context: ProxyFetchContext) {
        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session else {
            // 会话没了（已 stop）：撤掉占位，主连接和已挂上的等候者都给 502。
            stateLock.lock()
            inFlightByKey.removeValue(forKey: cacheKey(token: context.mapping.token, range: context.requestRange))
            let waiters = context.waiters
            stateLock.unlock()
            sendSimpleResponse(connection: context.connection, queue: context.queue, status: 502, body: "Bad Gateway")
            for waiter in waiters {
                sendSimpleResponse(connection: waiter.connection, queue: waiter.queue, status: 502, body: "Bad Gateway")
            }
            return
        }
        var request = URLRequest(url: context.mapping.upstream)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        request.timeoutInterval = 15
        // 身份头由代理统一带（UA/Referer/模块头/Cookie）；AVPlayer 发来的头只转发 Range
        //（MP4 用它；其余一律以代理的为准，不把 AppleCoreMedia 之类带去上游）。
        // P1-9：跨源上游（第三方 CDN 分片/密钥/变体）跳过凭据头——锚点是入口
        // URL（首个注册的上游），不是本次上游自身（自身恒同源，判了等于没判）。
        let sameOrigin = NetConstants.isSameOrigin(snapshotOriginURL(), context.mapping.upstream)
        for (key, value) in headers {
            if !sameOrigin && NetConstants.isSensitiveHeader(key) { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        // P1-5：显式要原样字节（Accept-Encoding: identity）。不写的话
        // URLSession 会自动发 gzip 并透明解压：上游 Content-Length 是压缩后
        // 的长度，解压后实际字节更多，按压缩长度发会截断流。放 headers 循环
        // 之后写死，模块自定义头里的 Accept-Encoding 也盖不掉它。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = context.requestRange {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        stateLock.lock()
        activeTasks[task.taskIdentifier] = context
        stateLock.unlock()
        task.resume()
    }

    private func context(for task: URLSessionTask) -> ProxyFetchContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeTasks[task.taskIdentifier]
    }

    /// 拉取收尾时才撤（didCompleteWithError 的 defer 里调）：缓存/改写完成前不撤，
    /// 不然撤掉到进缓存的窗口里后到的请求会再发一次上游、烧掉一次性 token。
    private func removeContext(for task: URLSessionTask) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let context = activeTasks.removeValue(forKey: task.taskIdentifier) {
            inFlightByKey.removeValue(forKey: cacheKey(token: context.mapping.token, range: context.requestRange))
        }
    }

    /// waiters 与 headersSent 跨队列读写（监听队列挂等候、URLSession 队列发包），
    /// 用 stateLock 保护；context 的其余字段只在 URLSession 串行回调里碰，不用锁。
    private func isHeadersSent(_ context: ProxyFetchContext) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context.headersSent
    }

    private func setHeadersSent(_ context: ProxyFetchContext) {
        stateLock.lock()
        defer { stateLock.unlock() }
        context.headersSent = true
    }

    /// 原子切换：把 headersSent 置 true 并取出当时全部等候者，同时记下
    /// 哪些等候者收到了响应头（headedWaiters=true 时，流式模式用）。
    /// 先快照再置旗会让中间到的 waiter 永远收不到头（只收到无头的分块 body），
    /// 必须一次锁里同时做完。
    private func markHeadersSent(_ context: ProxyFetchContext, headedWaiters: Bool) -> [(connection: NWConnection, queue: DispatchQueue, range: String?)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        context.headersSent = true
        if headedWaiters {
            context.headSentWaiters.append(contentsOf: context.waiters.map { $0.connection })
        }
        return context.waiters
    }

    private func snapshotWaiters(_ context: ProxyFetchContext) -> [(connection: NWConnection, queue: DispatchQueue, range: String?)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context.waiters
    }

    /// 已收到响应头的等候者（中途上游断了只能断连，不能再塞响应）。
    private func snapshotHeadSentWaiters(_ context: ProxyFetchContext) -> [NWConnection] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context.headSentWaiters
    }

    // MARK: - 播单改写（通用 URI 属性，不写死名单）

    /// 播单逐行改写：所有含 URI 的属性（URI="…"、SERVER-URI="…"、X-ASSET-URI="…" 等）
    /// 与 EXT-X-DEFINE 里 VALUE="http…" 的绝对 URL 一律改回环；裸 URI 行
    /// （变体播单/分片）解析成绝对路径后改回环；其余行原样。
    /// skd://（FairPlay）不动、记旗（ViewModel 据此报明确错误）；
    /// data: 内联密钥不动（AVPlayer 自己处理）。
    /// 返回改写后的文本；改写出的映射已记进期望账本。
    private func rewritePlaylist(_ text: String, baseURL: URL) -> String {
        // P1-3 同款归一化：CRLF 播单用 .newlines 拆会多出空串 ""，
        // 空串不能把 nextLineIsVariant 清零（见下）。
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        // P1-6：跟踪 #EXT-X-STREAM-INF:——下一行裸 URI 就是变体播单，
        // 哪怕没有 .m3u8 扩展名也必须记成 .variant（走缓冲模式改写）。
        // 不跟踪时它会被判成 .segment 走 streamMode：变体播单被原样流式
        // 转发、里面的内层 URI 不改写，AVPlayer 会直取上游、绕过代理。
        var nextLineIsVariant = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // 纯空白行不重置 nextLineIsVariant（同 HLSResourceLoader）。
                out.append(line)
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                nextLineIsVariant = true
                out.append(rewriteURIAttributes(in: line, baseURL: baseURL))
                continue
            }
            if line.hasPrefix("#") {
                out.append(rewriteURIAttributes(in: line, baseURL: baseURL))
                nextLineIsVariant = false
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let absolute = absoluteURL(trimmed, base: baseURL)
                let kind: BookKind = (nextLineIsVariant || isPlaylistURL(absolute)) ? .variant : .segment
                nextLineIsVariant = false
                if let loopback = loopbackURL(for: absolute, kind: kind) {
                    out.append(loopback.absoluteString)
                } else {
                    out.append(line)
                }
            } else {
                out.append(line)
            }
        }
        let rewritten = out.joined(separator: "\n")
        // lint：改写后还残留的非回环绝对 URL（DEFINE 展开前的变量、漏掉的属性……），
        // 只记个数，不记 URL——有残留即说明仍有 AVPlayer 直取上游的口子。
        let gapCount = countRemainingAbsoluteURLs(in: rewritten)
        if gapCount > 0 {
            stateLock.lock()
            rewriteGapCountValue += gapCount
            stateLock.unlock()
        }
        return rewritten
    }

    /// 一行里的 URI 属性改写（从后往前换，range 才不会错位）。
    private func rewriteURIAttributes(in line: String, baseURL: URL) -> String {
        var result = line
        // 1) 任何以 URI 结尾的属性：URI="…"、SERVER-URI="…"、X-ASSET-URI="…"。
        result = rewriteMatches(
            in: result,
            pattern: "([A-Za-z0-9_-]*URI)=\"([^\"]+)\"",
            baseURL: baseURL,
            tag: line
        )
        // 2) EXT-X-DEFINE 的 VALUE="http…"（绝对 URL 才改；相对值/纯字符串不动）。
        result = rewriteMatches(
            in: result,
            pattern: "(VALUE)=\"(https?://[^\"]+)\"",
            baseURL: baseURL,
            tag: line
        )
        return result
    }

    /// 正则替换：每处匹配到的 URL 解析成绝对路径后注册成回环 URL。
    /// skd:// 与 data: 不改（前者记 FairPlay 旗，后者是内联密钥）。
    private func rewriteMatches(in text: String, pattern: String, baseURL: URL, tag: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let valueRange = match.range(at: 2)
            let raw = nsText.substring(with: valueRange)
            if raw.hasPrefix("data:") { continue }
            let absolute = absoluteURL(raw, base: baseURL)
            if absolute.scheme == "skd" || absolute.scheme == "skds" {
                stateLock.lock()
                encounteredFairPlay = true
                stateLock.unlock()
                continue
            }
            let kind = kindFor(tag: tag, url: absolute)
            guard let loopback = loopbackURL(for: absolute, kind: kind) else { continue }
            mutable.replaceCharacters(in: valueRange, with: loopback.absoluteString)
        }
        return mutable as String
    }

    /// URI 属性的资源种类：KEY 行 → key；MAP 行 → map；.m3u8 → 变体/播单；其余 → 分片。
    private func kindFor(tag: String, url: URL) -> BookKind {
        if tag.hasPrefix("#EXT-X-KEY") || tag.hasPrefix("#EXT-X-SESSION-KEY") { return .key }
        if tag.hasPrefix("#EXT-X-MAP") { return .map }
        // 无 .m3u8 扩展名的音轨/字幕/I 帧子播单也走变体（缓冲改写），
        // 不当分片原样流式转发。
        if tag.hasPrefix("#EXT-X-MEDIA") || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") { return .variant }
        if isPlaylistURL(url) { return .variant }
        return .segment
    }

    /// 改写后残留的非回环绝对 URL 个数（lint 用）。
    private func countRemainingAbsoluteURLs(in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+", options: []) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var count = 0
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            if !text[r].hasPrefix("http://127.0.0.1") {
                count += 1
            }
        }
        return count
    }

    /// 相对路径按播单所在 URL 解析成绝对路径；已是绝对路径原样返回。
    private func absoluteURL(_ raw: String, base: URL) -> URL {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL ?? base
    }

    /// 按扩展名给分片/MAP 定 Content-Type（播单与密钥由 kind 定，不走这里）。
    private func contentType(for mapping: ProxyMapping, response: HTTPURLResponse) -> String {
        switch mapping.kind {
        case .playlist, .variant:
            return "application/vnd.apple.mpegurl"
        case .key:
            return "application/octet-stream"
        case .segment, .map:
            switch mapping.upstream.pathExtension.lowercased() {
            case "ts": return "video/mp2t"
            case "m4s": return "video/iso.segment"
            case "mp4": return "video/mp4"
            default:
                return response.mimeType ?? "application/octet-stream"
            }
        }
    }

    // MARK: - 缓存

    /// 缓存键：token + Range。206 局部响应只服务同 Range 的请求——
    /// 旧逻辑只按 token 查，2 字节探测响应可能被缓存后返回给所有 Range 请求。
    private func cacheKey(token: String, range: String?) -> String {
        guard let range, !range.isEmpty else { return token }
        return "\(token)|\(range)"
    }

    private func cachedResponse(for token: String, range: String?) -> CachedResponse? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache[cacheKey(token: token, range: range)]
    }

    /// 小响应进缓存（FIFO，总量 ≤64MB，超了淘汰最旧的）。
    private func cacheResponse(token: String, range: String?, response: CachedResponse) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let key = cacheKey(token: token, range: range)
        if cache[key] == nil {
            cacheOrder.append(key)
        } else {
            cacheBytes -= cache[key]?.body.count ?? 0
        }
        cache[key] = response
        cacheBytes += response.body.count
        while cacheBytes > Self.maxCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cacheBytes -= removed.body.count
            }
        }
    }

    // MARK: - 发包（chunked 流式；各连接在自己的串行队列上发，不持锁）

    private func send(connection: NWConnection, queue: DispatchQueue, data: Data, isComplete: Bool, contentContext: NWConnection.ContentContext = .defaultMessage, onComplete: (() -> Void)? = nil) {
        queue.async {
            connection.send(content: data, contentContext: contentContext, isComplete: isComplete, completion: .contentProcessed { _ in onComplete?() })
        }
    }

    /// 响应头（chunked；Content-Length 不转发——分块编码替它；只转发白名单里的上游头）。
    /// P1-1：contentLength != nil 时带 Content-Length、不写 chunked——
    /// CoreMedia 对 206 要求 Content-Length，chunked 会让 seek 后卡死
    ///（见 sendFullResponse 注释）；nil 时沿用 chunked 流式。
    private func responseHead(status: Int, contentType: String, response: HTTPURLResponse?, contentLength: Int? = nil) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        if let response {
            for field in ["Content-Range", "Accept-Ranges", "Cache-Control", "ETag", "Last-Modified"] {
                if let value = response.value(forHTTPHeaderField: field) {
                    head += "\(field): \(value)\r\n"
                }
            }
        }
        if let contentLength {
            head += "Content-Length: \(contentLength)\r\n"
        } else {
            head += "Transfer-Encoding: chunked\r\n"
        }
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8)
    }

    /// 流式响应可用的确定长度：上游 Content-Length 有效即用（206 一定有、
    /// 200 常有）；206 无 Content-Length 时从 Content-Range
    /// "bytes a-b/total" 取 b-a+1。拿不到则 nil（走 chunked）。
    private func streamContentLength(for response: HTTPURLResponse) -> Int? {
        // P1-5：上游若无视 Accept-Encoding: identity 仍返回 gzip（或别的
        // Content-Encoding），URLSession 透明解压后实际字节会大于这里读到的
        // 压缩 Content-Length——按它发 Content-Length 会截断流。编码非空且
        // 非 identity 时返回 nil，走 chunked，不再信这个长度。
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            return nil
        }
        if let raw = response.value(forHTTPHeaderField: "Content-Length")?.trimmingCharacters(in: .whitespaces),
           let n = Int(raw), n >= 0 {
            return n
        }
        guard response.statusCode == 206,
              let cr = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        // "bytes 0-99/1000" → 100；"bytes */1000" 这种无范围的返回 nil。
        let rangePart = cr.split(separator: " ").last?.split(separator: "/").first ?? ""
        let bounds = rangePart.split(separator: "-")
        guard bounds.count == 2,
              let lo = Int(bounds[0]), let hi = Int(bounds[1]), hi >= lo else { return nil }
        let (diff, o1) = hi.subtractingReportingOverflow(lo)
        let (len, o2) = diff.addingReportingOverflow(1)
        guard !o1, !o2 else { return nil }
        return len
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }

    /// 一块 body 数据包成分块格式发出（不完结，等后续块或终结块）。
    private func sendChunk(connection: NWConnection, queue: DispatchQueue, data: Data) {
        guard !data.isEmpty else { return }
        var packet = Data("\(String(data.count, radix: 16))\r\n".utf8)
        packet.append(data)
        packet.append(Data("\r\n".utf8))
        send(connection: connection, queue: queue, data: packet, isComplete: false)
    }

    /// 流式 body 一块：定长模式（头里是 Content-Length）裸发，chunked 模式包 chunk 帧。
    private func sendStreamData(connection: NWConnection, queue: DispatchQueue, data: Data, chunked: Bool) {
        guard !data.isEmpty else { return }
        if chunked {
            sendChunk(connection: connection, queue: queue, data: data)
        } else {
            send(connection: connection, queue: queue, data: data, isComplete: false)
        }
    }

    /// 终结块：0 长度块，完结本次响应。发完后才断连（.finalMessage + 完成回调里
    /// cancel）：旧逻辑 send 完就地 untrackConnection，末尾分块可能还没发出去
    /// 连接就从表里掉了，AVPlayer 收不到收尾就报错。
    private func sendTerminalChunk(connection: NWConnection, queue: DispatchQueue) {
        send(connection: connection, queue: queue, data: Data("0\r\n\r\n".utf8), isComplete: true, contentContext: .finalMessage) {
            self.untrackConnection(connection)
            connection.cancel()
        }
    }

    /// 定长流式收尾：不发 chunk 终结块（头里是 Content-Length，终结块会
    /// 变成多余字节），直接完结连接。发完才断连，同 sendTerminalChunk。
    private func sendClose(connection: NWConnection, queue: DispatchQueue) {
        send(connection: connection, queue: queue, data: Data(), isComplete: true, contentContext: .finalMessage) {
            self.untrackConnection(connection)
            connection.cancel()
        }
    }

    /// 简单错误响应（带 Content-Length、一次发完）。发完才断连，同上。
    private func sendSimpleResponse(connection: NWConnection, queue: DispatchQueue, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Content-Type: text/plain\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        send(connection: connection, queue: queue, data: payload, isComplete: true, contentContext: .finalMessage) {
            self.untrackConnection(connection)
            connection.cancel()
        }
    }

    /// 已知长度的完整响应（Content-Length，不走 chunked）：缓存响应与缓冲型
    /// 非 2xx 响应都用它——CoreMedia 对 206 响应要求 Content-Length，
    /// chunked 会让它在 seek 后卡死。发完断连。
    private func sendFullResponse(connection: NWConnection, queue: DispatchQueue, status: Int, contentType: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        for (field, value) in headers {
            head += "\(field): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        send(connection: connection, queue: queue, data: payload, isComplete: true, contentContext: .finalMessage) {
            self.untrackConnection(connection)
            connection.cancel()
        }
    }

    /// 缓存命中的完整响应：原样服务（Content-Length、一次发完，不走 chunked）。
    private func serveCached(connection: NWConnection, queue: DispatchQueue, mapping: ProxyMapping, cached: CachedResponse) {
        sendFullResponse(
            connection: connection, queue: queue,
            status: cached.status,
            contentType: cached.contentType,
            headers: cached.headers,
            body: cached.body
        )
    }

    /// 等候者统一服务。
    /// - error != nil：还没收到响应头的给 502；已收到头的只能断连（再塞一个响应
    ///   进已开始的 chunked 流，AVPlayer 会报协议错——旧逻辑全给 502）。
    /// - response != nil：缓冲型非 2xx 的真实状态/body（等候者不再被 502 冤枉）。
    /// - 否则从缓存按等候者自己的 Range 取（Range 不同拿到的 206 响应不同）。
    private func serveWaiters(context: ProxyFetchContext, error: Error?, response: CachedResponse? = nil) {
        let waiters = snapshotWaiters(context)
        guard !waiters.isEmpty else { return }
        let headed = Set(snapshotHeadSentWaiters(context).map { ObjectIdentifier($0) })
        for waiter in waiters {
            if headed.contains(ObjectIdentifier(waiter.connection)) {
                closeConnection(waiter.connection)
                continue
            }
            if let error {
                recordActual(mapping: context.mapping, status: nil, bytes: 0, servedFromCache: false)
                sendSimpleResponse(connection: waiter.connection, queue: waiter.queue, status: 502, body: "Bad Gateway")
                continue
            }
            if let response {
                recordActual(mapping: context.mapping, status: response.status, bytes: response.body.count, servedFromCache: false)
                serveCached(connection: waiter.connection, queue: waiter.queue, mapping: context.mapping, cached: response)
                continue
            }
            if let cached = cachedResponse(for: context.mapping.token, range: waiter.range) {
                recordActual(mapping: context.mapping, status: cached.status, bytes: cached.body.count, servedFromCache: true)
                serveCached(connection: waiter.connection, queue: waiter.queue, mapping: context.mapping, cached: cached)
            } else {
                recordActual(mapping: context.mapping, status: nil, bytes: 0, servedFromCache: false)
                sendSimpleResponse(connection: waiter.connection, queue: waiter.queue, status: 502, body: "Bad Gateway")
            }
        }
    }
}

// MARK: - URLSessionDataDelegate（上游拉取，流式转发）

extension LoopbackProxyServer: URLSessionDataDelegate, URLSessionTaskDelegate {

    /// 重定向：代理自己跟随，绝不把 Location 交给 AVPlayer；
    /// 跨域 302 会丢自定义头，重定向请求上把身份头补回去——但凭据头
    /// （Authorization / Cookie / API key）只在同源（scheme+host+端口）时保留，
    /// 跨域或 HTTPS→HTTP 降级一律不带（与 DiagnosticHTTPClient 的
    /// PerRequestDelegate 同款做法）。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // 拒非 http(s) 重定向目标：直接交回 3xx 响应，别让 CFNetwork 对
        // javascript:/file:///intent: 之类报 -1002（与 PerRequestDelegate 同款）。
        guard let targetURL = request.url,
              let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.assumesHTTP3Capable = false
        // P1-5：同源锚点是入口 URL（首个注册的上游，snapshotOriginURL()），
        // 不是本次请求的原始 URL（task.originalRequest）：跨源 CDN 分片 B
        // 302 到同域 B2 时，按 task.originalRequest（B）判会判同源、把源站 A
        // 的 Cookie / Authorization 重新发给第三方 CDN B2；按入口 A 判
        // 才是跨源，凭据头不跟过去。task.originalRequest 只作入口未记时的兜底。
        let sameOrigin = NetConstants.isSameOrigin(snapshotOriginURL() ?? task.originalRequest?.url, redirected.url)
        for (key, value) in headers {
            let lower = key.lowercased()
            if !sameOrigin && NetConstants.isSensitiveHeader(key) { continue }
            // Host/Content-Length 由 CFNetwork 自己管；跳步头（Connection/
            // Transfer-Encoding/Keep-Alive/Proxy-Connection/Upgrade）上 H2/H3
            // 会违反 RFC 9113/9114，直接 RST_STREAM（与 PerRequestDelegate 同款）。
            if lower == "host" || lower == "content-length" || lower == "connection"
                || lower == "transfer-encoding" || lower == "keep-alive"
                || lower == "proxy-connection" || lower == "upgrade" { continue }
            // 不覆盖重定向途中的新值：只补缺失的头（无条件 setValue 会盖掉
            // 服务端在重定向里新给的 Cookie/头）。
            if redirected.value(forHTTPHeaderField: key) == nil {
                redirected.setValue(value, forHTTPHeaderField: key)
            }
        }
        if !sameOrigin {
            // CFNetwork 会把上一跳的自定义头自动复制到 redirected 上；只跳过
            // 从 self.headers 补加敏感头不够，必须把 redirected 上已继承的
            // 敏感头也删掉，否则凭据跨域泄漏。
            if let fields = redirected.allHTTPHeaderFields {
                for key in fields.keys where NetConstants.isSensitiveHeader(key) {
                    redirected.setValue(nil, forHTTPHeaderField: key)
                }
            }
            // 跨域重定向也要原样字节，不让上游 gzip。
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        completionHandler(redirected)
    }

    /// 只暂存 metrics：这时 task.error 常为 nil、body 还没拼完，在这里就
    /// 下结论会把超时判错层；最终分类由 didCompleteWithError 结合 task.error 做。
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let context = context(for: task) else { return }
        context.stashedMetrics = metrics
    }

    /// 上游响应头到了：流式模式立刻把头送给 AVPlayer（首字节预算）；
    /// 缓冲模式（播单/变体/密钥）先攒着，等收齐改写/原样服务。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let context = context(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        context.response = http
        if context.streamMode {
            // 定长（206 / 有 Content-Length）走 Content-Length、不写 chunked（P1-1）。
            let contentLength = streamContentLength(for: http)
            context.streamContentLength = contentLength
            let head = responseHead(status: http.statusCode, contentType: contentType(for: context.mapping, response: http), response: http, contentLength: contentLength)
            // 一次锁里同时做：置 headersSent + 取等候者 + 记下哪些等候者收到了头。
            // 旧逻辑先快照再置旗，中间到的 waiter 永远收不到头（只收到无头的分块 body）。
            let waiters = markHeadersSent(context, headedWaiters: true)
            send(connection: context.connection, queue: context.queue, data: head, isComplete: false)
            for waiter in waiters {
                send(connection: waiter.connection, queue: waiter.queue, data: head, isComplete: false)
            }
        }
        completionHandler(.allow)
    }

    /// 上游 body 到了：流式模式立刻转发一块（等候者 tee 同一块）；同时攒起来
    /// （≤8MB 才攒，超了即放弃缓存）——小分片/密钥进缓存后，AVPlayer 重复请求
    /// 同一 token 时不再碰上游（一次性 token 就靠这个）。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = context(for: dataTask) else { return }
        context.receivedBytes += data.count
        // 响应体前 16KB 嗅探前缀（WAF 挑战页判定用；流模式 body 不攒全也够判）。
        if context.sniffPrefix.count < 16384 {
            context.sniffPrefix.append(data.prefix(16384 - context.sniffPrefix.count))
        }
        if context.streamMode {
            let chunked = context.streamContentLength == nil
            sendStreamData(connection: context.connection, queue: context.queue, data: data, chunked: chunked)
            for waiter in snapshotWaiters(context) {
                sendStreamData(connection: waiter.connection, queue: waiter.queue, data: data, chunked: chunked)
            }
        }
        if context.cacheable {
            context.body.append(data)
            if context.body.count > Self.maxCacheableBytes {
                context.cacheable = false
                context.body = Data()
                // P1-6：缓冲模式（播单/变体/密钥）超 8MB 时 body 已丢，
                // 不取消的话 didComplete 会按 200 空体发出去。直接取消上游
                // 拉取，走 didCompleteWithError 的 502 路径；流式模式
                // （分片/MAP）大分片本来就是边收边发，不取消。
                if !context.streamMode {
                    dataTask.cancel()
                }
            }
        }
    }

    /// 上游拉取结束：成功则收尾（缓冲模式改写/原样服务 + 进缓存；流式模式发终结块），
    /// 记实际账本，等候者统一服务；失败则记账本、给 502 或断连。
    /// 上下文只在收尾完成才撤（defer removeContext）：缓存/改写完成前不撤，
    /// 不然撤掉到进缓存的窗口里后到的请求会再发一次上游、烧掉一次性 token。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = context(for: task) else { return }
        defer { removeContext(for: task) }

        // 诊断事件在这里最终记：用暂存的 metrics + 现在的 task.error（这时才准），
        // body 用 16KB 嗅探前缀判 WAF，host 按最终重定向落点记。
        let diagRequest = task.currentRequest ?? task.originalRequest ?? URLRequest(url: context.mapping.upstream)
        let diagEvent = NetworkDiagnostics.makeEvent(
            source: "proxy",
            request: diagRequest,
            response: task.response,
            bodyData: context.sniffPrefix.isEmpty ? nil : context.sniffPrefix,
            error: error,
            metrics: context.stashedMetrics,
            fallbackDurationMs: 0,
            networkClass: context.networkClassAtStart
        )
        NetworkDiagnostics.record(diagEvent)

        if let error {
            recordActual(mapping: context.mapping, status: nil, bytes: context.receivedBytes, servedFromCache: false)
            if !isHeadersSent(context) {
                sendSimpleResponse(connection: context.connection, queue: context.queue, status: 502, body: "Bad Gateway")
            } else {
                closeConnection(context.connection)
            }
            serveWaiters(context: context, error: error)
            return
        }
        let status = context.response?.statusCode ?? 0
        if context.streamMode {
            // 流式：小响应进缓存（供重试原样服务，不再碰上游）；大分片只转发、不缓存。
            // P1-2：只缓存 2xx——403/429/502/503 的小体积错误页进缓存后，
            // AVPlayer 后续重试永远命中错误页。
            if context.cacheable, let http = context.response, (200...299).contains(http.statusCode) {
                cacheResponse(token: context.mapping.token, range: context.requestRange, response: CachedResponse(
                    status: http.statusCode,
                    contentType: contentType(for: context.mapping, response: http),
                    headers: forwardedHeaders(from: http),
                    body: context.body
                ))
            }
            recordActual(mapping: context.mapping, status: status, bytes: context.receivedBytes, servedFromCache: false)
            let waiters = snapshotWaiters(context)
            // 定长模式收尾直接断连（不发 chunk 终结块）；chunked 模式发终结块。
            let chunked = context.streamContentLength == nil
            if chunked {
                sendTerminalChunk(connection: context.connection, queue: context.queue)
            } else {
                sendClose(connection: context.connection, queue: context.queue)
            }
            for waiter in waiters {
                recordActual(mapping: context.mapping, status: status, bytes: context.receivedBytes, servedFromCache: false)
                if chunked {
                    sendTerminalChunk(connection: waiter.connection, queue: waiter.queue)
                } else {
                    sendClose(connection: waiter.connection, queue: waiter.queue)
                }
            }
            return
        }
        // 缓冲模式：收齐了再处理。
        guard let http = context.response else {
            recordActual(mapping: context.mapping, status: nil, bytes: context.receivedBytes, servedFromCache: false)
            sendSimpleResponse(connection: context.connection, queue: context.queue, status: 502, body: "Bad Gateway")
            serveWaiters(context: context, error: NSError(domain: "LoopbackProxy", code: -1, userInfo: nil))
            return
        }
        // 上游非 2xx：不改写，原样把状态与 body 交给 AVPlayer 和等候者
        //（账本记 rejectedUpstream）。旧逻辑主连接拿真 403、等候者却拿 502。
        guard (200...299).contains(http.statusCode) else {
            recordActual(mapping: context.mapping, status: http.statusCode, bytes: context.body.count, servedFromCache: false)
            let non2xx = CachedResponse(
                status: http.statusCode,
                contentType: contentType(for: context.mapping, response: http),
                headers: forwardedHeaders(from: http),
                body: context.body
            )
            setHeadersSent(context)
            sendFullResponse(
                connection: context.connection, queue: context.queue,
                status: non2xx.status,
                contentType: non2xx.contentType,
                headers: non2xx.headers,
                body: non2xx.body
            )
            serveWaiters(context: context, error: nil, response: non2xx)
            return
        }
        // 2xx：播单/变体改写后发，密钥原样发；可缓存的进缓存（供重试原样服务）。
        // P1-6 兜底：缓冲模式超 8MB 时 body 已在 didReceive 里清空丢弃
        //（cacheable=false），取消若没生效、走到这里也绝不能发 200 空体。
        if !context.cacheable {
            recordActual(mapping: context.mapping, status: nil, bytes: context.receivedBytes, servedFromCache: false)
            sendSimpleResponse(connection: context.connection, queue: context.queue, status: 502, body: "Bad Gateway")
            serveWaiters(context: context, error: NSError(domain: "LoopbackProxy", code: -1, userInfo: [NSLocalizedDescriptionKey: "响应超 8MB 缓冲上限"]))
            return
        }
        let outBody: Data
        if context.mapping.kind == .playlist || context.mapping.kind == .variant {
            let text = String(decoding: context.body, as: UTF8.self)
            // 只对真播单改写：HTML/WAF 挑战页 / JSON 错误页混进来不能当播单改写、缓存。
            guard text.contains("#EXTM3U") else {
                recordActual(mapping: context.mapping, status: http.statusCode, bytes: context.body.count, servedFromCache: false)
                let passthrough = CachedResponse(
                    status: http.statusCode,
                    contentType: contentType(for: context.mapping, response: http),
                    headers: forwardedHeaders(from: http),
                    body: context.body
                )
                setHeadersSent(context)
                sendFullResponse(
                    connection: context.connection, queue: context.queue,
                    status: passthrough.status,
                    contentType: passthrough.contentType,
                    headers: passthrough.headers,
                    body: passthrough.body
                )
                serveWaiters(context: context, error: nil, response: passthrough)
                return
            }
            // 相对 URI 按最终重定向落点解析（task.response.url），不是注册时的
            // mapping.upstream：重定向后的播单按旧基址解析会 100% 404。
            let finalBase = task.response?.url ?? task.currentRequest?.url ?? context.mapping.upstream
            let rewritten = rewritePlaylist(text, baseURL: finalBase)
            outBody = Data(rewritten.utf8)
        } else {
            outBody = context.body
        }
        if context.cacheable {
            cacheResponse(token: context.mapping.token, range: context.requestRange, response: CachedResponse(
                status: http.statusCode,
                contentType: contentType(for: context.mapping, response: http),
                headers: forwardedHeaders(from: http),
                body: outBody
            ))
        }
        recordActual(mapping: context.mapping, status: http.statusCode, bytes: outBody.count, servedFromCache: false)
        setHeadersSent(context)
        sendFullResponse(
            connection: context.connection, queue: context.queue,
            status: http.statusCode,
            contentType: contentType(for: context.mapping, response: http),
            headers: forwardedHeaders(from: http),
            body: outBody
        )
        serveWaiters(context: context, error: nil)
    }

    /// 转发白名单里的上游响应头（缓存的响应复用同一张表）。
    private func forwardedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for field in ["Content-Range", "Accept-Ranges", "Cache-Control", "ETag", "Last-Modified"] {
            if let value = response.value(forHTTPHeaderField: field) {
                out[field] = value
            }
        }
        return out
    }
}
