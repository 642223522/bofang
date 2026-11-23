// PlayerView.swift — AVPlayerViewController 的 UIViewControllerRepresentable 封装（v2 重建）
// 不自动全屏（entersFullScreenWhenPlaybackBegins = false），系统控制条自带全屏按钮。
// update 时换 item：coordinator 记下上一次的 URL，只有 URL 变了才 replaceCurrentItem
// 并 play，避免每次 SwiftUI 刷新都重建播放项（那正是旧版 AbortError 连锁的诱因之一）。
// 不用 WKWebView 播放器。
// 首帧与失败都由 coordinator 真监听 AVPlayer/AVPlayerItem 汇报给 PlayerViewModel：
// timeControlStatus == .playing / item .readyToPlay 且 rate > 0 → markPlaying()，
// “正在解析播放线路…” 由此消失，不再等后台 loadResource；
// item .failed / AVPlayerItemFailedToPlayToEndTime → markFailed() 自动切下一条线，
// 全部线失败才报 failed，不再黑屏死住。
// 快路径起播不等 loadResource；同一个 AVPlayer 只 replaceCurrentItem，不重建；
// 起播不等攒缓冲（automaticallyWaitsToMinimizeStalling = false，
// preferredForwardBufferDuration = 2 秒），首帧一到就播。
// nmcorp 签名 MP4 用带 Referer + iPhone UA 的 AVURLAsset 建项
// （ViewModel 给 headers；裸 AVPlayerItem(url:) 不带这些头会被 CDN 拒）；
// memojav m3u8 快路径 headers 为 nil，走原来的 AVPlayerItem(url:) 不动它。

import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 当前要播的 URL；nil 表示还没解析出线路。
    let url: URL?
    /// 当前线路要带的 HTTP 请求头（nmcorp 签名 MP4 的 Referer/UA；memojav 快路径为 nil）。
    let headers: [String: String]?
    /// 播放状态机：coordinator 把真实播放/失败事件汇报给它。
    let viewModel: PlayerViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, viewModel: viewModel)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.showsPlaybackControls = true
        // 起播不等攒缓冲：有首帧就播，不等 forward buffer 攒满。
        player.automaticallyWaitsToMinimizeStalling = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        player.automaticallyWaitsToMinimizeStalling = false
        context.coordinator.viewModel = viewModel
        context.coordinator.attachPlayer(player)
        guard let url else { return }
        // 只有 URL 或请求头真的变了才换 item；重复调用不打断正在播的 play()。
        guard context.coordinator.lastURL != url || context.coordinator.lastHeaders != headers else { return }
        context.coordinator.lastURL = url
        context.coordinator.lastHeaders = headers
        context.coordinator.replaceItem(url: url, headers: headers)
    }

    final class Coordinator {
        weak var viewModel: PlayerViewModel?
        private weak var player: AVPlayer?
        var lastURL: URL?
        var lastHeaders: [String: String]?
        private var timeControlObservation: NSKeyValueObservation?
        private var itemObservation: NSKeyValueObservation?
        private var failureObserver: NSObjectProtocol?
        private var didMarkPlayingURL: URL?
        private var didMarkFailedURL: URL?

        init(player: AVPlayer, viewModel: PlayerViewModel) {
            self.viewModel = viewModel
            attachPlayer(player)
        }

        deinit {
            timeControlObservation?.invalidate()
            itemObservation?.invalidate()
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
            }
        }

        /// 只跟同一个 AVPlayer 挂一次 timeControlStatus 监听。
        func attachPlayer(_ player: AVPlayer) {
            guard self.player !== player else { return }
            self.player = player
            timeControlObservation?.invalidate()
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                self?.checkPlaying(player: player)
            }
        }

        /// 真正开始出帧 → 汇报 playing（“正在解析线路…” 由此消失）。
        private func checkPlaying(player: AVPlayer) {
            guard player.timeControlStatus == .playing,
                  let url = lastURL,
                  didMarkPlayingURL != url else { return }
            didMarkPlayingURL = url
            guard let viewModel else { return }
            Task { @MainActor in await viewModel.markPlaying() }
        }

        /// 换播项：带请求头的 AVURLAsset（nmcorp 签名 MP4 用）或普通 item；
        /// 小 forward buffer + 不等待攒缓冲，首帧越快越好。
        func replaceItem(url: URL, headers: [String: String]?) {
            guard let player else { return }
            itemObservation?.invalidate()
            itemObservation = nil
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
                self.failureObserver = nil
            }
            didMarkPlayingURL = nil
            didMarkFailedURL = nil

            let item: AVPlayerItem
            if let headers {
                let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPHeaderFieldsKey: headers])
                item = AVPlayerItem(asset: asset)
            } else {
                item = AVPlayerItem(url: url)
            }
            // 只留约 2 秒前向缓冲：够起播就行，不等攒满才出首帧。
            item.preferredForwardBufferDuration = 2

            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                self?.handleItemStatus(item)
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] note in
                self?.handleItemFailure(note.object as? AVPlayerItem)
            }

            player.replaceCurrentItem(with: item)
            player.play()
        }

        private func handleItemStatus(_ item: AVPlayerItem) {
            switch item.status {
            case .readyToPlay:
                // 已就绪且在出帧就报 playing；刚 replace 时调的 play() 不会丢，
                // 这里不再补 play()，免得盖掉用户刚点的暂停。
                if let player, player.rate > 0 {
                    checkPlaying(player: player)
                }
            case .failed:
                handleItemFailure(item)
            case .unknown:
                break
            @unknown default:
                break
            }
        }

        /// 播失败只认一次（同一条 URL）：KVO .failed 和失败通知可能先后都到，
        /// 重复报会把刚切上的下一条线也误标失败。
        private func handleItemFailure(_ item: AVPlayerItem?) {
            guard let url = lastURL, didMarkFailedURL != url else { return }
            didMarkFailedURL = url
            guard let viewModel else { return }
            let detail = item?.error?.localizedDescription ?? "未知错误"
            Task { @MainActor in await viewModel.markFailed("这条线路播放失败（\(detail)）") }
        }
    }
}
