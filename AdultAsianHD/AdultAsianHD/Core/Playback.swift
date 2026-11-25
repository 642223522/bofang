import Foundation

/// 播放快路径：番号 → memojav 静态播单直拼，不抓帖页、不验播单。
/// 点封面的一瞬间就能拼出播单 URL，直接交给 AVPlayer。
/// 线路竞速决出的首选线（按模块 id 存内存，本会话每模块只竞一次、关软件重开再竞）。
/// memojav：静态 m3u8，可直拼快路径；nmcorp：签名 MP4，必须走 loadResource 现解。
/// nil（没竞速 / 没分出胜负 / 两条都死 / 无固定验线）= 按现有逻辑（快路径 + 备线）。
enum PreferredLine: Hashable {
    case memojav
    case nmcorp

    /// 检测页显示用（竞速结果里写哪条线胜出）。
    var displayLabel: String {
        switch self {
        case .memojav: return "MemoJav"
        case .nmcorp: return "NMCorp"
        }
    }
}

enum PlaybackEngine {

    /// 按 URL / 名字判断一条播放线路属于哪种线。
    /// memojav：host 含 memojav 或名字含 MemoJav；
    /// nmcorp：host 含 nmcorp / pvvstream、名字含 NMCorp，或签名 MP4（secure=）。
    /// 认不出的返回 nil（竞速里不算它，播放时按现有逻辑）。
    static func preferredLineKind(of line: PlayLine) -> PreferredLine? {
        guard let url = URL(string: line.url) else { return nil }
        let host = (url.host ?? "").lowercased()
        let name = line.name.lowercased()
        let urlString = line.url.lowercased()
        if host.contains("memojav") || name.contains("memojav") {
            return .memojav
        }
        if host.contains("nmcorp") || host.contains("pvvstream") || name.contains("nmcorp") {
            return .nmcorp
        }
        if urlString.contains("secure=") && url.pathExtension.lowercased() == "mp4" {
            return .nmcorp
        }
        return nil
    }

