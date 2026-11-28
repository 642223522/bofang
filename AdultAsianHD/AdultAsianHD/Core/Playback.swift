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

    /// 嵌入页（要先解流或 WebView 播）：playerHint 明确标嵌入
    /// （"embed"/"webview"），或 URL 形态是嵌页（路径含 /e/、/embed/、/player/，
    /// 或扩展名是 .html/.htm/.php/.aspx/.jsp）。
    /// 不再对“非直链即嵌页”一刀切（P0-6）：无后缀直链、无 hint 的不透明
    /// URL 不是嵌页，须留给 route(for:) 的 Step 5 兜底（.nativeIntercepted 试播），
    /// 否则 javtiful 这类直链会被误路由进 WebView。
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
        let path = url.path.lowercased()
        if path.contains("/e/") || path.contains("/embed/") || path.contains("/player/") {
            return true
        }
        return ["html", "htm", "php", "aspx", "jsp"].contains(url.pathExtension.lowercased())
    }

    /// 一条可播线路的种类（竞速用；播放路由仍用 route(for:) 的完整判定）。
    enum PlayableLineKind {
        case hls
        case directFile
        case embed
    }

    /// 统一分类器：竞速用这一个入口，不再手写 .m3u8/.mp4 子串判断。
    /// 顺序：
    ///  1. URL 含 .m3u8 → .hls；含 .mp4/.mov → .directFile（沿用 isDirectMediaURL）。
    ///  2. playerHint：exact "mp4"/"direct"/"avplayer" → .directFile；"hls"/"m3u8" → .hls；
    ///     含 "embed"/"webview"/"hlsjs" → .embed（"hlsjs" 不当直链，它明确走 WebView）。
    ///     这一步兜底无扩展名签发直链（如 javtiful 的 /media/video/<id>/720p，
    ///     URL 里没有 .mp4，模块须给 playerHint "mp4"，否则会被下面误判成嵌页。
    ///  3. URL 形态：path 含 /e/、/embed/、/player/ → .embed。
    ///  4. 其余 http(s) URL → .directFile（按内容校验兜底；Step 5 遇 HTML 时回退按嵌页重验）。
    ///  5. 非 http(s) / 空 URL → nil。
    static func classifyPlayableLine(_ line: PlayLine) -> PlayableLineKind? {
        let trimmed = line.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        if isDirectMediaURL(trimmed) {
            return trimmed.lowercased().contains(".m3u8") ? .hls : .directFile
        }
        if let hint = line.playerHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !hint.isEmpty {
            if hint == "mp4" || hint == "direct" || hint == "avplayer" { return .directFile }
            if hint == "hls" || hint == "m3u8" { return .hls }
            if hint.contains("embed") || hint.contains("webview") || hint.contains("hlsjs") { return .embed }
        }
        let path = url.path.lowercased()
        if path.contains("/e/") || path.contains("/embed/") || path.contains("/player/") { return .embed }
        return .directFile
    }

    /// 按播放真实顺序排序候选线：模块返回顺序；preferredKind 有值时把该种线提到最前
    /// （其余保持原顺序）。播放试线就是这个顺序（失败换下一条未试过的线）。
    static func orderPlayableLines(_ lines: [PlayLine], preferredKind: PreferredLine?) -> [PlayLine] {
        guard let preferred = preferredKind else { return lines }
        let preferredLines = lines.filter { preferredLineKind(of: $0) == preferred }
        let rest = lines.filter { preferredLineKind(of: $0) != preferred }
        return preferredLines + rest
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

    /// 路由表（Q5：证据优先——内容事实 > URL 形态 > hint > 默认）。
    /// 内容事实（首响应状态、重定向落点、首字节签名）只有取过才知道，路由时
    /// 只能按形态 + hint 判；取过之后的内容事实记进账本/不匹配记录，下次同模块
    /// 同模板走路线记忆。hint 只调梯子方向与升级 P 的先验，绝不强制指定播放器。
    /// - .mpd → .dash（绝不再往 AVPlayer 送）。
    /// - 非原生容器（.mkv/.flv/.avi/.webm）→ .softDecoder；没集成软解时路由到
    ///   .nativeIntercepted，失败时由 markFailed 报明确错误，不无意义重试。
    /// - 媒体形态（.m3u8/.mp4/.mov）：内容优先——hint=embed/webview + 媒体 URL
    ///   不再直接进 WebView（是 HLS 先走 D/P；“须在页上下文里取”的含义记到
    ///   不匹配日志里，梯度里再考虑 WebView）。hint=hlsjs 的 HLS 优先 hls.js，
    ///   其次才是拦截器那条（.nativeIntercepted，标明为 Native HLS 兼容实现，
    ///   不要把拦截器说成 hls.js）；hls.js 失败 → 回退到 .nativeIntercepted（一步，不循环）。
    ///   hlsjs+MP4 也可能需要 Cookie/Referer，走 .nativeIntercepted，不直接丢给 AVPlayer 裸播。
    /// - URL 含签名/token、模块给了自定义头/Cookie → .nativeIntercepted。
    /// - hint=native+明文 → .native；未知 hint 先按 URL 形态判，判不出走 .nativeIntercepted 试播。
    /// - 签名/token/加密/有自定义头/Cookie 的线直接走拦截器，不试裸连；
    ///   只有明文静态、无加密、无自定义头的线才先裸连、失败再升级拦截器（见 markFailed）。
    /// - 嵌页形态（/e/、/embed/、/player/、.html/.php 或 embed/webview hint）
    ///   → .webView；无 hint 的不透明 URL → .nativeIntercepted 试播（Step 5，
    ///   hint=native+嵌页是 hint_vs_content）。
    static func route(for line: PlayLine) -> PlayerEngine {
        let hint = (line.playerHint ?? "").lowercased()
        let lower = line.url.lowercased()
        guard let url = URL(string: line.url),
              url.scheme == "http" || url.scheme == "https" else {
            // 非 http(s) 地址（如自定义 scheme 的 epLink 被误当成线）：判不出，
            // 走拦截器试播，不直接报错。
            return .nativeIntercepted
        }
        let ext = url.pathExtension.lowercased()
        // 1. .mpd → DASH（在 isEmbedURL 之前判：.mpd 不是 AVPlayer 直链，
        //    也不是嵌页路径形态，必须先按 DASH 分流）。
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
        // 2. 非原生容器 → 软解（无软解则拦截器试播，失败报明确错误）。
        if ["mkv", "flv", "avi", "webm"].contains(ext) {
            return PlaybackCapabilities.hasSoftwareDecoder ? .softDecoder : .nativeIntercepted
        }
        // 3a. 显式直链 hint（classifyPlayableLine 的既有映射：exact "mp4"/
        //     "direct"/"avplayer" → 直链文件，"hls"/"m3u8" → HLS，"native" 同直链）。
        //     无扩展名直链（如 /media/video/<id>/720p + hint "mp4"）在此认出，
        //     不再掉进 Step 4 被 isEmbedURL 误判成嵌页（P0-6：javtiful 回归）。
        //     hint 含 hlsjs 不走这里：classify 把它归为嵌页，hlsjs+媒体 URL
        //     由下面 Step 3 的 hlsjs 分支处理，hlsjs+嵌页 URL 走 Step 4。
        //     带签名/自定义头/Cookie 或无扩展名 → .nativeIntercepted；
        //     明文带扩展名 → .native（与 Step 3 的同类分支一致）。
        let directHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["mp4", "direct", "avplayer", "hls", "m3u8", "native"].contains(directHint) {
            let needsIntercept = isSignedURL(line.url)
                || line.headers?.isEmpty == false
                || line.cookie?.isEmpty == false
                || ext.isEmpty
            if needsIntercept { return .nativeIntercepted }
            return .native
        }
        // 3. 媒体形态（m3u8/mp4/mov）：内容优先，hint 只调起手路线。
        //    hint=embed/webview + 媒体 URL 不再直接进 WebView（Q5：内容优先，是 HLS 先走 D/P；
        //    “须在页上下文里取”的含义记到不匹配日志里，梯度里再考虑 WebView）。
        let isMediaForm = ["m3u8", "mp4", "mov"].contains(ext)
            || lower.contains(".m3u8") || lower.contains(".mp4")
        if isMediaForm {
            if hint.contains("hlsjs") {
                if ext == "m3u8" || lower.contains(".m3u8") {
                    return PlaybackCapabilities.hasHLSJS ? .hlsjs : .nativeIntercepted
                }
                // hlsjs+MP4 也可能需要 Cookie/Referer，走拦截器，不裸播。
                return .nativeIntercepted
            }
            let needsIntercept = isSignedURL(line.url)
                || line.headers?.isEmpty == false
                || line.cookie?.isEmpty == false
            if needsIntercept { return .nativeIntercepted }
            if hint.contains("native") || hint.isEmpty { return .native }
            // 未知 hint 的媒体 URL：形态判得出，走拦截器试播。
            return .nativeIntercepted
        }
        // 4. 嵌页形态 → WebView（isEmbedURL 已收紧：只认 embed/webview hint
        //    或嵌页路径形态；无 hint 的不透明 URL 不再误判，在 Step 5 兜底）。
        if isEmbedURL(line.url, playerHint: line.playerHint) {
            return .webView
        }
        // 5. 不透明 URL → 拦截器试播。
        if ext.isEmpty {
            return .nativeIntercepted
        }
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
    /// 嵌入重试计数（run #20 F3）：retryEmbed() 每点一次 +1；
    /// WebViewPlayerView 监听它，重试时把探针整套状态清掉重开
    ///（看门狗的 failedReported/loadStartedAt/challengeReloaded 都归零，
    /// 同一 URL 重试也有新鲜的 45 秒窗口）。
    @Published var embedRetryNonce = 0
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

    /// 回环代理实例（currentEngine == .proxy 时持有；换线/停播时释放，见 releaseProxy）。
    private var proxyServer: LoopbackProxyServer?
    /// 回环播放地址（.proxy 时为 127.0.0.1 入口 URL，否则 nil）。
    @Published var proxyURL: URL?
    /// 播放用的实际地址：代理时为回环 URL，否则为线路原地址。
    /// DetailView 把它传给 CustomPlayerView（不是 currentURL——代理时播放器
    /// 只能看到回环地址，原始 https 地址只留在 ViewModel 里作线路身份）。
    var playerURL: URL? { proxyURL ?? currentURL }
    /// 代理是否在播单里见过 skd://（FairPlay）：CustomPlayerController 读它报明确错误。
    var proxyEncounteredFairPlay: Bool { proxyServer?.hasEncounteredFairPlay() == true }

    /// 当前播放尝试的账本 id（routeLine 起新线时开，markPlaying/markFailed 终局时结）。
    private var ledgerAttemptId: UUID?
    /// 当前账本尝试对应的线路 URL（换引擎重进 routeLine 时不另开账本）。
    private var ledgerAttemptLineURL: String?
    /// 当前片/当前集是否在播放时刻现铸过（账本 stage 用）。
    private var ledgerRecastAtPlay = false
    /// 播放器自身日志（errorLog/accessLog，CustomPlayerController 回传）：
    /// errorLog 的 URI 是 AVPlayer 实际请求失败的地址（绕过判定用），
    /// accessLog 的 serverAddress 说明实际连到了哪台 IP、有没有换过服务器。
    private var lastPlayerErrorURI: String?
    private var lastPlayerServerAddress: String?
    private var lastPlayerAddressChanges: Int = 0
    /// 绕过信号：errorLog 指向原始 https 地址且在期望账本里
    /// （宿主改写过它，AVPlayer 却直接去取了原地址）——升级 P 的条件之一。
    private var lastBypassSignal = false
    /// 路由时记的不匹配记录 id（终局时把 outcome 与嗅探结果补上去）。
    private var pendingMismatchId: UUID?
    /// 当前片的 item id（账本/不匹配记录用；play(item:) 里记）。
    private var currentItemId: String?

    /// 当前片的模块 id（账本/路线记忆用；host 的 stream 模块 id）。
    private var currentModuleId: String {
        guard let host = currentHost else { return "" }
        return host.modules.first(where: { $0.type == "stream" })?.id
            ?? host.modules.first?.id ?? ""
    }

    // MARK: - 回环代理（P 路）生命周期

    /// 释放代理：停监听、清入口 URL。换线/切引擎/停播时调。
    private func releaseProxy() {
        proxyServer?.stop()
        proxyServer = nil
        proxyURL = nil
    }

    /// 给一条线起回环代理：建 server（身份头与拦截器同款），异步起监听；
    /// 就绪后生成入口 URL 交给播放器（playerURL），播放器视图随 proxyURL 变而重建 item。
    /// 起不来：记 sticky 失败（以后不再试 P），直接报失败走梯子（markFailed 继续到 J/下一条线）。
    private func startProxy(for line: PlayLine) {
        releaseProxy()
        guard let originalURL = URL(string: line.url) else {
            failureReason = "这条线路的地址不对，播不了"
            status = .failed(failureReason!)
            return
        }
        let server = LoopbackProxyServer(headers: interceptedHeaders(for: line))
        proxyServer = server
        server.setRestartHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.proxyServerRestarted()
            }
        }
        // start 的 completion 在监听队列上调：跳回主线程再碰 ViewModel 的状态。
        server.start { [weak self] ok in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 换线/停播后才就绪的监听：server 已被释放，不认（不复活旧代理）。
                guard self.proxyServer === server else { return }
                if ok {
                    self.proxyURL = server.entryURL(for: originalURL)
                    if self.proxyURL == nil {
                        self.markFailed("回环代理启动失败")
                    }
                } else {
                    PlaybackCapabilities.loopbackProxyBindFailed = true
                    self.releaseProxy()
                    self.markFailed("回环代理启动失败")
                }
            }
        }
    }

    /// 监听重启（进程挂起后端口变了）：同一 server、同一 token，只换端口；
    /// 重新生成入口 URL，播放器看到新 URL 重建 item，同 generation 下按当前进度续播。
    private func proxyServerRestarted() {
        guard let server = proxyServer, let url = currentURL else { return }
        proxyURL = server.entryURL(for: url)
    }

    /// 播放器自身日志回传（CustomPlayerController 在失败/首帧时调）：
    /// errorLog 的 URI 是 AVPlayer 实际请求失败的地址，accessLog 的 serverAddress
    /// 说明实际连到了哪台 IP、有没有换过服务器。顺带算绕过信号：
    /// errorLog 指向原始 https 地址且在期望账本里，即宿主改写过它、AVPlayer 却直接取了原地址。
    func recordPlayerLogs(errorURI: String?, serverAddress: String?, addressChanges: Int) {
        lastPlayerErrorURI = errorURI
        lastPlayerServerAddress = serverAddress
        lastPlayerAddressChanges = addressChanges
        lastBypassSignal = false
        if let errorURI, let errorURL = URL(string: errorURI),
           (errorURL.scheme == "http" || errorURL.scheme == "https"),
           errorURL.host != "127.0.0.1" {
            var expectedHashes = Set<String>()
            if let loader = resourceLoader {
                expectedHashes.formUnion(loader.knownKeyURLStrings().map { PlaybackLedger.templateHash(for: $0) })
                if let current = currentURL?.absoluteString {
                    expectedHashes.insert(PlaybackLedger.templateHash(for: current))
                }
            }
            if let server = proxyServer {
                expectedHashes.formUnion(server.expectedTemplateHashes())
            }
            if expectedHashes.contains(PlaybackLedger.templateHash(for: errorURI)) {
                lastBypassSignal = true
            }
        }
    }

    // MARK: - 账本 / 不匹配 / 路线记忆

    /// 路线记忆的键（模块 + host + URL 模板哈希 + hint + 网络类）。
    private func routeMemoryKey(for line: PlayLine) -> RouteMemoryKey {
        RouteMemoryKey(
            moduleId: currentModuleId,
            host: URL(string: line.url)?.host ?? "",
            urlTemplateHash: PlaybackLedger.templateHash(for: line.url),
            hint: line.playerHint ?? "",
            networkClass: PlaybackLedger.networkClass
        )
    }

    /// 身份配方摘要（路线记忆里记“这次走通用了哪套身份”，供下次复用）：
    /// UA + Referer 是底，Cookie/模块自定义头有才加。
    private func identityRecipe(for line: PlayLine) -> String {
        var parts = ["UA", "Referer"]
        if line.cookie?.isEmpty == false { parts.append("Cookie") }
        if line.headers?.isEmpty == false { parts.append("模块头") }
        return parts.joined(separator: "+")
    }

    /// 嗅探类型（路线记忆里记“这次靠什么内容事实判的”）：
    /// 代理首取 / 拦截器预检 / JS 的 XHR / 页内 WebView / 无。
    private func currentSniffType() -> String {
        switch currentEngine {
        case .proxy: return "proxy-first-fetch"
        case .nativeIntercepted: return "loader-preflight"
        case .hlsjs, .dash: return "js-xhr"
        case .webView: return "webview"
        case .native, .softDecoder: return "none"
        }
    }

    /// 嗅探结果摘要（终局时写进不匹配记录）：代理/拦截器各自首取的状态与种类。
    private func sniffDescription() -> String {
        var parts: [String] = []
        if let server = proxyServer {
            let (_, actual) = server.bookSnapshot()
            if let first = actual.first {
                parts.append("代理首取 \(first.upstreamStatus.map(String.init) ?? "无响应")（\(first.kindLabel)）")
            }
        }
        if let loader = resourceLoader {
            let book = loader.requestBookSnapshot()
            if let first = book.first {
                parts.append("拦截器首取 \(first.statusCode.map(String.init) ?? "无响应")（\(first.kind)）")
            }
        }
        if parts.isEmpty { return "无实际请求" }
        return parts.joined(separator: "；")
    }

    /// 起一条新账本（routeLine 进新线时调；同线换引擎重进不另开）。
    /// 播放器日志与绕过信号按线清零（上一条线的信号不能带到下一条线）。
    private func beginLedgerAttempt(for line: PlayLine) {
        ledgerAttemptId = PlaybackLedger.shared.beginAttempt(
            moduleId: currentModuleId,
            itemId: currentItemId ?? line.name,
            lineURL: line.url,
            hint: line.playerHint ?? "",
            recastAtPlay: ledgerRecastAtPlay
        )
        ledgerAttemptLineURL = line.url
        ledgerRecastAtPlay = false
        lastPlayerErrorURI = nil
        lastPlayerServerAddress = nil
        lastPlayerAddressChanges = 0
        lastBypassSignal = false
    }

    /// 梯子每走一级记一级（连续重复去重）。
    private func noteLedgerEngine(_ engine: PlayerEngine) {
        guard let id = ledgerAttemptId else { return }
        PlaybackLedger.shared.noteEngine(engine, attemptId: id)
    }

    /// 路由时记不匹配（hint 与 URL 形态不一致即记；一致的不记，免得账本被“无不匹配”淹没）。
    /// 终局时把 outcome 与嗅探结果补上去（见 finalizeLedgerAttempt）。
    private func noteRoutingMismatch(for line: PlayLine, engine: PlayerEngine) {
        let hint = (line.playerHint ?? "").lowercased()
        let lower = line.url.lowercased()
        let url = URL(string: line.url)
        let ext = url?.pathExtension.lowercased() ?? ""
        let urlForm: String
        if ext == "mpd" || lower.contains(".mpd") {
            urlForm = "DASH(.mpd)"
        } else if ext == "m3u8" || lower.contains(".m3u8") {
            urlForm = "HLS(.m3u8)"
        } else if ext == "mp4" || lower.contains(".mp4") {
            urlForm = "MP4"
        } else if PlaybackEngine.isEmbedURL(line.url, playerHint: line.playerHint) {
            urlForm = "嵌页"
        } else if ext.isEmpty {
            urlForm = "不透明 URL"
        } else {
            urlForm = ".\(ext)"
        }
        // 路由已认的 hint（含 Step 3a 的显式直链 hint）：不再记“未知 hint”。
        let knownHints = ["native", "hlsjs", "embed", "webview", "dash",
                          "mp4", "direct", "avplayer", "hls", "m3u8"]
        let mismatch: MismatchKind
        let evidence: String
        if hint.isEmpty {
            mismatch = .hintAbsent
            evidence = "无 hint，按 URL 形态 \(urlForm) 判"
        } else if !knownHints.contains(where: { hint.contains($0) }) {
            mismatch = .hintUnknown
            evidence = "未知 hint「\(line.playerHint ?? "")」，按 URL 形态 \(urlForm) 判"
        } else if (hint.contains("embed") || hint.contains("webview"))
                    && (urlForm == "HLS(.m3u8)" || urlForm == "MP4" || urlForm.hasPrefix("DASH")) {
            mismatch = .hintVsForm
            evidence = "hint 称嵌页，但 URL 形态是 \(urlForm)（内容优先，走媒体路线）"
        } else if hint.contains("hlsjs") && urlForm == "嵌页" {
            mismatch = .hintVsForm
            evidence = "hint 称 hlsjs，但 URL 形态是嵌页（走 WebView 解流）"
        } else if hint.contains("native") && urlForm == "嵌页" {
            mismatch = .hintVsForm
            evidence = "hint 称原生，但 URL 形态是嵌页（走 WebView 解流）"
        } else {
            return // hint 与形态一致：不记。
        }
        let record = RouteMismatch(
            at: Date(), moduleId: currentModuleId, itemId: currentItemId ?? line.name,
            hintDeclared: line.playerHint ?? "", urlForm: urlForm, sniff: "路由时未嗅探",
            evidenceUsed: evidence, decision: engine.displayName, mismatch: mismatch,
            ladderSteps: [engine.displayName], outcome: "待定"
        )
        PlaybackLedger.shared.recordMismatch(record)
        pendingMismatchId = record.id
    }

    /// 终局：合并拦截器/代理的账本快照，定 stage 与三路判定；不匹配记录收尾。
    /// 已终局的尝试再次终局是空操作（markPlaying 可能被多次触发）。
    private func finalizeLedgerAttempt(outcome: String, playedOK: Bool) {
        guard let id = ledgerAttemptId else { return }
        ledgerAttemptId = nil
        ledgerAttemptLineURL = nil
        // 合并本次的账本：拦截器 + 回环代理各自记的实际请求。
        var expected: [LedgerBookEntry] = []
        var actual: [LedgerBookEntry] = []
        if let loader = resourceLoader {
            for item in loader.requestBookSnapshot() {
                actual.append(LedgerBookEntry(
                    token: String(PlaybackLedger.templateHash(for: item.url).prefix(8)),
                    kind: BookKind(rawValue: item.kind) ?? .segment,
                    host: URL(string: item.url)?.host ?? "",
                    pathTemplateHash: PlaybackLedger.templateHash(for: item.url),
                    upstreamStatus: item.statusCode,
                    bytes: nil,
                    servedFromCache: false
                ))
            }
            for keyURL in loader.knownKeyURLStrings() {
                expected.append(LedgerBookEntry(
                    token: String(PlaybackLedger.templateHash(for: keyURL).prefix(8)),
                    kind: .key,
                    host: URL(string: keyURL)?.host ?? "",
                    pathTemplateHash: PlaybackLedger.templateHash(for: keyURL),
                    upstreamStatus: nil,
                    bytes: nil,
                    servedFromCache: false
                ))
            }
            if let current = currentURL?.absoluteString {
                expected.append(LedgerBookEntry(
                    token: String(PlaybackLedger.templateHash(for: current).prefix(8)),
                    kind: .playlist,
                    host: URL(string: current)?.host ?? "",
                    pathTemplateHash: PlaybackLedger.templateHash(for: current),
                    upstreamStatus: loader.preflightPlaylistStatusCode,
                    bytes: nil,
                    servedFromCache: false
                ))
            }
        }
        if let server = proxyServer {
            let (exp, act) = server.bookSnapshot()
            expected.append(contentsOf: exp)
            actual.append(contentsOf: act)
        }
        PlaybackLedger.shared.mergeBooks(expected: expected, actual: actual, attemptId: id)
        let gaps = proxyServer?.rewriteGapCount() ?? 0
        PlaybackLedger.shared.finalizeAttempt(
            id, outcome: outcome, playedOK: playedOK,
            errorURI: lastPlayerErrorURI, serverAddress: lastPlayerServerAddress,
            addressChanges: lastPlayerAddressChanges, rewriteGaps: gaps
        )
        // 不匹配记录收尾：路由时记的把 outcome、嗅探结果、完整梯子补上；
        // 终局判定是被绕过/上游拒绝/播放器拒收、路由时又没记过不匹配的，
        // 再补一条内容事实层面的不匹配（路由的假设被内容证伪了）。
        let sniff = sniffDescription()
        let attempt = PlaybackLedger.shared.attempts.first(where: { $0.id == id })
        let ladderSteps = attempt?.ladder.map { $0.displayName } ?? []
        if let mismatchId = pendingMismatchId {
            pendingMismatchId = nil
            PlaybackLedger.shared.updateMismatch(id: mismatchId, outcome: outcome, sniff: sniff, ladderSteps: ladderSteps, kind: nil)
        } else {
            let verdict = attempt?.verdict ?? .unknown
            let kind: MismatchKind?
            let evidence: String
            switch verdict {
            case .bypassed:
                kind = .hintVsContent
                evidence = "路由按 hint/形态选了 \(attempt?.ladder.first?.displayName ?? "")，内容事实：AVPlayer 直接取了原始 https 地址，拦截/代理未命中"
            case .rejectedUpstream:
                kind = .formVsContent
                evidence = "URL 形态称可播，内容事实：上游返回 4xx/5xx"
            case .avPlayerRejected:
                kind = .formVsContent
                evidence = "URL 形态称可播，内容事实：代理/拦截器拿到 2xx，播放器仍拒收"
            default:
                kind = nil
                evidence = ""
            }
            if let kind {
                PlaybackLedger.shared.recordMismatch(RouteMismatch(
                    at: Date(), moduleId: attempt?.moduleId ?? currentModuleId,
                    itemId: attempt?.itemId ?? "", hintDeclared: attempt?.hint ?? "",
                    urlForm: "", sniff: sniff, evidenceUsed: evidence,
                    decision: attempt?.ladder.first?.displayName ?? "",
                    mismatch: kind, ladderSteps: ladderSteps, outcome: outcome
                ))
            }
        }
    }

    /// 该线路实际走的引擎：有强制覆盖（回退/升级）用覆盖；否则先查路线记忆
    /// （同一模块+host+模板+hint 之前走通过的起手路线），没有才走路由表。
    private func engine(for line: PlayLine) -> PlayerEngine {
        if let override = engineOverrides[line.url] {
            return override
        }
        // 路线记忆（内容事实 rung）：之前同一模块+host+模板+hint 走通的起手路线，
        // 直接用它起手，省掉重新判；7 天内有效、2 次一致失败才过期（见 PlaybackLedger）。
        if let cached = PlaybackLedger.shared.cachedRoute(
            moduleId: currentModuleId,
            host: URL(string: line.url)?.host ?? "",
            urlTemplateHash: PlaybackLedger.templateHash(for: line.url),
            hint: line.playerHint ?? "",
            networkClass: PlaybackLedger.networkClass
        ) {
            return cached
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
    /// 全部合并走大小写不敏感的 NetConstants.mergeHeaders，避免 "user-agent" 与
    /// "User-Agent" 两个键同时存在时被字典遍历顺序随机覆盖。
    private func interceptedHeaders(for line: PlayLine) -> [String: String] {
        var base: [String: String] = ["User-Agent": PlaybackEngine.iPhoneUserAgent]
        if let referer = line.referer, !referer.isEmpty {
            base["Referer"] = referer
        } else if let referer = currentItemLink, !referer.isEmpty {
            base["Referer"] = referer
        }
        if let cookie = line.cookie, !cookie.isEmpty {
            base["Cookie"] = cookie
        }
        return NetConstants.mergeHeaders(base: base, overrides: line.headers ?? [:])
    }

    /// 给一条拦截线路建 HLSResourceLoader：头用 interceptedHeaders，Cookie 单独传；
    /// 密钥 403 重铸回调挂到 handleKeyAuthFailure。
    private func makeResourceLoader(for line: PlayLine) -> HLSResourceLoader {
        let loader = HLSResourceLoader(headers: interceptedHeaders(for: line), cookie: line.cookie)
        // PlaybackEngine 本身是 @MainActor，handleKeyAuthFailure() 也是
        // MainActor 隔离：直接 await 就会跳回主线程，不需要 MainActor.run
        // 包一层（且本工具链的 MainActor.run 只有同步 body 的重载，
        // 传 async 闭包编不过，见 GitHub Actions 首次运行报错）。
        loader.onKeyAuthFailed = { [weak self] in
            await self?.handleKeyAuthFailure() ?? false
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
        // 账本：这条线是播放时刻现铸的（密钥 403 后的重铸），stage 至少到 mint。
        ledgerRecastAtPlay = true
        routeLine(first)
        return true
    }

    /// 换当前线路：URL + 该线路要带的请求头一起换，状态回 .loading。
    /// URL 非法返回 false，调用方据此报“没有可用的播放线路”。
    /// 切到直链时，取消正在跑的解流、清掉 WebView（旧的解流结果不能再写回）。
    /// currentEngine == .nativeIntercepted 时建拦截器并挂到 resourceLoader：
    /// currentURL 保持 https 原地址（线路身份、失败去重、画质匹配都按它认），
    /// scheme 改写只发生在 CustomPlayerView 建 asset 那一步。
    /// currentEngine == .proxy 时起回环代理（异步监听）：currentURL 同样保持
    /// https 原地址，播放用的回环地址另存 proxyURL，playerURL 供播放器视图读；
    /// 监听就绪前 playerURL 还是原地址，但控制器对 .proxy 只认回环地址
    ///（见 CustomPlayerController.load），就绪前不建 asset、不裸播原地址；
    /// proxyURL 一到，视图随之重建 item 走回环。
    /// 发布顺序：先建好拦截器/起好代理、再设 currentURL/currentHeaders、最后设 currentEngine——
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
            releaseProxy()
        } else if resolvedEngine == .proxy {
            resourceLoader = nil
            startProxy(for: line)
        } else {
            resourceLoader = nil
            releaseProxy()
        }
        currentURL = url
        if resolvedEngine == .nativeIntercepted || resolvedEngine == .proxy {
            // 拦截/代理线路：Referer/UA/模块头/Cookie 全给拦截器或代理（子请求用），
            // currentHeaders 同步一份，供 HLS.js 回退的播放器复用；
            // 代理时 CustomPlayerView 不把 currentHeaders 挂到回环 asset 上
            //（回环地址不需要头，头由代理统一带——见 CustomPlayerController.load）。
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
    /// .native/.nativeIntercepted/.proxy → setCurrent（AVPlayer，拦截器线挂 delegate，
    /// 代理线起回环监听）；.webView → 现有 playEmbedLine；
    /// .hlsjs/.dash/.softDecoder → 只设 currentURL/currentHeaders/currentEngine/status=.loading，
    ///   不建 AVPlayer（视图层按 currentEngine 显示对应播放器，D 路负责）。
    /// 账本：进新线开一条尝试（同线换引擎重进不另开），梯子每走一级记一级，
    /// 路由时把 hint 与形态的不一致记下来（终局时补 outcome 与嗅探结果）。
    /// 返回 true 表示这条线已被接手（直链已设、嵌入流程已启动，或已交给对应播放器视图）。
    @discardableResult
    private func routeLine(_ line: PlayLine) -> Bool {
        let engine = self.engine(for: line)
        // 首选引擎即记为已试：回退只去没试过的引擎，不 ping-pong
        //（hlsjs → 拦截器是一步，拦截器失败不再回 hls.js——hls.js 首选时已试过）。
        markFallbackTried(url: line.url, engine: engine)
        // 账本：进新线开一条尝试（同线换引擎重进只记梯子）；路由时记 hint 与形态的不一致。
        // 换线时先把上一条线的尝试终局（切线），不留没终局的孤儿账本。
        if ledgerAttemptLineURL != line.url {
            finalizeLedgerAttempt(outcome: "切线", playedOK: false)
            beginLedgerAttempt(for: line)
            noteRoutingMismatch(for: line, engine: engine)
        }
        noteLedgerEngine(engine)
        switch engine {
        case .native, .nativeIntercepted, .proxy:
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
            releaseProxy()
            guard let url = URL(string: line.url) else {
                failureReason = "这条线路的地址不对，播不了"
                status = .failed("这条线路的地址不对，播不了")
                finalizeLedgerAttempt(outcome: "线路地址不对", playedOK: false)
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
                finalizeLedgerAttempt(outcome: "DASH 不支持", playedOK: false)
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
        releaseProxy()
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
        releaseProxy()
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
        // 上一场的账本尝试若还开着（同一 ViewModel 重播），先按停播终局。
        finalizeLedgerAttempt(outcome: "停播", playedOK: false)
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
        releaseProxy()
        currentItemLink = item.link
        currentItemId = item.id
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
                // 按需发现（run #20）：后台解出的线若能认出种类，先暂定为首选线
                //（竞速被推迟到首屏之后时，首点不因此慢；种子竞速跑完再覆盖它）。
                host.noteTappedVideoDiscovery(lines: merged)
                // 没快路径时，直接上第一条备线
                if self.currentURL == nil {
                    if let first = merged.first {
                        self.routeLine(first)
                    }
                    // 嵌入线已接手（正在解流，isResolvingEmbed=true，或墙后分支已把 URL
                    // 交给 WebView、webViewURL != nil）：别报失败，等解流/嵌页结果。
                    // 旧逻辑只查 isResolvingEmbed：墙后分支同步把 isResolvingEmbed=false、
                    // webViewURL=embedURL、status=.playing 写好了，走到这里 currentURL
                    // 仍是 nil、isResolvingEmbed 是 false，status 会被这句盖成 .failed，
                    // 用户看到“没有可用的播放线路”，而 WebView 里其实已经在播了。
                    if self.currentURL == nil && !self.isResolvingEmbed && self.webViewURL == nil {
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
                // 账本：这条线是播放时刻现铸的（分集点播的重铸），stage 至少到 mint。
                self.ledgerRecastAtPlay = true
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
    /// 播单拉取失败 / key 失败 / 分片失败 + HTTP 状态码（账本复用这套分层）。
    /// 分层铁证（见 PlaybackFailureStage）：VPN 不改头、不改 cookie——VPN 下可播，
    /// 则缺头/缺 cookie 不可能是首要根因；VPN 下仍不可播，才是头/cookie/解析问题；
    /// 明文流（pornjav）在 B 上也要代理，几乎一定在网络层，与 playerHint 无关。
    /// 恢复顺序（有限，不循环）：过期/一次性 URL 不自动重试同一条线 →
    /// hls.js ⇄ Native HLS 兼容实现（拦截器）各试一次 → 回环代理（P，
    /// 只在分片需头/拦截被绕过时升级）→ 裸连升级拦截器 →
    /// 切下一条线 → 报 failed。key 403 的链是：重拉播单一次 → 重铸一次 →
    /// 再失败即报失败切线（重拉+重铸在拦截器里，见 HLSResourceLoader）。
    /// - FairPlay（skd://）：拦截器或代理已在播单里见到 skd://，直接报明确错误，不切线重试。
    /// - hlsjs 线：每条线每个引擎最多试一次（路由首选的引擎即记为已试）——
    ///   首选 hls.js 时：hls.js 失败 → 回退 .nativeIntercepted（一步），拦截器再失败
    ///   直接切下一条线，不回 hls.js；首选拦截器时：拦截器失败 → 回退 .hlsjs（一步）。
    ///   分片需头 -12881 也走拦截器→hls.js 这条（拦截器覆盖不了分片，hls.js 经 XHR 能给分片带头）。
    /// - 明文静态线裸连失败：把同一条线升级成拦截器再试一次（不消费 token，
    ///   明文线本来就没 token）；升级过的线不再升级，直接切下一条。
    /// - 非原生容器且没集成软解：报明确错误（需要软解播放器），不无意义重试。
    /// 先试下一条没失败过的线，都失败才报 failed。
    /// 终局（切线/报 failed）时账本定 stage 与三路判定；分层明确的失败才写路线记忆。
    func markFailed(
        _ reason: String,
        stage: PlaybackFailureStage? = nil,
        httpStatusCode: Int? = nil,
        failedURL: URL? = nil
    ) {
        // 所有调用方都在主线程（PlayerViewModel 是 @MainActor）：不断言就
        // 悄悄把锁省了，万一哪天有后台调用方，assert 会在 DEBUG 抓住它。
        assert(Thread.isMainThread)
        // 拦截旧 item 迟到的失败回调，防误杀刚切好的新线。
        if let failedURL, failedURL != currentURL && failedURL != proxyURL { return }
        // 同一条 URL 只认一次失败：KVO .failed 和失败通知可能先后都到，
        // 不拦的话第二次会把刚切上的下一条线也误标失败。
        guard let current = currentURL?.absoluteString, !failedURLs.contains(current) else { return }
        // 分层：调用方传来的 stage 优先，否则用拦截器记的分层。
        let failureStage = stage ?? resourceLoader?.lastFailureStage
        // 状态码：调用方（播放器视图的 errorLog）优先，否则用拦截器记的。
        let failureStatusCode = httpStatusCode ?? resourceLoader?.lastFailureStatusCode
        // 404/410 说明服务端根本没有该片源（如 memojav 缺号），跳过同线引擎升级，直接切备用线。
        let isNotFound = (failureStatusCode == 404 || failureStatusCode == 410)
        // FairPlay：拦截器或代理已在播单里见到 skd://，直接明确报错。
        if resourceLoader?.encounteredFairPlay == true || proxyServer?.hasEncounteredFairPlay() == true {
            failedURLs.insert(current)
            failureReason = "这条线路用了 FairPlay 加密（skd://），当前播放器不支持，请换一条线路"
            status = .failed(failureReason!)
            finalizeLedgerAttempt(outcome: "FairPlay 加密，不支持", playedOK: false)
            return
        }
        let currentLine = lines.first(where: { $0.url == current })
        let hintIsHLSJS = (currentLine?.playerHint ?? "").lowercased().contains("hlsjs")
        // 404/410：服务端根本没有该片源，同线换引擎没有意义
        //（memojav 缺号时 native→拦截器→hls.js→代理全试一遍也是 404），
        // 直接跳过下面五段引擎升级，切备用线。
        if !isNotFound {
            // 过期/一次性 URL 不再自动重试：签名线在 key 层失败（403/401，重拉+重铸已尽），
            // 同一条旧 URL 再换引擎试也没有意义——直接记过期、切下一条线。
            if hintIsHLSJS || PlaybackEngine.isSignedURL(current),
               failureStage == .keyFetch {
                expiredTokenURLs.insert(current)
                failedURLs.insert(current)
                if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
                    finalizeLedgerAttempt(outcome: "密钥过期/一次性 token 失效", playedOK: false)
                    routeLine(next)
                    return
                }
                failureReason = layeredReason(stage: .keyFetch, statusCode: failureStatusCode, fallback: reason)
                status = .failed(failureReason!)
                finalizeLedgerAttempt(outcome: "密钥过期/一次性 token 失效", playedOK: false)
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
                    noteLedgerEngine(.hlsjs)
                    currentEngine = .hlsjs
                    status = .loading
                    failureReason = nil
                    return
                }
            }
            // P 失败 → J：代理也失败了，hlsjs 线、hls.js 可用、还没试过 hls.js 时，
            // 切 hls.js 再试一次（一步）；不是 hlsjs 线或 hls.js 已试过，直接走下面切线。
            if currentEngine == .proxy,
               hintIsHLSJS,
               PlaybackCapabilities.hasHLSJS,
               !hasTriedFallback(url: current, engine: .hlsjs) {
                markFallbackTried(url: current, engine: .hlsjs)
                engineOverrides[current] = .hlsjs
                resourceLoader = nil
                releaseProxy()
                noteLedgerEngine(.hlsjs)
                currentEngine = .hlsjs
                status = .loading
                failureReason = nil
                return
            }
            // D 失败 → P：回环代理升级（梯子 D → P → J 里的一级）。
            // 只在代理能帮上忙的信号下升级：分片需头（.segmentFetch / -12881，
            // 拦截器覆盖不了分片）或拦截被绕过（errorLog 指向原始 https 地址）；
            // 其他失败直接切线，不白跑代理。代理起监听失败过（sticky）也不再试。
            // 升级后由 routeLine 走 setCurrent(.proxy) 起监听；监听就绪才交回环地址给播放器。
            if (currentEngine == .nativeIntercepted || currentEngine == .hlsjs),
               !PlaybackCapabilities.loopbackProxyBindFailed,
               !hasTriedFallback(url: current, engine: .proxy),
               (failureStage == .segmentFetch || lastBypassSignal) {
                markFallbackTried(url: current, engine: .proxy)
                engineOverrides[current] = .proxy
                if let line = currentLine {
                    routeLine(line)
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
        }
        failedURLs.insert(current)
        if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
            finalizeLedgerAttempt(outcome: isNotFound ? "主线 404，自动切备用线" : "失败，切下一条线", playedOK: false)
            if let line = currentLine {
                // 分层明确的失败才写路线记忆（分层不明不写，避免把偶然失败记成路线）。
                PlaybackLedger.shared.recordRouteFailure(key: routeMemoryKey(for: line), clearClass: failureStage != nil)
            }
            routeLine(next)
            return
        }
        if !PlaybackCapabilities.hasSoftwareDecoder, PlaybackEngine.isUnsupportedContainer(current) {
            let ext = URL(string: current)?.pathExtension.lowercased() ?? ""
            failureReason = "这条线路是 .\(ext) 格式，需要软解播放器，当前版本未集成软解"
            status = .failed(failureReason!)
            finalizeLedgerAttempt(outcome: failureReason!, playedOK: false)
            return
        }
        failureReason = layeredReason(stage: failureStage, statusCode: failureStatusCode, fallback: reason)
        status = .failed(failureReason!)
        finalizeLedgerAttempt(outcome: failureReason!, playedOK: false)
        if let line = currentLine {
            PlaybackLedger.shared.recordRouteFailure(key: routeMemoryKey(for: line), clearClass: failureStage != nil)
        }
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
            return "分片拉取失败（分片可能需要请求头）"
        case .playback, nil:
            return fallback
        }
    }

    /// 播放器出首帧后调（Views 层监听 AVPlayerItem status / 开始播放）。
    /// 终局：账本记“播放中”，走通的起手路线写进路线记忆（下次同模块+host+模板+hint 直接用它）。
    func markPlaying() {
        if case .failed = status { return }
        failureReason = nil
        status = .playing
        finalizeLedgerAttempt(outcome: "播放中", playedOK: true)
        if let current = currentURL?.absoluteString,
           let line = lines.first(where: { $0.url == current }) {
            PlaybackLedger.shared.recordRouteSuccess(
                key: routeMemoryKey(for: line),
                firstRoute: currentEngine,
                identityRecipe: identityRecipe(for: line),
                sniffType: currentSniffType()
            )
        }
    }

    /// 嵌入播放终局失败（run #20 F3，探针看门狗调）：嵌页一直没出画面，
    /// 不是直链失败——markFailed 走不通（currentURL 是 nil，会被它早退拦掉），
    /// 所以单开一条路：状态 .failed + 原因，嵌入 URL 记一次失败、账本终局，
    /// 但 webViewURL / lines 都留着（DetailView 的“重试嵌入播放”按钮靠它们重播）。
    func markEmbedFailed(_ reason: String) {
        assert(Thread.isMainThread)
        if let embedURL = webViewURL?.absoluteString {
            failedURLs.insert(embedURL)
        }
        failureReason = reason
        status = .failed(reason)
        finalizeLedgerAttempt(outcome: "嵌入播放失败", playedOK: false)
    }

    /// 重试嵌入播放（run #20 F3，DetailView 的“重试嵌入播放”按钮调）：
    /// 找到 webViewURL 对应的线，清掉它的失败/回退标记，重新走路由
    ///（→ playEmbedLine，探针看门狗重新开始计时）。
    func retryEmbed() {
        guard let embedURL = webViewURL else { return }
        let urlString = embedURL.absoluteString
        failedURLs.remove(urlString)
        clearFallbackState(for: urlString)
        failureReason = nil
        status = .loading
        // 探针重开：同一 URL 重试不触发 WebViewPlayerView 的 onChange(of: url)，
        // 靠这个计数让它把探针状态清掉重开（看门狗重新计时）。
        embedRetryNonce += 1
        if let line = lines.first(where: { $0.url == urlString }) {
            routeLine(line)
        } else {
            routeLine(PlayLine(name: "嵌入播放", url: urlString, description: "嵌页重试"))
        }
    }

    /// 离开详情页即停播：清 URL 与线路，旧的后台备线任务回来也会被 generation 拦住。
    /// 正在跑的解流也取消、WebView 也清掉（嵌入页不继续在后台跑）。
    /// 开着的账本尝试按停播终局（已终局过的是空操作）；代理随停播释放。
    /// lines 故意留着（run #20 F3）：切 Tab 回来/重进详情页时，线路表还在，
    /// 失败的嵌入线能重试；play() 开头会重置 lines，不会残留到下一部片。
    func stop() {
        finalizeLedgerAttempt(outcome: "停播", playedOK: false)
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
        releaseProxy()
        currentHost = nil
        currentRecastLink = nil
        currentRecastTitle = nil
        currentItemId = nil
        engineOverrides = [:]
        triedEngineFallbacks = []
        expiredTokenURLs = []
        keyRecastAttemptedURLs = []
        currentItemLink = nil
        status = .idle
        failureReason = nil
    }
}
