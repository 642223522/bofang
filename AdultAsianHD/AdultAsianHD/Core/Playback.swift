import Foundation

/// 播放快路径：番号 → memojav 静态播单直拼，不抓帖页、不验播单。
/// 点封面的一瞬间就能拼出播单 URL，直接交给 AVPlayer。
enum PlaybackEngine {

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

/// 只管 URL 与线路状态；AVPlayer 本身由 Views 层包（AVPlayerViewController），
/// 这里不写任何 WebView 播放器。
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

    /// 已经失败过的线路 URL（切线时跳过，不来回横跳）
    private var failedURLs: Set<String> = []
    /// 每次 play 换一个 generation，旧的后台备线任务回来发现对不上就丢弃，
    /// 防止切到别的片后旧备线写回 lines。
    private var playGeneration = UUID()
    /// 当前片的帖页链接：nmcorp 签名 MP4 的 Referer 就用它（模块取播放器页时也是这个 Referer）。
    private var currentItemLink: String?

    /// 换当前线路：URL + 该线路要带的请求头一起换，状态回 .loading。
    /// URL 非法返回 false，调用方据此报“没有可用的播放线路”。
    @discardableResult
    private func setCurrent(_ line: PlayLine) -> Bool {
        guard let url = URL(string: line.url) else { return false }
        currentURL = url
        currentHeaders = PlaybackEngine.headers(forLineURL: line.url, referer: currentItemLink)
        status = .loading
        failureReason = nil
        return true
    }

    /// 点封面即播：快路径立刻设 currentURL，后台拿备线。
    func play(item: VideoItem, host: WidgetHost) async {
        let generation = UUID()
        playGeneration = generation
        failedURLs = []
        lines = []
        failureReason = nil
        currentHeaders = nil
        currentItemLink = item.link
        status = .loading

        // 快路径：标题抠番号，直拼播单，立刻交给播放器
        if let fastURL = PlaybackEngine.fastPathURL(for: item) {
            let fastLine = PlayLine(name: "快速线", url: fastURL.absoluteString, description: "番号直拼，秒播")
            lines = [fastLine]
            setCurrent(fastLine)
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
                        self.setCurrent(first)
                    }
                    if self.currentURL == nil {
                        self.status = .failed("没有可用的播放线路")
                        self.failureReason = "这个视频没有可用的播放线路"
                    }
                    return
                }
                // 快路径已经失败过了、备线刚到：有没试过的备线就立刻续上
                if case .failed = self.status,
                   let next = merged.first(where: { !self.failedURLs.contains($0.url) }) {
                    self.setCurrent(next)
                }
            }
        }
    }

    /// 点线路切线（在小窗口里切，不重建播放器，由 Views 层换 AVPlayerItem）。
    func switchLine(_ line: PlayLine) {
        failedURLs.remove(line.url) // 手动点的线允许重试：先清掉它的失败记录
        setCurrent(line)
    }

    /// 播放器报错时调（Views 层监听 AVPlayerItemFailedToPlayToEndTime 等）。
    /// 先试下一条没失败过的线，都失败才报 failed。
    func markFailed(_ reason: String) {
        // 同一条 URL 只认一次失败：KVO .failed 和失败通知可能先后都到，
        // 不拦的话第二次会把刚切上的下一条线也误标失败。
        guard let current = currentURL?.absoluteString, !failedURLs.contains(current) else { return }
        failedURLs.insert(current)
        if let next = lines.first(where: { !failedURLs.contains($0.url) }) {
            setCurrent(next)
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
    func stop() {
        playGeneration = UUID()
        currentURL = nil
        currentHeaders = nil
        currentItemLink = nil
        lines = []
        status = .idle
        failureReason = nil
    }
}
