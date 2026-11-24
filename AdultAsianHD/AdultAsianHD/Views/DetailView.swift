// DetailView.swift — 详情页（v2 重建）
// 顶部 16:9 小窗口内嵌自定义播放器（CustomPlayerView：AVPlayerLayer + 自绘底条，
// 不用 AVPlayerViewController，所以不触发系统 Now Playing，灵动岛干干净净），不弹全屏；
// 点封面进来 onAppear 即调 PlayerViewModel.play(item, host) 自动起播，从 0:00 开始，
// 不自动续播（新 AVPlayerItem 本来就从 0:00 起）。currentURL 变化由 CustomPlayerView
// 的 controller 换 item：新片/新一集从 0:00 起，同片切线保当前进度；
// 就绪后再 play（自动播可靠的触发点），卡住 2 秒再补一次 play()。
// 播放/暂停按钮在播放器底条里，状态由 timeControlStatus 驱动（真正在出帧才显示“暂停”），
// 不再用本地 isPlaying 旗子猜（那正是旧版状态对不上的根）。
// “正在解析播放线路…”只在 status == .loading 时显示，controller
// 真监听到出帧（timeControlStatus == .playing）才调 markPlaying() 让它消失，
// 不再等后台 loadResource。离开页面 onDisappear 停播（pause + replaceCurrentItem(nil)
// + playerVM.stop()，迟到的备线也被 generation 拦住）。
// 失败时红字显示 failureReason。下载：m3u8 走 downloadHLS，mp4 走 downloadMP4。

import AVFoundation
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
        // 等缓冲再播（true）：四家 AI 一致纠正，false 会让播放器一有首帧就播、
        // 首片播完必卡；true 让 AVPlayer 按实测速度管起播缓冲。配合
        // CustomPlayerView 的 10 秒前向缓冲 + 起播码率封顶。
        // 不走 AirPlay（用户不要），也不触发 Now Playing（自定义播放器只用 AVPlayerLayer）。
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        return player
    }()
    @State private var downloadAlertMessage: String?
    @State private var showDownloadAlert = false
    /// 全屏是不是开着（CustomPlayerView 从 controller 同步上来）：
    /// 全屏进出会触发 onDisappear/onAppear，靠它区分“去全屏”还是“真离开”。
    @State private var isFullscreen = false
    /// 本次进详情页是否已起播过：起播只做一次（首进），从全屏回来不重播、不从头。
    @State private var hasStartedPlayback = false
    /// 分集详情（loadDetail 返回；没有 loadDetail 的模块为 nil，不显示分集区）。
    @State private var detail: DetailItem?
    /// 正在播的分集 id（点播时记下来，勾选标记用）。
    @State private var currentEpisodeId: String?
    /// 分集现铸失败时显示的红字。
    @State private var episodeError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 播放器：嵌入页 fallback 时显示 WebView 播放器（同一套自定义底条），
                // 否则显示直链自定义播放器（AVPlayerLayer + 自绘底条）。
                if let webViewURL = playerVM.webViewURL {
                    WebViewPlayerView(url: webViewURL, onClose: { playerVM.closeWebView() })
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    CustomPlayerView(player: player, url: playerVM.currentURL, headers: playerVM.currentHeaders, viewModel: playerVM, isFullscreen: $isFullscreen)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if case .failed(let reason) = playerVM.status {
                    Text(reason)
                        .foregroundColor(.red)
                        .font(.subheadline)
                } else if let failureReason = playerVM.failureReason {
                    Text(failureReason)
                        .foregroundColor(.red)
                        .font(.subheadline)
                } else if playerVM.isResolvingEmbed {
                    Text("正在解析嵌入播放…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
                                    if playerVM.currentURL?.absoluteString == line.url
                                        || playerVM.webViewURL?.absoluteString == line.url {
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
                                        || playerVM.currentURL?.absoluteString == ep.videoURL
                                        || playerVM.webViewURL?.absoluteString == ep.videoURL {
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

                // 相关视频：朋友桥的 loadDetail 给分类返回的 relatedItems，
                // 以前解析时直接丢了，现在接住显示（点开进新详情页）。
                if let detail, !detail.relatedItems.isEmpty {
                    Text("相关")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(detail.relatedItems) { rel in
                            NavigationLink {
                                DetailView(item: rel, host: host, sourceId: sourceId)
                            } label: {
                                VideoCard(item: rel, sourceId: sourceId)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 起播只做一次（首进）：全屏进出也会触发 onAppear，回来不重播、不从头。
            // 分集加载不受影响（每次出现都取，幂等）。
            if !hasStartedPlayback {
                hasStartedPlayback = true
                Task {
                    await playerVM.play(item: item, host: host)
                }
            }
            Task {
                // 分集：模块有 loadDetail 就取详情（短剧站）；没有就当没有分集，不报错。
                if let d = try? await host.loadDetail(link: item.link) {
                    detail = d
                }
            }
        }
        .onChange(of: playerVM.isResolvingEmbed) { _, resolving in
            // 开始解嵌入页时，停掉正在播的直链（不然旧的直链会继续出声）。
            // 只 pause，不改 controller 的 shouldPlay：解出直链后新 URL 到达会自动播起来。
            if resolving { player.pause() }
        }
        .onChange(of: playerVM.webViewURL) { _, webURL in
            // 切到页内 WebView 播时，同样停掉直链播放器。
            if webURL != nil { player.pause() }
        }
        .onDisappear {
            // 全屏时不拆播放器：全屏模态盖上来也会触发 onDisappear，
            // 只是去全屏、没离开详情页，回来要接着播；真离开（isFullscreen=false）才停播。
            guard !isFullscreen else { return }
            player.pause()
            player.replaceCurrentItem(with: nil)
            playerVM.stop()
        }
        .alert("下载", isPresented: $showDownloadAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(downloadAlertMessage ?? "")
        }
    }

    // MARK: - 按钮行：收藏 / 下载
    // 播放/暂停在播放器底条里（状态由 timeControlStatus 驱动），这里不再另设一个
    // （旧版这里的 isPlaying 是本地旗子，和真实播放状态对不上，正是状态 bug 的根）。

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
