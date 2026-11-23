import Foundation

/// 播放快路径：番号 → memojav 静态播单直拼，不抓帖页、不验播单。
/// 点封面的一瞬间就能拼出播单 URL，直接交给 AVPlayer。
enum PlaybackEngine {

    private static let codeRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b([A-Za-z]{2,6}-\\d{2,5})\\b")
    }()

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
@MainActor
final class PlayerViewModel: ObservableObject {

    @Published var lines: [PlayLine] = []
    @Published var currentURL: URL?
    @Published var status: PlayerStatus = .idle
    @Published var failureReason: String?

    /// 已经失败过的线路 URL（切线时跳过，不来回横跳）
    private var failedURLs: Set<String> = []
    /// 每次 play 换一个 generation，旧的后台备线任务回来发现对不上就丢弃，
    /// 防止切到别的片后旧备线写回 lines。
    private var playGeneration = UUID()

    /// 点封面即播：快路径立刻设 currentURL，后台拿备线。
    func play(item: VideoItem, host: WidgetHost) async {
        let generation = UUID()
        playGeneration = generation
        failedURLs = []
        lines = []
        failureReason = nil
        status = .loading

        // 快路径：标题抠番号，直拼播单，立刻交给播放器
        if let fastURL = PlaybackEngine.fastPathURL(for: item) {
            currentURL = fastURL
            lines = [PlayLine(name: "快速线", url: fastURL.absoluteString, description: "番号直拼，秒播")]
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
                    if let first = merged.first, let url = URL(string: first.url) {
                        self.currentURL = url
                        self.status = .loading
                    } else {
                        self.status = .failed("没有可用的播放线路")
                        self.failureReason = "这个视频没有可用的播放线路"
                    }
                    return
                }
                // 快路径已经失败过了、备线刚到：有没试过的备线就立刻续上
                if self.status == .failed,
                   let next = merged.first(where: { !self.failedURLs.contains($0.url) }),
                   let url = URL(string: next.url) {
                    self.currentURL = url
                    self.status = .loading
                    self.failureReason = nil
                }
            }
        }
    }

    /// 点线路切线（在小窗口里切，不重建播放器，由 Views 层换 AVPlayerItem）。
    func switchLine(_ line: PlayLine) {
        guard let url = URL(string: line.url) else { return }
        currentURL = url
        status = .loading
        failureReason = nil
    }

    /// 播放器报错时调（Views 层监听 AVPlayerItemFailedToPlayToEndTime 等）。
    /// 先试下一条没失败过的线，都失败才报 failed。
    func markFailed(_ reason: String) {
        if let current = currentURL?.absoluteString {
            failedURLs.insert(current)
        }
        if let next = lines.first(where: { !failedURLs.contains($0.url) }),
           let url = URL(string: next.url) {
            currentURL = url
            status = .loading
            failureReason = nil
            return
        }
        failureReason = reason
        status = .failed(reason)
    }

    /// 播放器出首帧后调（Views 层监听 AVPlayerItem status / 开始播放）。
    func markPlaying() {
        if status != .failed {
            status = .playing
        }
    }

    /// 离开详情页即停播：清 URL 与线路，旧的后台备线任务回来也会被 generation 拦住。
    func stop() {
        playGeneration = UUID()
        currentURL = nil
        lines = []
        status = .idle
        failureReason = nil
    }
}
