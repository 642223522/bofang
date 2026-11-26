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
//   跨域 302 会丢自定义头，重定向请求上把身份头补回去（同拦截器的 RedirectHandler）。
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
    var response: HTTPURLResponse?
    var receivedBytes = 0
    /// 小响应才攒 body（播单要改写、密钥要原样服务）；超 8MB 即放弃缓存、只流式转发。
    var body = Data()
    var cacheable = true
    var headersSent = false
    /// 流式模式（分片/MAP）：头一到就发、body 边收边发；缓冲模式（播单/变体/密钥）：
    /// 收齐再改写/再发。
    let streamMode: Bool
    /// 同一 token 已在取、后来又到的连接：取完后从缓存统一服务。
    var waiters: [(connection: NWConnection, queue: DispatchQueue)] = []

    init(connection: NWConnection, queue: DispatchQueue, mapping: ProxyMapping) {
        self.connection = connection
        self.queue = queue
        self.mapping = mapping
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
    private func bindListener() {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: 0))
        } catch {
            completeStart(success: false)
            return
        }
        stateLock.lock()
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
        stateLock.lock()
        let port = Int(listener.port?.rawValue ?? 0)
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
        if port > 0 {
            // 第一次就绪是“能力已证实”；之后是监听重启换端口。
            PlaybackCapabilities.hasLoopbackProxy = true
            if !completed {
                completion?(true)
            } else if wasBound {
                handler?()
            }
        } else {
            completeStart(success: false)
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
        // 缓存命中：原样服务，不再碰上游（一次性 token 就靠这个）。
        if let cached = cachedResponse(for: urlToken) {
            recordActual(mapping: mapping, status: cached.status, bytes: cached.body.count, servedFromCache: true)
            serveCached(connection: connection, queue: queue, mapping: mapping, cached: cached)
            return
        }
        // 同一 token 正在取：挂等候（tee 直播 / 从缓存服务）或直接 502，不再发第二次上游请求。
        if handleWaiterIfFetching(token: urlToken, connection: connection, queue: queue) {
            return
        }
        startUpstreamFetch(mapping: mapping, range: headers["range"], connection: connection, queue: queue)
    }

    // MARK: - 上游拉取（URLSessionDataDelegate 流式转发）

    private func startUpstreamFetch(mapping: ProxyMapping, range: String?, connection: NWConnection, queue: DispatchQueue) {
        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session else {
            sendSimpleResponse(connection: connection, queue: queue, status: 502, body: "Bad Gateway")
            return
        }
        var request = URLRequest(url: mapping.upstream)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        // 身份头由代理统一带（UA/Referer/模块头/Cookie）；AVPlayer 发来的头只转发 Range
        //（MP4 用它；其余一律以代理的为准，不把 AppleCoreMedia 之类带去上游）。
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let context = ProxyFetchContext(connection: connection, queue: queue, mapping: mapping)
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

    private func takeContext(for task: URLSessionTask) -> ProxyFetchContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeTasks.removeValue(forKey: task.taskIdentifier)
    }

    /// 同一 token 正在取：还没发过头就挂等候（流式直播 tee、缓冲取完从缓存服务）；
    /// 已发过头且缓存有就原样服务；否则给 502（重复请求已错过直播流）。
    /// 返回 true 表示已处理（不再发起第二次上游请求）。
    private func handleWaiterIfFetching(token: String, connection: NWConnection, queue: DispatchQueue) -> Bool {
        stateLock.lock()
        var target: ProxyFetchContext?
        for context in activeTasks.values where context.mapping.token == token {
            target = context
            break
        }
        stateLock.unlock()
        guard let context = target else { return false }
        let sent = isHeadersSent(context)
        if !sent {
            stateLock.lock()
            context.waiters.append((connection: connection, queue: queue))
            stateLock.unlock()
            return true
        }
        if let cached = cachedResponse(for: token) {
            recordActual(mapping: context.mapping, status: cached.status, bytes: cached.body.count, servedFromCache: true)
            serveCached(connection: connection, queue: queue, mapping: context.mapping, cached: cached)
            return true
        }
        recordActual(mapping: context.mapping, status: nil, bytes: 0, servedFromCache: false)
        sendSimpleResponse(connection: connection, queue: queue, status: 502, body: "Bad Gateway")
        return true
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

    private func snapshotWaiters(_ context: ProxyFetchContext) -> [(connection: NWConnection, queue: DispatchQueue)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context.waiters
    }

    // MARK: - 播单改写（通用 URI 属性，不写死名单）

    /// 播单逐行改写：所有含 URI 的属性（URI="…"、SERVER-URI="…"、X-ASSET-URI="…" 等）
    /// 与 EXT-X-DEFINE 里 VALUE="http…" 的绝对 URL 一律改回环；裸 URI 行
    /// （变体播单/分片）解析成绝对路径后改回环；其余行原样。
    /// skd://（FairPlay）不动、记旗（ViewModel 据此报明确错误）；
    /// data: 内联密钥不动（AVPlayer 自己处理）。
    /// 返回改写后的文本；改写出的映射已记进期望账本。
    private func rewritePlaylist(_ text: String, baseURL: URL) -> String {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if line.hasPrefix("#") {
                out.append(rewriteURIAttributes(in: line, baseURL: baseURL))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let absolute = absoluteURL(trimmed, base: baseURL)
                let kind: BookKind = isPlaylistURL(absolute) ? .variant : .segment
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

    private func cachedResponse(for token: String) -> CachedResponse? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache[token]
    }

    /// 小响应进缓存（FIFO，总量 ≤64MB，超了淘汰最旧的）。
    private func cacheResponse(token: String, response: CachedResponse) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if cache[token] == nil {
            cacheOrder.append(token)
        } else {
            cacheBytes -= cache[token]?.body.count ?? 0
        }
        cache[token] = response
        cacheBytes += response.body.count
        while cacheBytes > Self.maxCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cacheBytes -= removed.body.count
            }
        }
    }

    // MARK: - 发包（chunked 流式；各连接在自己的串行队列上发，不持锁）

    private func send(connection: NWConnection, queue: DispatchQueue, data: Data, isComplete: Bool) {
        queue.async {
            connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed { _ in })
        }
    }

    /// 响应头（chunked；Content-Length 不转发——分块编码替它；只转发白名单里的上游头）。
    private func responseHead(status: Int, contentType: String, response: HTTPURLResponse?) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        if let response {
            for field in ["Content-Range", "Accept-Ranges", "Cache-Control", "ETag", "Last-Modified"] {
                if let value = response.value(forHTTPHeaderField: field) {
                    head += "\(field): \(value)\r\n"
                }
            }
        }
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8)
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

    /// 终结块：0 长度块，完结本次响应。
    private func sendTerminalChunk(connection: NWConnection, queue: DispatchQueue) {
        send(connection: connection, queue: queue, data: Data("0\r\n\r\n".utf8), isComplete: true)
        untrackConnection(connection)
    }

    /// 简单错误响应（带 Content-Length、一次发完）。
    private func sendSimpleResponse(connection: NWConnection, queue: DispatchQueue, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Content-Type: text/plain\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(bodyData)
        send(connection: connection, queue: queue, data: payload, isComplete: true)
        untrackConnection(connection)
    }

    /// 缓存命中的完整响应：原样服务（chunked 分块发出）。
    private func serveCached(connection: NWConnection, queue: DispatchQueue, mapping: ProxyMapping, cached: CachedResponse) {
        var head = "HTTP/1.1 \(cached.status) \(reasonPhrase(for: cached.status))\r\n"
        head += "Content-Type: \(cached.contentType)\r\n"
        for (field, value) in cached.headers {
            head += "\(field): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"
        send(connection: connection, queue: queue, data: Data(head.utf8), isComplete: false)
        // 大 body 分 64KB 一块发，避免单次 send 过大。
        var offset = 0
        while offset < cached.body.count {
            let end = min(offset + 65536, cached.body.count)
            sendChunk(connection: connection, queue: queue, data: cached.body.subdata(in: offset..<end))
            offset = end
        }
        sendTerminalChunk(connection: connection, queue: queue)
    }

    /// 等候者统一服务：取成功了从缓存原样服务，取失败了给 502。
    private func serveWaiters(context: ProxyFetchContext, error: Error?) {
        let waiters = snapshotWaiters(context)
        guard !waiters.isEmpty else { return }
        if error == nil, let cached = cachedResponse(for: context.mapping.token) {
            for waiter in waiters {
                recordActual(mapping: context.mapping, status: cached.status, bytes: cached.body.count, servedFromCache: true)
                serveCached(connection: waiter.connection, queue: waiter.queue, mapping: context.mapping, cached: cached)
            }
        } else {
            for waiter in waiters {
                recordActual(mapping: context.mapping, status: nil, bytes: 0, servedFromCache: false)
                sendSimpleResponse(connection: waiter.connection, queue: waiter.queue, status: 502, body: "Bad Gateway")
            }
        }
    }
}

