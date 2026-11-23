// PlayerView.swift — AVPlayerViewController 的 UIViewControllerRepresentable 封装（v2 重建）
// 不自动全屏（entersFullScreenWhenPlaybackBegins = false），系统控制条自带全屏按钮。
// update 时换 item：coordinator 记下上一次的 URL，只有 URL 变了才 replaceCurrentItem
// 并 play，避免每次 SwiftUI 刷新都重建播放项（那正是旧版 AbortError 连锁的诱因之一）。
// 不用 WKWebView 播放器。

import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 当前要播的 URL；nil 表示还没解析出线路。
    let url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        guard let url else { return }
        // 只有 URL 真的变了才换 item；重复调用不打断正在播的 play()。
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    final class Coordinator {
        var lastURL: URL?
    }
}