    private static let codeRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b([A-Za-z]{2,6}-\\d{2,5})\\b")
    }()

    /// 模块抓帖页/播放器页用的 iPhone Safari UA；nmcorp 签名 MP4 走 AVPlayer
    /// 默认 UA（AppleCoreMedia）可能被 CDN 拒，换线时补上同款 UA。
    static let iPhoneUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 从标题里抠番号，如 "ATID-686 ..." → "ATID-686"。抠不到返回 nil。
    static func javCode(from title: String) -> String? {
        guard let regex = codeRegex else { return nil }
        let range = NSRange(title.startIndex..., in: title)
        guard let match = regex.firstMatch(in: title, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        let codeRange = match.range(at: 1)
        guard let swiftRange = Range(codeRange, in: title) else { return nil }
        return String(title[swiftRange]).uppercased()
    }

    /// memojav 静态播单：https://video10.memojav.net/stream/<番号>/master.m3u8
    /// 明文 fMP4 HLS，无 AES 密钥，AVPlayer 原生就能播。
    static func memojavURL(for code: String) -> URL {
        // 番号只含字母数字和横杠，直接拼是安全的
        URL(string: "https://video10.memojav.net/stream/\(code.uppercased())/master.m3u8")!
    }

    /// 快路径 URL：从标题抠番号 → memojav URL，抠不到返回 nil。
    static func fastPathURL(for item: VideoItem) -> URL? {
        guard let code = javCode(from: item.title) else { return nil }
        return memojavURL(for: code)
    }

    /// 直链（AVPlayer 能直接播）：扩展名是 m3u8/mp4/mov，或 URL 里含 .m3u8/.mp4。
    /// .mpd 不再是 AVPlayer 直链（DASH 绝不再往 AVPlayer 送，路由表把它判给 .dash）。
    /// 播单 URL 先过这一关：是直链走现有 AVPlayer，不是再看是不是嵌入页。
    static func isDirectMediaURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "mov"].contains(ext) { return true }
        let lower = urlString.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4")
    }

    /// 嵌入页（要先解流或 WebView 播）：http(s) 链接且不是直链；
    /// 或 playerHint 明确标嵌入（"embed"/"webview"）。
    /// playmogo/dood 这类嵌入页 URL 走这条；huangguo 的直链 HLS 虽然 hint 也是 hlsjs，
    /// 但 URL 本身是 .m3u8，先被上一关认成直链，不会误判。
    /// hlsjs 不再只由后缀决定去向：hlsjs+嵌页 URL 经由 route(for:) 判给 .webView。
    static func isEmbedURL(_ urlString: String, playerHint: String? = nil) -> Bool {
        if let hint = playerHint?.lowercased(),
           hint.contains("embed") || hint.contains("webview") {
            return true
        }
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return false }
        return !isDirectMediaURL(urlString)
    }

    /// URL 里是否含签名/token 参数（现铸签名、一次性 token 类）。
    /// 查 query 参数名，不只查子串，避免把路径里偶然出现的词误判。
    static func isSignedURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        if lower.contains("auth_key") || lower.contains("authkey") { return true }
        guard let components = URLComponents(string: urlString),
              let queryItems = components.queryItems else { return false }
        let signedNames: Set<String> = ["token", "access_token", "auth", "sign", "signature", "secure", "expires", "exp", "st", "key"]
        return queryItems.contains { signedNames.contains($0.name.lowercased()) }
    }

    /// AVPlayer 不支持的非原生容器（.mkv/.flv/.avi/.webm）：只认扩展名，
    /// 编码未知时不猜（URL 看不出编码），由软解引擎或失败报错兜底。
    static func isUnsupportedContainer(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return ["mkv", "flv", "avi", "webm"].contains(url.pathExtension.lowercased())
    }

    /// 明文静态线：先裸连、失败再升级拦截器的候选。
    /// 条件：hint 是 native/缺失，URL 是明文 .m3u8/.mp4，无签名、无自定义头、无 Cookie。
    static func isPlainStaticLine(_ line: PlayLine) -> Bool {
        let hint = (line.playerHint ?? "").lowercased()
        guard hint.isEmpty || hint.contains("native") else { return false }
        guard !isSignedURL(line.url) else { return false }
        guard line.headers?.isEmpty != false, line.cookie?.isEmpty != false else { return false }
        guard let url = URL(string: line.url) else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "mp4"
            || line.url.lowercased().contains(".m3u8")
            || line.url.lowercased().contains(".mp4")
    }

    /// hlsjs 现铸签名线：hint 是 hlsjs 且 URL 带签名（黄果类）。播放时刻一律重新现铸。
    static func isHLSJSSignedLine(_ line: PlayLine) -> Bool {
        let hint = (line.playerHint ?? "").lowercased()
        return hint.contains("hlsjs") && isSignedURL(line.url)
    }

    /// 路由表：hint 优先于 URL 后缀。
    /// - hint 含 embed/webview，或 URL 是嵌页 → .webView（hlsjs+嵌页也是 .webView）。
    /// - .mpd → .dash（绝不再往 AVPlayer 送）。
    /// - 非原生容器（.mkv/.flv/.avi/.webm）→ .softDecoder；没集成软解时路由到
    ///   .nativeIntercepted，失败时由 markFailed 报明确错误，不无意义重试。
    /// - hint=hlsjs：优先走 hls.js（PlaybackCapabilities.hasHLSJS 为 true 时 → .hlsjs），
    ///   其次才是拦截器那条（.nativeIntercepted，标明为 Native HLS 兼容实现，
    ///   不要把拦截器说成 hls.js）；hls.js 失败 → 回退到 .nativeIntercepted（一步，不循环）。
    ///   hlsjs+MP4 也可能需要 Cookie/Referer，走 .nativeIntercepted，不直接丢给 AVPlayer 裸播。
    /// - URL 含签名/token、模块给了自定义头/Cookie → .nativeIntercepted。
    /// - hint=native+明文 → .native；未知 hint 先按 URL 形态判，判不出走 .nativeIntercepted 试播。
    /// - 签名/token/加密/有自定义头/Cookie 的线直接走拦截器，不试裸连；
    ///   只有明文静态、无加密、无自定义头的线才先裸连、失败再升级拦截器（见 markFailed）。
    static func route(for line: PlayLine) -> PlayerEngine {
        let hint = (line.playerHint ?? "").lowercased()
        let lower = line.url.lowercased()
        guard let url = URL(string: line.url),
              url.scheme == "http" || url.scheme == "https" else {
            // 非 http(s) 地址（如自定义 scheme 的 epLink 被误当成线）：判不出，
            // 走拦截器试播，不直接报错。
            return .nativeIntercepted
        }
        // 1. hint 明确标嵌入 → WebView。
        if hint.contains("embed") || hint.contains("webview") {
            return .webView
        }
        let ext = url.pathExtension.lowercased()
        // 2. .mpd → DASH（在 isEmbedURL 之前判：.mpd 已不是 AVPlayer 直链，
        //    isEmbedURL 会把它误判成嵌页）。
        //    能力判定：有 dash.js → .dash；无 dash.js 但有软解 → .softDecoder；
        //    两者都没有 → 仍返回 .dash（不静默丢线），由 routeLine 的 fast-fail
        //    直接报明确错误并切下一条线；能力探测中途变化时，B 路 DASHPlayerView
        //    的 JS 报错 → markFailed 切线仍是第二道网。
        //    不改走 Native HLS 兼容实现：AVPlayer 解析不了 DASH manifest，
        //    拦截器把 .mpd 的 XML 当媒体喂进去只会报一个含糊的 -11800，
        //    不如明确报错。
        if ext == "mpd" || lower.contains(".mpd") {
            if PlaybackCapabilities.hasDASH {
                return .dash
            }
            if PlaybackCapabilities.hasSoftwareDecoder {
                return .softDecoder
            }
            return .dash
        }
        // 3. 非原生容器 → 软解（无软解则拦截器试播，失败报明确错误）。
        if ["mkv", "flv", "avi", "webm"].contains(ext) {
            return PlaybackCapabilities.hasSoftwareDecoder ? .softDecoder : .nativeIntercepted
        }
        // 4. 嵌页 URL → WebView（hlsjs+嵌页也是 WebView）。
        if isEmbedURL(line.url, playerHint: line.playerHint) {
            return .webView
        }
        // 5. hlsjs：优先 hls.js，其次 Native HLS 兼容实现（拦截器）。
        if hint.contains("hlsjs") {
            if ext == "m3u8" || lower.contains(".m3u8") {
                return PlaybackCapabilities.hasHLSJS ? .hlsjs : .nativeIntercepted
            }
            // hlsjs+MP4 也可能需要 Cookie/Referer，走拦截器，不裸播。
            return .nativeIntercepted
        }
        // 6. 拦截条件：签名 token / 自定义头 / Cookie。
        let needsIntercept = isSignedURL(line.url)
            || line.headers?.isEmpty == false
            || line.cookie?.isEmpty == false
        if ext == "m3u8" || lower.contains(".m3u8") {
            if needsIntercept { return .nativeIntercepted }
            if hint.contains("native") || hint.isEmpty { return .native }
            // 未知 hint 的 .m3u8：形态判得出是 HLS 但 hint 不认得，走拦截器试播。
            return .nativeIntercepted
        }
        if ext == "mp4" || lower.contains(".mp4") {
            if needsIntercept { return .nativeIntercepted }
            return .native
        }
        // 7. 无后缀 / 不透明 URL：形态判不出，走拦截器试播，不直接报错。
        if ext.isEmpty {
            return .nativeIntercepted
        }
        // 其他已知直链后缀（如 .mov）→ 原生。
        return .native
    }

    /// 该线路播放时要带的 HTTP 请求头。只给签名 MP4 线（nmcorp/cdn2.pvvstream
    /// 的 vid_*p.mp4?secure=…）：模块取播放器页时带 Referer=帖页才拿到签名，
    /// AVPlayer 默认不带 Referer，CDN 会拒 → 黑屏；补 Referer=帖页 + iPhone UA。
    /// memojav m3u8 快路径真机已播通，不动它，返回 nil。
    static func headers(forLineURL urlString: String, referer: String?) -> [String: String]? {
        guard let url = URL(string: urlString),
              url.pathExtension.lowercased() == "mp4" else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard host.contains("pvvstream") || host.contains("nmcorp")
                || urlString.contains("secure=") else { return nil }
        var headers = ["User-Agent": iPhoneUserAgent]
        if let referer, !referer.isEmpty {
            headers["Referer"] = referer
        }
        return headers
    }
}

