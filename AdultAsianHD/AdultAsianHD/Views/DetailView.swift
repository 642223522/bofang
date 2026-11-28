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
    /// 分集现铸的异步任务（run #36 P0-10）：保存下来才能在离页/点别的集时
    /// 取消；不保存的话，点第 2 集后离页，loadResource 返回后会在后台重新起播。
    @State private var episodeTask: Task<Void, Never>?
    /// onAppear 起的起播任务（run #36 R4：与分集任务分开——旧的 appearTasks
    /// 数组把两者混在一起，从全屏返回时 onAppear 取消数组会误取消尚未返回的
    /// playTask；分开后全屏返回只动分集任务，起播任务不受影响）。
    @State private var playTask: Task<Void, Never>?
    /// onAppear 起的分集加载任务（与 playTask 分开，见上）。
    @State private var loadDetailTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 播放器按当前引擎分流（currentEngine 由 PlayerViewModel 的路由表设，
                // 按内容事实 > URL 形态 > hint 定；A 路新增的 @Published 属性）：
                // .hlsjs/.dash 走对应的 HLS.js / DASH 播放器（B 路建，同款 viewModel 契约）；
                // .softDecoder 走软解播放器（C 路 Wave 2 的 SoftDecoderPlayerView：
                // KSPlayer/FFmpeg，同一 16:9 盒子）；.native/.nativeIntercepted/.proxy 走现有直链自定义
                // 播放器（AVPlayerLayer + 自绘底条，一字不动）；.webView 走现有嵌入页
                // 播放器（一字不动）。webViewURL 尚未到达时（路由先行、URL 随后），
                // .webView 分支退回直链播放器，和旧逻辑（webViewURL 为 nil 时显示直链）一致。
                // 直链播放器拿的是 playerURL：代理时为回环地址，否则为线路原地址
                //（代理时 AVPlayer 只能看到回环地址，原始 https 地址只留在 ViewModel 里）。
                switch playerVM.currentEngine {
                case .hlsjs:
                    HLSJSPlayerView(viewModel: playerVM, onFullscreenChange: { isFullscreen = $0 })
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .dash:
                    DASHPlayerView(viewModel: playerVM, onFullscreenChange: { isFullscreen = $0 })
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .softDecoder:
                    SoftDecoderPlayerView(viewModel: playerVM, onFullscreenChange: { isFullscreen = $0 })
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .webView:
                    if let webViewURL = playerVM.webViewURL {
                        WebViewPlayerView(url: webViewURL, onClose: { isFullscreen = false; playerVM.closeWebView() }, onPlaying: { playerVM.markPlaying() }, onEmbedFailed: { playerVM.markEmbedFailed($0) }, onFullscreenChange: { isFullscreen = $0 }, retryNonce: playerVM.embedRetryNonce)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        CustomPlayerView(player: player, url: playerVM.currentURL, headers: playerVM.currentHeaders, viewModel: playerVM, isFullscreen: $isFullscreen)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .native, .nativeIntercepted, .proxy:
                    CustomPlayerView(player: player, url: playerVM.playerURL, headers: playerVM.currentHeaders, viewModel: playerVM, isFullscreen: $isFullscreen)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if case .failed(let reason) = playerVM.status {
                    Text(reason)
                        .foregroundColor(.red)
                        .font(.subheadline)
                    // 嵌入播放失败（探针看门狗终局）：给重试按钮，重新走 playEmbedLine。
                    // 直链失败不显示（直链失败走自动切线，重试按钮只属于嵌页）。
                    if playerVM.webViewURL != nil {
                        Button("重试嵌入播放") {
                            playerVM.retryEmbed()
                        }
                        .buttonStyle(.bordered)
                    }
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
                                // 手动切线先取消在途的分集现铸任务：慢返回的分集
                                // 会调 playLine 覆盖刚切好的线路。
                                episodeTask?.cancel()
                                episodeTask = nil
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
                                    // 勾只给正在播的那集：黄果非首集 videoURL 为 nil（"" 转 nil），
                                    // nil == nil 在 Swift 里是 true，不加守卫会让所有没 URL 的集全勾上。
                                    if currentEpisodeId == ep.id
                                        || (ep.videoURL != nil && playerVM.currentURL?.absoluteString == ep.videoURL)
                                        || (ep.videoURL != nil && playerVM.webViewURL?.absoluteString == ep.videoURL) {
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
            // 起播只做一次（首进）：全屏进出也会触发 onAppear，回来不重播、不从头，
            // 也不取消尚未返回的起播任务（playTask 与分集任务已分开）。
            if !hasStartedPlayback {
                hasStartedPlayback = true
                playTask?.cancel()
                playTask = Task {
                    await playerVM.play(item: item, host: host)
                }
            }
            // 分集只在还没拿到时拉一次：从全屏回来 onAppear 再跑也不重拉；
            // 写回前校验 !Task.isCancelled，迟到的返回不往视图写 detail。
            if detail == nil {
                loadDetailTask?.cancel()
                loadDetailTask = Task {
                    // 分集：模块有 loadDetail 就取详情（短剧站）；没有就当没有分集，不报错。
                    if let d = try? await host.loadDetail(link: item.link) {
                        guard !Task.isCancelled else { return }
                        detail = d
                    }
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
            // 嵌页卸载（webViewURL 变 nil）：全屏一定已不在——probe.stop() 故意
            // 保留 isFullscreen，若恰为 true 又不复位，onDisappear 的
            // guard !isFullscreen 会永久拦住停播。复位条件只认 webURL == nil，
            // 不再加 currentEngine == .webView：closeWebView()/stop() 都是先置
            // webViewURL = nil 再置 currentEngine = .native（同一同步批），
            // onChange 送达时引擎早已是 .native，加了等于永不触发。
            if webURL == nil { isFullscreen = false }
        }
        .onDisappear {
            // 全屏时不拆播放器：全屏模态盖上来也会触发 onDisappear，
            // 只是去全屏、没离开详情页，回来要接着播；真离开（isFullscreen=false）才停播。
            guard !isFullscreen else { return }
            episodeTask?.cancel()
            episodeTask = nil
            playTask?.cancel()
            playTask = nil
            loadDetailTask?.cancel()
            loadDetailTask = nil
            // 重置起播旗：从“相关视频”点返回时 onAppear 会再跑，旗不重置就
            // 永远不重播（离页时播放器已被停掉），只剩黑屏。
            hasStartedPlayback = false
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
                    favorites.isFavorite(itemId: item.id, sourceId: sourceId) ? "已收藏" : "收藏",
                    systemImage: favorites.isFavorite(itemId: item.id, sourceId: sourceId) ? "star.fill" : "star"
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
        // 旧的现铸任务先取消：连点第 2 集再点第 3 集时，慢返回的第 2 集
        // 不能反过来劫持正在播的第 3 集；点第 2 集后离页，onDisappear 也会取消。
        episodeTask?.cancel()
        currentEpisodeId = ep.id
        episodeError = nil
        if let urlString = ep.videoURL, !urlString.isEmpty {
            // 重建 PlayLine 时把分集的字段一并传上，别丢了：以前只传 playerHint，
            // referer/adStrip 被重置（referer 丢了会让需要 Referer 的 CDN 失败，
            // adStrip 丢了会让该剥广告的线不剥）。headers/cookie 是 A 路按共享契约
            // 给 PlayLine / DetailEpisode 补的字段（[String: String]? / String?），
            // 按契约名引用；A 路未落地前这里编译不过，等 A 路字段到位即通，审计核对。
            // 预铸直通分支：把该集 epLink 作 recastLink 传过去（A 路的
            // playLine(_:recastLink:) 签名；只对 hlsjs 签名线现铸才生效，
            // 其他线不受影响）。否则首集可能播预铸的旧签名（C 路 Wave 2）。
            playerVM.playLine(PlayLine(
                name: ep.title,
                url: urlString,
                description: ep.description,
                playerHint: ep.playerHint,
                referer: ep.referer,
                adStrip: ep.adStrip,
                headers: ep.headers,
                cookie: ep.cookie
            ), recastLink: ep.link)
            return
        }
        episodeTask = Task {
            do {
                let lines = try await host.loadResource(link: ep.link, title: ep.title)
                // 迟到返回的校验：任务被取消（离页/点了别的集），或当前分集
                // 已不是这集，一律丢弃，不起播、不报错。
                guard !Task.isCancelled, currentEpisodeId == ep.id else { return }
                if let first = lines.first {
                    // 非预铸分支也要传 recastLink: ep.link（与预铸分支一致）：
                    // 否则第 2 集起遇密钥 403 重铸时无 epLink，会跳回第 1 集。
                    playerVM.playLine(first, recastLink: ep.link)
                } else {
                    episodeError = "这集没有可用的播放线路"
                }
            } catch {
                guard !Task.isCancelled, currentEpisodeId == ep.id else { return }
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
        // 入队即弹窗“已加入下载”：downloadHLS/downloadMP4 是整片下完才返回的，
        // 以前 await 下完才弹，文案与行为对不上（大片要等很久才提示）。
        // 入队那一刻任务记录已进下载列表，提示属实；进度在「我的 → 下载」里看。
        downloadAlertMessage = "已加入下载，可在「我的 → 下载」里查看进度。"
        showDownloadAlert = true
        Task {
            if url.pathExtension.lowercased() == "m3u8"
                || url.absoluteString.lowercased().contains("m3u8") {
                await downloader.downloadHLS(url, title: item.title)
            } else {
                await downloader.downloadMP4(url, title: item.title)
            }
        }
    }
}
