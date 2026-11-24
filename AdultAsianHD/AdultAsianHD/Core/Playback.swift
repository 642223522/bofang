import Foundation

/// 播放快路径：番号 → memojav 静态播单直拼，不抓帖页、不验播单。
/// 点封面的一瞬间就能拼出播单 URL，直接交给 AVPlayer。
/// 线路竞速决出的首选线（按模块 id 存内存，进模块时重算）。
/// memojav：静态 m3u8，可直拼快路径；nmcorp：签名 MP4，必须走 loadResource 现解。
/// nil（没竞速 / 没分出胜负 / 两条都死 / 无固定验线）= 按现有逻辑（快路径 + 备线）。
enum PreferredLine: Equatable {
    case memojav
    case nmcorp
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

    /// 直链（AVPlayer 能直接播）：扩展名是 m3u8/mp4/mpd/mov，或 URL 里含 .m3u8/.mp4。
    /// 播单 URL 先过这一关：是直链走现有 AVPlayer，不是再看是不是嵌入页。
    static func isDirectMediaURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "mpd", "mov"].contains(ext) { return true }
        let lower = urlString.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4")
    }

    /// 嵌入页（要先解流或 WebView 播）：http(s) 链接且不是直链；
    /// 或 playerHint 明确标嵌入（"embed"/"webview"）。
    /// playmogo/dood 这类嵌入页 URL 走这条；huangguo 的直链 HLS 虽然 hint 也是 hlsjs，
    /// 但 URL 本身是 .m3u8，先被上一关认成直链，不会误判。
    static func isEmbedURL(_ urlString: String, playerHint: String? = nil) -> Bool {
        if let hint = playerHint?.lowercased(),
           hint.contains("embed") || hint.contains("webview") {
            return true
        }
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return false }
        return !isDirectMediaURL(urlString)
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
    @Published var status: PlayerStatus = .idle
    @Published var failureReason: String?
    /// 正在用页内 WebView 播的嵌入页地址（非 nil 时 DetailView 显示 WebView 播放器，不显示 AVPlayer）。
    @Published var webViewURL: URL?
    /// 正在跑混合解流（无界面 WebView 抽直链）时为 true，DetailView 显示“正在解析嵌入播放…”。
    @Published var isResolvingEmbed = false

    /// 已经失败过的线路 URL（切线时跳过，不来回横跳）
    private var failedURLs: Set<String> = []
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

    /// 换当前线路：URL + 该线路要带的请求头一起换，状态回 .loading。
    /// URL 非法返回 false，调用方据此报“没有可用的播放线路”。
    /// 切到直链时，取消正在跑的解流、清掉 WebView（旧的解流结果不能再写回）。
    @discardableResult
    private func setCurrent(_ line: PlayLine) -> Bool {
        guard let url = URL(string: line.url) else { return false }
        embedTask?.cancel()
        embedTask = nil
        embedExtractor?.cancel()
        embedExtractor = nil
        webViewURL = nil
        isResolvingEmbed = false
        currentURL = url
        // 解流得到的直链带了 Referer（嵌入页）：AVPlayer 取流时带上，CDN 要这个。
        // 没带 Referer 的线走原有逻辑（一字不动）。
        if let referer = line.referer, !referer.isEmpty {
            currentHeaders = ["Referer": referer, "User-Agent": PlaybackEngine.iPhoneUserAgent]
        } else {
            currentHeaders = PlaybackEngine.headers(forLineURL: line.url, referer: currentItemLink)
        }
        status = .loading
        failureReason = nil
        return true
    }

    /// 播一条线：直链走现有 AVPlayer（setCurrent，一字不动）；
    /// 嵌入页先走混合解流（解出直链→AVPlayer），解不出 fallback 到页内 WebView 播放器。
    /// 返回 true 表示这条线已被接手（直链已设或嵌入流程已启动）。
    @discardableResult
    private func routeLine(_ line: PlayLine) -> Bool {
        guard PlaybackEngine.isEmbedURL(line.url, playerHint: line.playerHint) else {
            return setCurrent(line)
        }
        playEmbedLine(line)
        return true
    }

    /// 嵌入页播放：先混合解流（15 秒），解出直链→AVPlayer；解不出→页内 WebView 播放器。
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
        isResolvingEmbed = true
        currentURL = nil
        currentHeaders = nil
        status = .loading
        failureReason = nil
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
                // 解出直链：Referer=嵌入页，交给现有 AVPlayer 通路；
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
                _ = self.setCurrent(directLine)
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
        lines = []
        failureReason = nil
        currentHeaders = nil
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
        routeLine(line)
    }

    /// 直接播一条指定线路（分集点播用）：把这条线放进线路列表并切过去。
    /// 已有同样 URL 的线不重复加；失败记录里有它就清掉（手动点的允许重试）。
    /// 地址非法时报 failed，不静默。
    /// 分集是新片：换 generation，自定义播放器从 0:00 起播（不同于 switchLine 的同片保进度）。
    func playLine(_ line: PlayLine) {
        playGeneration = UUID()
        failedURLs.remove(line.url)
        if !lines.contains(where: { $0.url == line.url }) {
            lines.insert(line, at: 0)
        }
        if !routeLine(line) {
            failureReason = "这条线路的地址不对，播不了"
            status = .failed("这条线路的地址不对，播不了")
        }
    }

    /// 播放器报错时调（Views 层监听 AVPlayerItemFailedToPlayToEndTime 等）。
    /// 先试下一条没失败过的线，都失败才报 failed。
    func markFailed(_ reason: String) {
        // 同一条 URL 只认一次失败：KVO .failed 和失败通知可能先后都到，
        // 不拦的话第二次会把刚切上的下一条线也误标失败。
        guard let current = currentURL?.absoluteString, !failedURLs.contains(current) else { return }
        failedURLs.insert(current)
        if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
            routeLine(next)
            return
        }
        failureReason = reason
        status = .failed(reason)
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
        currentItemLink = nil
        lines = []
        status = .idle
        failureReason = nil
    }
}