enum PlayerStatus: Equatable {
    case idle
    case loading
    case playing
    case failed(String)
}

/// 只管 URL 与线路状态；AVPlayer 本身由 Views 层的自定义播放器
/// （CustomPlayerView：AVPlayerLayer + 自绘底条，不用 AVPlayerViewController），
/// 嵌入页由 WebViewPlayer.swift（页内播）+ EmbedStreamExtractor.swift（解流）负责，
/// ViewModel 只做路由：直链 → 现有 AVPlayer，嵌入页 → 先解流、解不出再 WebView。
/// 播放流程：快路径先上（不抓帖页、不验播单），后台再跑模块的 loadResource 拿备线；
/// 快路径失败时自动切备线，备线也都失败才报 failed。
/// nmcorp 签名 MP4 换线时带上 Referer + iPhone UA（AVPlayer 默认不带，CDN 会拒），
/// 由 currentHeaders 交给 PlayerView 去建 AVURLAsset。
@MainActor
final class PlayerViewModel: ObservableObject {

    @Published var lines: [PlayLine] = []
    @Published var currentURL: URL?
    /// 当前线路播放时要带的 HTTP 请求头（nmcorp 签名 MP4 的 Referer/UA；memojav 快路径为 nil）。
    @Published var currentHeaders: [String: String]?
    /// 当前线路走的播放器引擎（路由表定；DetailView 按它显示对应播放器）。
    /// stop() 时重置回 .native。
    @Published var currentEngine: PlayerEngine = .native
    /// 拦截器实例（currentEngine == .nativeIntercepted 时才有）：
    /// ViewModel 强持有，CustomPlayerView 用它给 asset 挂 delegate；
    /// 换线/stop 时释放，旧 item 的 delegate 随 controller 手里的强引用续命到换项。
    private(set) var resourceLoader: HLSResourceLoader?
    @Published var status: PlayerStatus = .idle
    @Published var failureReason: String?
    /// 正在用页内 WebView 播的嵌入页地址（非 nil 时 DetailView 显示 WebView 播放器，不显示 AVPlayer）。
    @Published var webViewURL: URL?
    /// 正在跑混合解流（无界面 WebView 抽直链）时为 true，DetailView 显示“正在解析嵌入播放…”。
    @Published var isResolvingEmbed = false

