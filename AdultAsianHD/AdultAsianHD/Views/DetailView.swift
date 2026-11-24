// DetailView.swift — 详情页（v2 重建）
// 顶部 16:9 小窗口内嵌 AVPlayerViewController（PlayerView），不弹全屏；
// 点封面进来 onAppear 即调 PlayerViewModel.play(item, host) 自动起播，从 0:00 开始，
// 不自动续播（新 AVPlayerItem 本来就从 0:00 起）。currentURL 变化由 PlayerView
// 在 update 时换 item 并 play。播放/暂停、线路切换都直接作用于同一个 AVPlayer。
// “正在解析播放线路…”只在 status == .loading 时显示，PlayerView 的 coordinator
// 真监听到出帧（timeControlStatus == .playing）才调 markPlaying() 让它消失，
// 不再等后台 loadResource。离开页面 onDisappear 停播（pause + replaceCurrentItem(nil)
// + playerVM.stop()，迟到的备线也被 generation 拦住）。
// 失败时红字显示 failureReason。下载：m3u8 走 downloadHLS，mp4 走 downloadMP4。

import AVKit
import SwiftUI

struct DetailView: View {
    let item: VideoItem
    let host: WidgetHost
    let sourceId: String

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var downloader: Downloader

    @StateObject private var playerVM = PlayerViewModel()
    @State private var player: AVPlayer = {
        let player = AVPlayer()
        // 起播不等攒缓冲：有首帧就播，不等 forward buffer 攒满（慢首帧的主因之一）。
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }()
    @State private var isPlaying = false
    @State private var downloadAlertMessage: String?
    @State private var showDownloadAlert = false
    /// 分集详情（loadDetail 返回；没有 loadDetail 的模块为 nil，不显示分集区）。
    @State private var detail: DetailItem?
    /// 正在播的分集 id（点播时记下来，勾选标记用）。
    @State private var currentEpisodeId: String?
    /// 分集现铸失败时显示的红字。
    @State private var episodeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlayerView(player: player, url: playerVM.currentURL, headers: playerVM.currentHeaders, viewModel: playerVM)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if case .failed(let reason) = playerVM.status {
                    Text(reason)
                        .foregroundColor(.red)
                        .font(.subheadline)
                } else if let failureReason = playerVM.failureReason {
                    Text(failureReason)
                        .foregroundColor(.red)
                        .font(.subheadline)
                } else if playerVM.status == .loading {
                    Text("正在解析播放线路…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text(item.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("时长 --:--")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                buttonRow

                if !playerVM.lines.isEmpty {
                    Text("线路")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(playerVM.lines.enumerated()), id: \.offset) { _, line in
                            Button {
                                playerVM.switchLine(line)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.name)
                                            .font(.headline)
                                        if !line.description.isEmpty {
                                            Text(line.description)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if playerVM.currentURL?.absoluteString == line.url {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }

                if let detail, !detail.episodes.isEmpty {
                    Text("分集")
                        .font(.headline)
                    if let episodeError {
                        Text(episodeError)
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                    VStack(spacing: 0) {
                        ForEach(detail.episodes) { ep in
                            Button {
                                playEpisode(ep)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ep.title)
                                            .font(.headline)
                                        if !ep.description.isEmpty {
                                            Text(ep.description)
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if currentEpisodeId == ep.id
                                        || playerVM.currentURL?.absoluteString == ep.videoURL {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                await playerVM.play(item: item, host: host)
            }
            Task {
                // 分集：模块有 loadDetail 就取详情（短剧站）；没有就当没有分集，不报错。
                if let d = try? await host.loadDetail(link: item.link) {
                    detail = d
                }
            }
        }
        .onChange(of: playerVM.currentURL) { _, newURL in
            // 有了可播 URL 即视为正在播（实际换 item + play 由 PlayerView.update 做）。
            isPlaying = newURL != nil
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playerVM.stop()
            isPlaying = false
        }
        .alert("下载", isPresented: $showDownloadAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(downloadAlertMessage ?? "")
        }
    }

    // MARK: - 按钮行：收藏 / 播放-暂停切换 / 下载

    private var buttonRow: some View {
        HStack(spacing: 16) {
            Button {
                favorites.toggle(item: item, sourceId: sourceId)
            } label: {
                Label(
                    favorites.isFavorite(item.id) ? "已收藏" : "收藏",
                    systemImage: favorites.isFavorite(item.id) ? "star.fill" : "star"
                )
            }
            .buttonStyle(.bordered)

            Button {
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(playerVM.currentURL == nil)

            Button {
                downloadCurrent()
            } label: {
                Label("下载", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(playerVM.currentURL == nil && PlaybackEngine.fastPathURL(for: item) == nil)
        }
    }

    // MARK: - 分集点播

    /// 点某集：有预铸直链直接播；没有就用该集 epLink 调 loadResource 现铸再播。
    private func playEpisode(_ ep: DetailEpisode) {
        currentEpisodeId = ep.id
        episodeError = nil
        if let urlString = ep.videoURL, !urlString.isEmpty {
            playerVM.playLine(PlayLine(
                name: ep.title,
                url: urlString,
                description: ep.description,
                playerHint: ep.playerHint
            ))
            return
        }
        Task {
            do {
                let lines = try await host.loadResource(link: ep.link, title: ep.title)
                if let first = lines.first {
                    playerVM.playLine(first)
                } else {
                    episodeError = "这集没有可用的播放线路"
                }
            } catch {
                episodeError = "这集解析失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 下载

    private func downloadCurrent() {
        guard let url = playerVM.currentURL ?? PlaybackEngine.fastPathURL(for: item) else {
            downloadAlertMessage = "没有可下载的直链，这个站不支持下载。"
            showDownloadAlert = true
            return
        }
        Task {
            if url.pathExtension.lowercased() == "m3u8"
                || url.absoluteString.lowercased().contains("m3u8") {
                await downloader.downloadHLS(url, title: item.title)
            } else {
                await downloader.downloadMP4(url, title: item.title)
            }
            downloadAlertMessage = "已加入下载，可在「我的 → 下载」里查看进度。"
            showDownloadAlert = true
        }
    }
}