// MARK: - URLSessionDataDelegate（上游拉取，流式转发）

extension LoopbackProxyServer: URLSessionDataDelegate, URLSessionTaskDelegate {

    /// 重定向：代理自己跟随，绝不把 Location 交给 AVPlayer；
    /// 跨域 302 会丢自定义头，重定向请求上把身份头补回去。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        for (key, value) in headers {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
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
            let head = responseHead(status: http.statusCode, contentType: contentType(for: context.mapping, response: http), response: http)
            send(connection: context.connection, queue: context.queue, data: head, isComplete: false)
            for waiter in snapshotWaiters(context) {
                send(connection: waiter.connection, queue: waiter.queue, data: head, isComplete: false)
            }
            setHeadersSent(context)
        }
        completionHandler(.allow)
    }

    /// 上游 body 到了：流式模式立刻转发一块（等候者 tee 同一块）；同时攒起来
    /// （≤8MB 才攒，超了即放弃缓存）——小分片/密钥进缓存后，AVPlayer 重复请求
    /// 同一 token 时不再碰上游（一次性 token 就靠这个）。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let context = context(for: dataTask) else { return }
        context.receivedBytes += data.count
        if context.streamMode {
            sendChunk(connection: context.connection, queue: context.queue, data: data)
            for waiter in snapshotWaiters(context) {
                sendChunk(connection: waiter.connection, queue: waiter.queue, data: data)
            }
        }
        if context.cacheable {
            context.body.append(data)
            if context.body.count > Self.maxCacheableBytes {
                context.cacheable = false
                context.body = Data()
            }
        }
    }

    /// 上游拉取结束：成功则收尾（缓冲模式改写/原样服务 + 进缓存；流式模式发终结块），
    /// 记实际账本，等候者统一服务；失败则记账本、给 502 或断连。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = takeContext(for: task) else { return }
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
            if context.cacheable, let http = context.response {
                cacheResponse(token: context.mapping.token, response: CachedResponse(
                    status: http.statusCode,
                    contentType: contentType(for: context.mapping, response: http),
                    headers: forwardedHeaders(from: http),
                    body: context.body
                ))
            }
            recordActual(mapping: context.mapping, status: status, bytes: context.receivedBytes, servedFromCache: false)
            let waiters = snapshotWaiters(context)
            sendTerminalChunk(connection: context.connection, queue: context.queue)
            for waiter in waiters {
                recordActual(mapping: context.mapping, status: status, bytes: context.receivedBytes, servedFromCache: false)
                sendTerminalChunk(connection: waiter.connection, queue: waiter.queue)
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
        // 上游非 2xx：不改写，原样把状态与 body 交给 AVPlayer（账本记 rejectedUpstream）。
        guard (200...299).contains(http.statusCode) else {
            recordActual(mapping: context.mapping, status: http.statusCode, bytes: context.body.count, servedFromCache: false)
            let head = responseHead(status: http.statusCode, contentType: contentType(for: context.mapping, response: http), response: http)
            send(connection: context.connection, queue: context.queue, data: head, isComplete: false)
            setHeadersSent(context)
            sendChunk(connection: context.connection, queue: context.queue, data: context.body)
            sendTerminalChunk(connection: context.connection, queue: context.queue)
            serveWaiters(context: context, error: nil)
            return
        }
        // 2xx：播单/变体改写后发，密钥原样发；可缓存的进缓存（供重试原样服务）。
        let outBody: Data
        if context.mapping.kind == .playlist || context.mapping.kind == .variant {
            let text = String(decoding: context.body, as: UTF8.self)
            let rewritten = rewritePlaylist(text, baseURL: context.mapping.upstream)
            outBody = Data(rewritten.utf8)
        } else {
            outBody = context.body
        }
        if context.cacheable {
            cacheResponse(token: context.mapping.token, response: CachedResponse(
                status: http.statusCode,
                contentType: contentType(for: context.mapping, response: http),
                headers: forwardedHeaders(from: http),
                body: outBody
            ))
        }
        recordActual(mapping: context.mapping, status: http.statusCode, bytes: outBody.count, servedFromCache: false)
        let head = responseHead(status: http.statusCode, contentType: contentType(for: context.mapping, response: http), response: http)
        send(connection: context.connection, queue: context.queue, data: head, isComplete: false)
        setHeadersSent(context)
        sendChunk(connection: context.connection, queue: context.queue, data: outBody)
        sendTerminalChunk(connection: context.connection, queue: context.queue)
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