    /// 已经失败过的线路 URL（切线时跳过，不来回横跳）
    private var failedURLs: Set<String> = []
    /// 引擎强制覆盖（URL → 引擎）：裸连失败升级、hls.js ⇄ 拦截器回退都走这里，
    /// 同一条线只回退有限次（见 triedEngineFallbacks），不循环。
    /// 手动切线/点播时清掉该 URL 的覆盖，重新按路由表定。
    private var engineOverrides: [String: PlayerEngine] = [:]
    /// 已试过的引擎回退（"URL|引擎"）：同一条线同一引擎只回退一次。
    private var triedEngineFallbacks: Set<String> = []
    /// 因过期/一次性 token 失败的 URL：不再自动重试同一条线（只认手动点播）。
    private var expiredTokenURLs: Set<String> = []
    /// 密钥 403 重铸已试过的 URL（一次播放只重铸一次，不循环重铸）。
    private var keyRecastAttemptedURLs: Set<String> = []
    /// 当前片/当前集的现铸入口（分集 epLink）：hlsjs 签名线播放时刻现铸、密钥 403 重铸都用它。
    /// play(item:host:) 没有 epLink，只有 playLine(_:recastLink:) 能给它。
    private var currentRecastLink: String?
    private var currentRecastTitle: String?
    /// 当前 host（play(item:host:) 存下，供 routeLine/playLine 的现铸分支调 loadResource 用）。
    /// 不改 play(item:host:) 的签名。
    private var currentHost: WidgetHost?
    /// 每次 play 换一个 generation，旧的后台备线任务回来发现对不上就丢弃，
    /// 防止切到别的片后旧备线写回 lines。
    /// internal（不 private）：自定义播放器靠它区分“新片/新一集”（从 0:00 起）
    /// 还是“同片切线”（保当前进度）。
    var playGeneration = UUID()
    /// 当前片的帖页链接：nmcorp 签名 MP4 的 Referer 就用它（模块取播放器页时也是这个 Referer）。
    private var currentItemLink: String?
    /// 正在跑的混合解流（一次只跑一路；换线/停播时取消，旧结果写不回来）。
    private var embedExtractor: EmbedStreamExtractor?
    private var embedTask: Task<Void, Never>?

    /// 该线路实际走的引擎：有强制覆盖（回退/升级）用覆盖，其余走路由表。
    private func engine(for line: PlayLine) -> PlayerEngine {
        if let override = engineOverrides[line.url] {
            return override
        }
        return PlaybackEngine.route(for: line)
    }

    /// 清掉一条线的回退状态（手动切线/点播时调）：覆盖、已试回退、过期标记全清，
    /// 重新按路由表定引擎，允许重试。
    private func clearFallbackState(for url: String) {
        engineOverrides.removeValue(forKey: url)
        triedEngineFallbacks = triedEngineFallbacks.filter { !$0.hasPrefix(url + "|") }
        expiredTokenURLs.remove(url)
    }

    /// 该 URL 是否已试过某引擎的回退（防循环）。
    private func hasTriedFallback(url: String, engine: PlayerEngine) -> Bool {
        triedEngineFallbacks.contains("\(url)|\(engine)")
    }

    /// 记下该 URL 已试过某引擎的回退。
    private func markFallbackTried(url: String, engine: PlayerEngine) {
        triedEngineFallbacks.insert("\(url)|\(engine)")
    }

    /// 拦截器用的子请求头：Referer（线路 referer，缺失时用当前帖页）+ iPhone UA，
    /// 模块自定义头后合并（模块的为准）；Cookie 也放进头里一份，供 HLS.js 回退复用，
    /// 拦截器自己另从 line.cookie 取（见 makeResourceLoader）。
    private func interceptedHeaders(for line: PlayLine) -> [String: String] {
        var headers: [String: String] = ["User-Agent": PlaybackEngine.iPhoneUserAgent]
        if let referer = line.referer, !referer.isEmpty {
            headers["Referer"] = referer
        } else if let referer = currentItemLink, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let extra = line.headers {
            for (key, value) in extra {
                headers[key] = value
            }
        }
        if let cookie = line.cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    /// 给一条拦截线路建 HLSResourceLoader：头用 interceptedHeaders，Cookie 单独传；
    /// 密钥 403 重铸回调挂到 handleKeyAuthFailure。
    private func makeResourceLoader(for line: PlayLine) -> HLSResourceLoader {
        let loader = HLSResourceLoader(headers: interceptedHeaders(for: line), cookie: line.cookie)
        loader.onKeyAuthFailed = { [weak self] in
            await MainActor.run { await self?.handleKeyAuthFailure() ?? false }
        }
        return loader
    }

    /// 密钥 403/401 且拦截器重拉播单后仍失败时调：用当前集的 epLink 重新现铸一次，
    /// 铸出新线就切过去（返回 true），没 epLink/没 host/已重铸过/铸不出就返回 false，
    /// 由拦截器按失败收尾、markFailed 走正常切线。
    private func handleKeyAuthFailure() async -> Bool {
        guard let link = currentRecastLink, let host = currentHost else { return false }
        guard let current = currentURL?.absoluteString,
              !keyRecastAttemptedURLs.contains(current) else { return false }
        keyRecastAttemptedURLs.insert(current)
        let generation = playGeneration
        guard let recast = try? await host.loadResource(link: link, title: currentRecastTitle ?? ""),
              let first = recast.first else { return false }
        guard playGeneration == generation else { return false }
        if !lines.contains(where: { $0.url == first.url }) {
            lines.insert(first, at: 0)
        }
        failedURLs.remove(first.url)
        routeLine(first)
        return true
    }

    /// 换当前线路：URL + 该线路要带的请求头一起换，状态回 .loading。
    /// URL 非法返回 false，调用方据此报“没有可用的播放线路”。
    /// 切到直链时，取消正在跑的解流、清掉 WebView（旧的解流结果不能再写回）。
    /// currentEngine == .nativeIntercepted 时建拦截器并挂到 resourceLoader：
    /// currentURL 保持 https 原地址（线路身份、失败去重、画质匹配都按它认），
    /// scheme 改写只发生在 CustomPlayerView 建 asset 那一步。
    /// 发布顺序：先建好拦截器、再设 currentURL/currentHeaders、最后设 currentEngine——
    /// 控制器的引擎监听触发 load() 时拦截器已经在位，不会先建出裸 asset。
    @discardableResult
    private func setCurrent(_ line: PlayLine, engine: PlayerEngine? = nil) -> Bool {
        guard let url = URL(string: line.url) else { return false }
        let resolvedEngine = engine ?? self.engine(for: line)
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        webViewURL = nil
        isResolvingEmbed = false
        if resolvedEngine == .nativeIntercepted {
            resourceLoader = makeResourceLoader(for: line)
        } else {
            resourceLoader = nil
        }
        currentURL = url
        if resolvedEngine == .nativeIntercepted {
            // 拦截线路：Referer/UA/模块头/Cookie 全给拦截器（子请求用），
            // currentHeaders 同步一份，供 HLS.js 回退的播放器复用。
            currentHeaders = interceptedHeaders(for: line)
        } else if let referer = line.referer, !referer.isEmpty {
            // 解流得到的直链带了 Referer（嵌入页）：AVPlayer 取流时带上，CDN 要这个。
            // 没带 Referer 的线走原有逻辑（一字不动）。
            currentHeaders = ["Referer": referer, "User-Agent": PlaybackEngine.iPhoneUserAgent]
        } else {
            currentHeaders = PlaybackEngine.headers(forLineURL: line.url, referer: currentItemLink)
        }
        currentEngine = resolvedEngine
        status = .loading
        failureReason = nil
        return true
    }

    /// 播一条线：先调路由表定引擎，再分流。
    /// .native/.nativeIntercepted → setCurrent（AVPlayer，拦截器线挂 delegate）；
    /// .webView → 现有 playEmbedLine；
    /// .hlsjs/.dash/.softDecoder → 只设 currentURL/currentHeaders/currentEngine/status=.loading，
    ///   不建 AVPlayer（视图层按 currentEngine 显示对应播放器，D 路负责）。
    /// 返回 true 表示这条线已被接手（直链已设、嵌入流程已启动，或已交给对应播放器视图）。
    @discardableResult
    private func routeLine(_ line: PlayLine) -> Bool {
        let engine = self.engine(for: line)
        // 首选引擎即记为已试：回退只去没试过的引擎，不 ping-pong
        //（hlsjs → 拦截器是一步，拦截器失败不再回 hls.js——hls.js 首选时已试过）。
        markFallbackTried(url: line.url, engine: engine)
        switch engine {
        case .native, .nativeIntercepted:
            return setCurrent(line, engine: engine)
        case .webView:
            currentEngine = engine
            playEmbedLine(line)
            return true
        case .hlsjs, .dash, .softDecoder:
            embedTask?.cancel()
            embedTask = nil
            embedExtractor?.cancel()
            embedExtractor = nil
            webViewURL = nil
            isResolvingEmbed = false
            resourceLoader = nil
            guard let url = URL(string: line.url) else {
                failureReason = "这条线路的地址不对，播不了"
                status = .failed("这条线路的地址不对，播不了")
                return false
            }
            // DASH 能力缺失 fast-fail：设备不支持 dash.js 且无软解时，
            // 直接报明确错误并切下一条线，不进 DASHPlayerView 空转
            // （不靠 JS 报错兜底当第一道防线；能力探测中途变化时，
            // B 路 DASHPlayerView 的 JS 报错 → markFailed 切线仍是第二道网）。
            if engine == .dash, !PlaybackCapabilities.hasDASH, !PlaybackCapabilities.hasSoftwareDecoder {
                failedURLs.insert(line.url)
                if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
                    routeLine(next)
                    return true
                }
                failureReason = "这条线路是 DASH 格式，当前设备不支持 dash.js 播放"
                status = .failed(failureReason!)
                return true
            }
            currentURL = url
            currentHeaders = interceptedHeaders(for: line)
            currentEngine = engine
            status = .loading
            failureReason = nil
            return true
        }
    }

    /// 嵌入页播放：墙后家族（playmogo/dood 系）直接进页内 WebViewPlayer，不解流；
    /// 其余嵌页先混合解流（15 秒），解出直链→AVPlayer；解不出→页内 WebView 播放器。
    /// 解流期间状态 .loading，DetailView 显示“正在解析嵌入播放…”。
    private func playEmbedLine(_ line: PlayLine) {
        guard let embedURL = URL(string: line.url) else {
            failureReason = "这条线路的地址不对，播不了"
            status = .failed("这条线路的地址不对，播不了")
            return
        }
        // 取消上一路解流（换线时旧的不能再写回）
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        webViewURL = nil
        currentURL = nil
        currentHeaders = nil
        failureReason = nil
        // Fix B wall-first：嵌页 host 属于 playmogo/dood 等墙后家族时，URLSession
        // 解流注定过不了 CF 挑战（探针：playmogo 403 + Cf-Mitigated: challenge），
        // 跳过解流、直接进页内 WebViewPlayer（0 等待，不耗 2 秒 blob 收尾）。
        if isWalledEmbedHost(embedURL.host) {
            isResolvingEmbed = false
            webViewURL = embedURL
            status = .playing
            return
        }
        isResolvingEmbed = true
        status = .loading
        let extractor = EmbedStreamExtractor(embedURL: embedURL)
        embedExtractor = extractor
        embedTask = Task { [weak self] in
            guard let self else { return }
            let stream = await extractor.extract()
            // 解流期间换了别的线/停播了，这路结果丢弃
            guard self.embedExtractor === extractor else { return }
            self.embedExtractor = nil
            self.embedTask = nil
            self.isResolvingEmbed = false
            if let stream {
                // 解出直链：Referer=嵌入页，交给路由表（再定一次引擎；
                // 解出的 HLS 可能带签名/要拦截，不直接走 setCurrent 绕过路由）。
                // 线路表里把这条嵌入线换成解出的直链（切线/失败重试能认出它）。
                let directLine = PlayLine(
                    name: line.name,
                    url: stream.url.absoluteString,
                    description: line.description,
                    playerHint: line.playerHint,
                    referer: stream.referer.absoluteString
                )
                if let idx = self.lines.firstIndex(where: { $0.url == line.url }) {
                    self.lines[idx] = directLine
                } else if !self.lines.contains(where: { $0.url == directLine.url }) {
                    self.lines.append(directLine)
                }
                _ = self.routeLine(directLine)
            } else {
                // 解不出：fallback 到页内 WebView 播放器，不报错（用户看到的是嵌入页在加载/过挑战）。
                self.webViewURL = embedURL
                self.status = .playing
            }
        }
    }

    /// 关闭嵌入播放器（WebView 里的 X）：停掉解流/清掉 WebView，
    /// 这条嵌入线记一次失败（不再自动重试），状态回 idle，等用户另点线路。
    func closeWebView() {
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        if let embedURL = webViewURL?.absoluteString {
            failedURLs.insert(embedURL)
        }
        webViewURL = nil
        isResolvingEmbed = false
        resourceLoader = nil
        currentEngine = .native
        status = .idle
        failureReason = nil
    }

    /// 点封面即播：快路径立刻设 currentURL，后台拿备线。
    /// 首选线（进模块时竞速定，本次有效）：
    /// - 首选 nmcorp：先解线，挑 nmcorp 线先播（memojav 在竞速里输了，不先拼它）；
    ///   没 nmcorp 线才退回快路径，已解出的线留作备线，不再跑一次 loadResource。
    /// - 首选 memojav / 无胜负 / 没竞速：现有逻辑（快路径先上，后台拿备线）。
    func play(item: VideoItem, host: WidgetHost) async {
        // 开始播放：后台自动自检立刻停（让路），下次断点续跑。
        SourceStore.shared.cancelAutoCheck()
        let generation = UUID()
        playGeneration = generation
        failedURLs = []
        engineOverrides = [:]
        triedEngineFallbacks = []
        expiredTokenURLs = []
        keyRecastAttemptedURLs = []
        currentRecastLink = nil
        currentRecastTitle = nil
        currentHost = host
        lines = []
        failureReason = nil
        currentHeaders = nil
        currentEngine = .native
        resourceLoader = nil
        currentItemLink = item.link
        status = .loading
        // 同一 ViewModel 重播时，旧的解流/WebView 不能残留
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        webViewURL = nil
        isResolvingEmbed = false

        if host.preferredLine == .nmcorp {
            let resolved = (try? await host.loadResource(link: item.link, title: item.title)) ?? []
            guard playGeneration == generation else { return } // 已播别的片，丢弃
            lines = resolved
            if let nmcorpLine = resolved.first(where: { PlaybackEngine.preferredLineKind(of: $0) == .nmcorp }) {
                routeLine(nmcorpLine)
                return
            }
            // 没 nmcorp 线：退回快路径（memojav 直拼），已解出的线留作备线
            if let fastURL = PlaybackEngine.fastPathURL(for: item) {
                let fastLine = PlayLine(name: "快速线", url: fastURL.absoluteString, description: "番号直拼，秒播")
                if !lines.contains(where: { $0.url == fastLine.url }) {
                    lines.insert(fastLine, at: 0)
                }
                if routeLine(fastLine) { return }
            }
            if let first = resolved.first, routeLine(first) { return }
            status = .failed("没有可用的播放线路")
            failureReason = "这个视频没有可用的播放线路"
            return
        }

        // 快路径：标题抠番号，直拼播单，立刻交给播放器
        if let fastURL = PlaybackEngine.fastPathURL(for: item) {
            let fastLine = PlayLine(name: "快速线", url: fastURL.absoluteString, description: "番号直拼，秒播")
            lines = [fastLine]
            routeLine(fastLine)
        } else {
            currentURL = nil
        }

        // 后台拿备线（模块的 loadResource），不挡快路径起播
        Task.detached {
            let backup = (try? await host.loadResource(link: item.link, title: item.title)) ?? []
            await MainActor.run {
                guard self.playGeneration == generation else { return } // 已播别的片，丢弃
                var merged = self.lines
                for line in backup where !line.url.isEmpty && !merged.contains(where: { $0.url == line.url }) {
                    merged.append(line)
                }
                self.lines = merged
                // 没快路径时，直接上第一条备线
                if self.currentURL == nil {
                    if let first = merged.first {
                        self.routeLine(first)
                    }
                    // 嵌入线已接手（正在解流，isResolvingEmbed=true）：别报失败，等解流结果
                    if self.currentURL == nil && !self.isResolvingEmbed {
                        self.status = .failed("没有可用的播放线路")
                        self.failureReason = "这个视频没有可用的播放线路"
                    }
                    return
                }
                // 快路径已经失败过了、备线刚到：有没试过的备线就立刻续上
                if case .failed = self.status,
                   let next = merged.first(where: { !self.failedURLs.contains($0.url) }) {
                    self.routeLine(next)
                }
            }
        }
    }

    /// 点线路切线（在小窗口里切，不重建播放器，由 Views 层换 AVPlayerItem）。
    func switchLine(_ line: PlayLine) {
        failedURLs.remove(line.url) // 手动点的线允许重试：先清掉它的失败记录
        clearFallbackState(for: line.url) // 手动点也清掉回退/过期标记，重新按路由表定
        routeLine(line)
    }

    /// 直接播一条指定线路（分集点播用）：把这条线放进线路列表并切过去。
    /// 已有同样 URL 的线不重复加；失败记录里有它就清掉（手动点的允许重试）。
    /// 地址非法时报 failed，不静默。
    /// 分集是新片：换 generation，自定义播放器从 0:00 起播（不同于 switchLine 的同片保进度）。
    /// recastLink：该集的 epLink。hlsjs 现铸签名线（黄果）有 epLink + host 时，
    /// 播放时刻一律走 loadResource(link: epLink) 重新现铸，不播缓存/预铸的旧 URL；
    /// 现铸失败时退回播原线，不直接报错。没 epLink 时走正常路由（由 D 路在
    /// DetailView.playEpisode 里把预铸直通分支改成传 epLink 过来）。
    func playLine(_ line: PlayLine, recastLink: String? = nil) {
        playGeneration = UUID()
        failedURLs.remove(line.url)
        clearFallbackState(for: line.url) // 手动点播：回退/过期标记全清，重新按路由表定
        if let recastLink {
            currentRecastLink = recastLink
            currentRecastTitle = line.name
        }
        if !lines.contains(where: { $0.url == line.url }) {
            lines.insert(line, at: 0)
        }
        if PlaybackEngine.isHLSJSSignedLine(line),
           let link = recastLink ?? currentRecastLink,
           let host = currentHost {
            status = .loading
            failureReason = nil
            let generation = playGeneration
            Task { [weak self] in
                guard let self else { return }
                guard let recast = try? await host.loadResource(link: link, title: line.name),
                      let first = recast.first else {
                    // 现铸失败：退回播原线，不直接报错。
                    guard self.playGeneration == generation else { return }
                    _ = self.routeLine(line)
                    return
                }
                guard self.playGeneration == generation else { return }
                if !self.lines.contains(where: { $0.url == first.url }) {
                    self.lines.insert(first, at: 0)
                }
                self.failedURLs.remove(first.url)
                _ = self.routeLine(first)
            }
            return
        }
        if !routeLine(line) {
            failureReason = "这条线路的地址不对，播不了"
            status = .failed("这条线路的地址不对，播不了")
        }
    }

    /// 播放器报错时调（Views 层监听 AVPlayerItemFailedToPlayToEndTime 等）。
    /// stage：调用方已知的失败分层（CustomPlayerController 报 -12881 时传 .segmentFetch，
    /// 其余传 nil，由拦截器记的分层兜底）。失败上报要分层，不要只报“失败”：
    /// 播单拉取失败 / key 失败 / 分片失败 + HTTP 状态码（Fix C 的自检复用这套分层）。
    /// 分层铁证（见 PlaybackFailureStage）：VPN 不改头、不改 cookie——VPN 下可播，
    /// 则缺头/缺 cookie 不可能是首要根因；VPN 下仍不可播，才是头/cookie/解析问题；
    /// 明文流（pornjav）在 B 上也要代理，几乎一定在网络层，与 playerHint 无关。
    /// 恢复顺序（有限，不循环）：过期/一次性 URL 不自动重试同一条线 →
    /// hls.js ⇄ Native HLS 兼容实现（拦截器）各试一次 → 裸连升级拦截器 →
    /// 切下一条线 → 报 failed。key 403 的链是：重拉播单一次 → 重铸一次 →
    /// 再失败即报失败切线（重拉+重铸在拦截器里，见 HLSResourceLoader）。
    /// - FairPlay（skd://）：拦截器在播单里见到了，直接报明确错误，不切线重试。
    /// - hlsjs 线：每条线每个引擎最多试一次（路由首选的引擎即记为已试）——
    ///   首选 hls.js 时：hls.js 失败 → 回退 .nativeIntercepted（一步），拦截器再失败
    ///   直接切下一条线，不回 hls.js；首选拦截器时：拦截器失败 → 回退 .hlsjs（一步）。
    ///   分片需头 -12881 也走拦截器→hls.js 这条（拦截器覆盖不了分片，hls.js 经 XHR 能给分片带头）。
    /// - 明文静态线裸连失败：把同一条线升级成拦截器再试一次（不消费 token，
    ///   明文线本来就没 token）；升级过的线不再升级，直接切下一条。
    /// - 非原生容器且没集成软解：报明确错误（需要软解播放器），不无意义重试。
    /// 先试下一条没失败过的线，都失败才报 failed。
    func markFailed(_ reason: String, stage: PlaybackFailureStage? = nil) {
        // 同一条 URL 只认一次失败：KVO .failed 和失败通知可能先后都到，
        // 不拦的话第二次会把刚切上的下一条线也误标失败。
        guard let current = currentURL?.absoluteString, !failedURLs.contains(current) else { return }
        // 分层：调用方传来的 stage 优先，否则用拦截器记的分层。
        let failureStage = stage ?? resourceLoader?.lastFailureStage
        let failureStatusCode = resourceLoader?.lastFailureStatusCode
        // FairPlay：拦截器已在播单里见到 skd://，直接明确报错。
        if resourceLoader?.encounteredFairPlay == true {
            failedURLs.insert(current)
            failureReason = "这条线路用了 FairPlay 加密（skd://），当前播放器不支持，请换一条线路"
            status = .failed(failureReason!)
            return
        }
        let currentLine = lines.first(where: { $0.url == current })
        let hintIsHLSJS = (currentLine?.playerHint ?? "").lowercased().contains("hlsjs")
        // 过期/一次性 URL 不再自动重试：签名线在 key 层失败（403/401，重拉+重铸已尽），
        // 同一条旧 URL 再换引擎试也没有意义——直接记过期、切下一条线。
        if hintIsHLSJS || PlaybackEngine.isSignedURL(current),
           failureStage == .keyFetch {
            expiredTokenURLs.insert(current)
            failedURLs.insert(current)
            if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
                routeLine(next)
                return
            }
            failureReason = layeredReason(stage: .keyFetch, statusCode: failureStatusCode, fallback: reason)
            status = .failed(failureReason!)
            return
        }
        if hintIsHLSJS {
            // hls.js 失败 → Native HLS 兼容实现（拦截器），只试一次。
            if currentEngine == .hlsjs, !hasTriedFallback(url: current, engine: .nativeIntercepted) {
                markFallbackTried(url: current, engine: .nativeIntercepted)
                engineOverrides[current] = .nativeIntercepted
                if let line = currentLine {
                    routeLine(line)
                    return
                }
            }
            // 拦截器失败 → hls.js 重试同一条线一次（分片需头 -12881 也走这条：
            // 拦截器覆盖不了分片，hls.js 经 XHR 能给分片带头）。
            if currentEngine == .nativeIntercepted,
               PlaybackCapabilities.hasHLSJS,
               !hasTriedFallback(url: current, engine: .hlsjs) {
                markFallbackTried(url: current, engine: .hlsjs)
                engineOverrides[current] = .hlsjs
                resourceLoader = nil
                currentEngine = .hlsjs
                status = .loading
                failureReason = nil
                return
            }
        }
        // 裸连失败升级拦截器：只对明文静态线（无签名、无自定义头、无 Cookie），
        // 同一条线只升级一次；带 token 的线不重试同一条（不消费一次性 token）。
        if currentEngine == .native,
           let line = currentLine,
           PlaybackEngine.isPlainStaticLine(line),
           !hasTriedFallback(url: current, engine: .nativeIntercepted) {
            markFallbackTried(url: current, engine: .nativeIntercepted)
            engineOverrides[current] = .nativeIntercepted
            routeLine(line)
            return
        }
        failedURLs.insert(current)
        if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
            routeLine(next)
            return
        }
        if !PlaybackCapabilities.hasSoftwareDecoder, PlaybackEngine.isUnsupportedContainer(current) {
            let ext = URL(string: current)?.pathExtension.lowercased() ?? ""
            failureReason = "这条线路是 .\(ext) 格式，需要软解播放器，当前版本未集成软解"
            status = .failed(failureReason!)
            return
        }
        failureReason = layeredReason(stage: failureStage, statusCode: failureStatusCode, fallback: reason)
        status = .failed(failureReason!)
    }

    /// 分层错误文案：播单/key/分片 + HTTP 状态码；没分层信息时退回原 reason。
    private func layeredReason(stage: PlaybackFailureStage?, statusCode: Int?, fallback: String) -> String {
        switch stage {
        case .playlistFetch:
            if let statusCode {
                return "播单拉取失败（HTTP \(statusCode)）"
            }
            return "播单拉取失败"
        case .keyFetch:
            if let statusCode {
                return "密钥请求失败（HTTP \(statusCode)，签名可能已过期）"
            }
            return "密钥请求失败（签名可能已过期）"
        case .segmentFetch:
            if let statusCode {
                return "分片拉取失败（HTTP \(statusCode)，分片可能需要请求头）"
            }
            return "分片拉取失败（分片可能需要请求头，已回退 hls.js）"
        case .playback, nil:
            return fallback
        }
    }

    /// 播放器出首帧后调（Views 层监听 AVPlayerItem status / 开始播放）。
    func markPlaying() {
        if case .failed = status { return }
        failureReason = nil
        status = .playing
    }

    /// 离开详情页即停播：清 URL 与线路，旧的后台备线任务回来也会被 generation 拦住。
    /// 正在跑的解流也取消、WebView 也清掉（嵌入页不继续在后台跑）。
    func stop() {
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        webViewURL = nil
        isResolvingEmbed = false
        playGeneration = UUID()
        currentURL = nil
        currentHeaders = nil
        currentEngine = .native
        resourceLoader = nil
        currentHost = nil
        currentRecastLink = nil
        currentRecastTitle = nil
        engineOverrides = [:]
        triedEngineFallbacks = []
        expiredTokenURLs = []
        keyRecastAttemptedURLs = []
        currentItemLink = nil
        lines = []
        status = .idle
        failureReason = nil
    }
}
