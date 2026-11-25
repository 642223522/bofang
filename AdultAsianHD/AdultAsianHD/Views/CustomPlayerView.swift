import AVFoundation
import Combine
import SwiftUI
import UIKit

// MARK: - 播放层（AVPlayerLayer，不用 AVPlayerViewController）

/// AVPlayerLayer 的 UIView 封装：只负责出画面，不带任何系统控制条。
/// 不用 AVPlayerViewController，就不会触发系统的 Now Playing，
/// 灵动岛 / 控制中心不会再挂“正在播放”媒体卡。
/// 也不设 MPNowPlayingInfoCenter、不用 Live Activities、不激活 playback 音频会话。
final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

// MARK: - 自定义播放器控制器

/// 直链自定义播放器的状态机（ObservableObject，@MainActor）。
/// 只管 AVPlayer 本身：换项、自动播、播放/暂停、快进、画质、缓冲、失败上报、全屏与控制条显隐。
/// 线路、验线竞速、markPlaying/markFailed 仍走 PlayerViewModel（Playback.swift），这里不重写。
@MainActor
final class CustomPlayerController: ObservableObject {
    let player: AVPlayer
    let viewModel: PlayerViewModel

    /// 真实播放状态：timeControlStatus == .playing 才为 true（按钮据此显示暂停/播放）。
    @Published var isPlaying = false
    /// 当前播放秒数（拖进度条时由周期观察暂停更新，拖动位置由滑块本地显示）。
    @Published var currentTime: Double = 0
    /// 总时长秒数（未知为 0）。
    @Published var duration: Double = 0
    /// 已缓冲到的秒数（进度条浅灰段）。
    @Published var bufferedEnd: Double = 0
    /// 正在等数据/缓冲（画面中央转圈）。
    @Published var isLoading = false
    /// 控制条是否可见（播时 3 秒无操作自动藏，暂停时常显，点画面切换）。
    @Published var controlsVisible = true
    /// 是否在全屏呈现里（按钮图标据此切全屏/退出全屏）。
    @Published var isFullscreen = false
    /// 画质选项（从 viewModel.lines 推导）与当前档位。
    @Published var qualityOptions: [QualityOption] = []
    @Published var currentQualityLabel: String = "自动"

    /// 用户意图：true=想播（自动播/点播放），false=点了暂停。
    /// 新 URL 时重置为 true；只有用户点暂停才变 false。
    /// 就绪回调与卡住兜底只认它，不会盖掉用户刚点的暂停。
    private var shouldPlay = true
    private var lastURL: URL?
    private var lastHeaders: [String: String]?
    /// 上次见到的引擎（viewModel.currentEngine）：变了=同一 URL 换了播放路径
    /// （裸连→拦截器，或拦截器→HLS.js 回退再回来），要重建 item、清掉失败标记。
    private var lastEngine: PlayerEngine?
    /// 当前 item 在用的拦截器（强持有，item 活着它就活着；换项/拆项时释放）。
    /// ViewModel 的 resourceLoader 只管“当前线路该用哪个”，这里管“当前 item 在用哪个”。
    private var activeResourceLoader: HLSResourceLoader?
    /// 上次见到的播放会话代际（PlayerViewModel.playGeneration）：
    /// 变了=新片/新一集（从 0:00 起），没变=同片切线（保当前进度）。
    private var lastGeneration: UUID?
    /// 切线时要恢复的进度（同 generation 才有值）。
    private var pendingResumeAt: CMTime?
    private var didMarkPlayingURL: URL?
    private var didMarkFailedURL: URL?
    private var currentItem: AVPlayerItem?
    /// 拖进度条前是不是在播（松手后据此恢复）。
    private var wasPlayingBeforeScrub = false

    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var hideTask: Task<Void, Never>?
    private var stallKickTask: Task<Void, Never>?
    /// 起播码率封顶的放开计时：播稳 12 秒后把 preferredPeakBitRate/720p 封顶撤掉。
    /// 四家 AI 一致：起播先封顶（800Kbps + 720p）防 4G 下一上来就抢高码率变体饿死，
    /// 播稳后再放开吃满画质。每个新 item 重新封顶、重新计时。
    private var capLiftTask: Task<Void, Never>?
    private var capsLifted = false
    /// accessLog 采样计数（周期回调 0.25 秒一次，每 8 次≈2 秒采一次，
    /// 只记数、不动播放；DEBUG 下打印，供定位“到底是带宽还是首字节延迟”）。
    private var accessLogSampleCount = 0
    private var cancellables = Set<AnyCancellable>()

    init(player: AVPlayer, viewModel: PlayerViewModel) {
        self.player = player
        self.viewModel = viewModel
        // 不出灵动岛：不走 AirPlay（用户不要）。
        player.allowsExternalPlayback = false
        // 等缓冲再播（true，默认值）：四家 AI 一致纠正——设 false 会让播放器
        // 一有首帧就立即播，首片播完、下一片还没拉到就必卡（8 秒停就是这么来的）；
        // true 让 AVPlayer 按实测下载速度动态管起播缓冲阈值，起播稍慢一点、
        // 播起来不断。配合同一文件里 replaceItem 的 10 秒前向缓冲 + 起播码率封顶。
        // （首帧速度若真机回退明显，可再 A/B 测 false——ChatGPT 的保留意见。）
        player.automaticallyWaitsToMinimizeStalling = true
        setupPlayerObservations()
        // 线路表是后台慢慢补的（loadResource），变了就重算画质选项。
        viewModel.$lines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshQualityOptions() }
            .store(in: &cancellables)
        // 引擎监听：currentEngine 一变就跟进。
        // 变成非原生引擎（hlsjs/dash/软解/webView）→ 对应播放器接手，拆掉 AVPlayerItem；
        // 回到原生引擎 → 按当前 URL/头重建（同一 URL 换引擎时 onChange(of: url) 不触发，
        // 全靠这里重建，如裸连失败升级拦截器）。
        // .receive(on:) 让回调异步跑：setCurrent 里先建拦截器、再设 URL、最后设引擎，
        // 回调跑到时拦截器与新 URL 都已就位。
        viewModel.$currentEngine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.load(url: self.viewModel.currentURL, headers: self.viewModel.currentHeaders)
                }
            }
            .store(in: &cancellables)
        refreshQualityOptions()
    }

    deinit {
        timeControlObservation?.invalidate()
        itemStatusObservation?.invalidate()
        loadedRangesObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        hideTask?.cancel()
        stallKickTask?.cancel()
        capLiftTask?.cancel()
    }

    // MARK: - 换项与自动播

    /// 新 URL 到达时调（DetailView 传进来的 currentURL/headers 变化）。
    /// URL/请求头/引擎没变不重建，避免 SwiftUI 刷新打断正在播的 play()。
    /// 非原生引擎（hlsjs/dash/软解/webView）不归 AVPlayer：拆掉当前 item，
    /// 由视图层按 currentEngine 显示对应播放器。
    func load(url: URL?, headers: [String: String]?) {
        let engine = viewModel.currentEngine
        guard engine == .native || engine == .nativeIntercepted else {
            unloadCurrentItem()
            return
        }
        guard let url else {
            lastURL = nil
            lastHeaders = nil
            lastEngine = engine
            replaceItem(nil, headers: nil, resumeAt: nil)
            return
        }
        let engineChanged = lastEngine != engine
        guard lastURL != url || lastHeaders != headers || engineChanged else { return }
        if engineChanged {
            // 同一 URL 换引擎：失败只认一次的标记要清掉，
            // 否则同一 URL 换路径后的第二次失败报不上去（markFailed 会认成重复）。
            didMarkPlayingURL = nil
            didMarkFailedURL = nil
        }
        // 新片/新一集（generation 变了）从 0:00 起；同片切线保当前进度。
        let generation = viewModel.playGeneration
        let isNewSession = generation != lastGeneration
        lastGeneration = generation
        var resumeAt: CMTime? = nil
        if !isNewSession, let item = player.currentItem, item.status == .readyToPlay {
            let t = player.currentTime()
            if t.seconds.isFinite && t.seconds > 1 {
                resumeAt = t
            }
        }
        shouldPlay = true
        lastURL = url
        lastHeaders = headers
        lastEngine = engine
        refreshQualityOptions()
        let loader = engine == .nativeIntercepted ? viewModel.resourceLoader : nil
        replaceItem(url, headers: headers, resumeAt: resumeAt, resourceLoader: loader)
    }

    /// 拆掉当前 AVPlayerItem（引擎切走时调）：清掉 URL/头/引擎记忆，
    /// 下次回到原生引擎、同一 URL 也会重建，不会被 load() 的去重 guard 拦住。
    func unloadCurrentItem() {
        lastURL = nil
        lastHeaders = nil
        lastEngine = nil
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        shouldPlay = false
        replaceItem(nil, headers: nil, resumeAt: nil)
    }

    /// 换播项：带请求头的 AVURLAsset（nmcorp 签名 MP4 用）或普通 item；
    /// 小 forward buffer + 不等待攒缓冲，首帧越快越好。
    /// resourceLoader 非 nil 时（拦截线路）：URL 的 scheme 换成 hlsloader:// 建 asset
    /// 并挂 delegate，播单/密钥走拦截器代发（分片 AVPlayer 直接拉，拦截器管不到）；nil 时走现有逻辑，
    /// pornjav 的 native 线完全不受影响。拦截器接手后 headers 参数不再经
    /// AVURLAssetHTTPHeaderFieldsKey 传（只作用于建 asset 那一次调用，管不到子请求），
    /// 头由拦截器给每个子请求带。
    private func replaceItem(_ url: URL?, headers: [String: String]?, resumeAt: CMTime?, resourceLoader: HLSResourceLoader? = nil) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        loadedRangesObservation?.invalidate()
        loadedRangesObservation = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        stallKickTask?.cancel()
        stallKickTask = nil
        capLiftTask?.cancel()
        capLiftTask = nil
        capsLifted = false
        accessLogSampleCount = 0
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        pendingResumeAt = resumeAt
        isLoading = url != nil
        guard let url else {
            currentItem = nil
            activeResourceLoader = nil
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            currentTime = 0
            duration = 0
            bufferedEnd = 0
            return
        }
        let item: AVPlayerItem
        if let resourceLoader {
            // 拦截线路：scheme 换成 hlsloader://，delegate 接管播单/密钥请求。
            // asset 只认这个自定义 scheme 的 URL；currentURL 本身仍保持 https 原地址。
            // UA 走公开 API（AVURLAssetHTTPUserAgentKey，等值字面量——该常量在
            // Xcode 27.2 / iOS 27 SDK 的 Swift 接口里不可见，见下 headers 分支同款处理）：
            // 分片是 AVPlayer 直接拉的，UA 必须在 asset 层换，拦截器管不到分片。
            let loaderURL = HLSResourceLoader.loaderURL(for: url)
            let asset = AVURLAsset(url: loaderURL, options: ["AVURLAssetHTTPUserAgentKey": PlaybackEngine.iPhoneUserAgent])
            asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.delegateQueue)
            activeResourceLoader = resourceLoader
            item = AVPlayerItem(asset: asset)
        } else if let headers {
            // AVURLAssetHTTPHeaderFieldsKey 在 Xcode 27.2 / iOS 27 SDK 的 Swift 接口里不可见，
            // 改用等值字面量（该常量的字符串值就是它自己的名字，运行时等价）。
            // UA 同样走公开 API AVURLAssetHTTPUserAgentKey（等值字面量），不要只塞进
            // header 字典——header 只作用于建 asset 那一次调用，UA 键才管 asset 全程请求。
            let userAgent = headers["User-Agent"] ?? PlaybackEngine.iPhoneUserAgent
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": headers,
                "AVURLAssetHTTPUserAgentKey": userAgent,
            ])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        // 前向缓冲 10 秒（约 2~3 个分片）：memojav 分片 4~8 秒、码率约 2.1Mbps，
        // 4G 下拉一个分片要几秒；只留 2 秒缓冲的话，播到第一片末尾（8.34 秒）
        // 才开始拉下一片、根本来不及，必定在 8 秒处饿死。10 秒让播放器一边播
        // 一边提前拉 2~3 片，4G 下也有余量；起播缓冲阈值由
        // automaticallyWaitsToMinimizeStalling=true 交给 AVPlayer 按实测速度管。
        item.preferredForwardBufferDuration = 10
        // 起播码率封顶（四家 AI 一致）：先 800Kbps + 720p 起播，防 4G 下一上来
        // 就抢最高码率变体、首片没播完就饿死；播稳 12 秒后放开（见 capLiftTask）。
        // 蜂窝单独封顶（preferredPeakBitRateForExpensiveNetworks），WiFi 走通用封顶。
        item.preferredPeakBitRate = 800_000
        item.preferredPeakBitRateForExpensiveNetworks = 800_000
        item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        // 有合规变体就先播，不等最高码率变体就绪（首帧快一步）。
        item.startsOnFirstEligibleVariant = true
        // 预热：详情页打开、item 一建好就先 load isPlayable（不阻塞起播，
        // 只是让 asset 提前走完 TLS/重定向/签名校验，首个 play() 少等首字节）。
        Task { _ = try? await item.asset.load(.isPlayable) }
        currentItem = item
        // 就绪后 play：自动播真正可靠的触发点。旧播放器只在 replace 后调一次 play()，
        // item 还没就绪时那次 play() 会丢，时间就停在 0:00:00 不走——这里就绪后再补一次。
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in self?.handleItemStatus(item) }
        }
        loadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.updateBuffered(item) }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleItemFailure(note.object as? AVPlayerItem) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidPlayToEnd() }
        }
        player.replaceCurrentItem(with: item)
        // 先调一次 play()（rate=1），再靠就绪回调补一次——双保险。
        player.play()
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard item === currentItem else { return }
        switch item.status {
        case .readyToPlay:
            updateDuration(item)
            updateBuffered(item)
            // 切线恢复进度：先 seek 到原进度，再 play；新片（resumeAt=nil）直接 play。
            if let resumeAt = pendingResumeAt {
                pendingResumeAt = nil
                if resumeAt.seconds > 1 {
                    player.seek(to: resumeAt, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.shouldPlay else { return }
                            self.player.play()
                        }
                    }
                } else if shouldPlay {
                    player.play()
                }
            } else if shouldPlay {
                player.play()
            }
        case .failed:
            handleItemFailure(item)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    // MARK: - 播放状态监听

    private func setupPlayerObservations() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in self?.handleTimeControlStatus(player) }
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in self?.handlePeriodicTime(time) }
        }
    }

    private func handleTimeControlStatus(_ player: AVPlayer) {
        switch player.timeControlStatus {
        case .playing:
            isPlaying = true
            isLoading = false
            stallKickTask?.cancel()
            // 真正出帧 → markPlaying（“正在解析播放线路…”由此消失）。
            if let url = lastURL, didMarkPlayingURL != url {
                didMarkPlayingURL = url
                viewModel.markPlaying()
            }
            showControlsTemporarily()
            // 播稳了就开始计 12 秒，满了放开起播码率封顶。
            scheduleCapLift()
        case .paused:
            isPlaying = false
            stallKickTask?.cancel()
            capLiftTask?.cancel()
            // 暂停时控制条常显，不自动藏。
            controlsVisible = true
        case .waitingToPlayAtSpecifiedRate:
            // 等数据/缓冲：不算在播（按钮显示“播放”），画面转圈。
            isPlaying = false
            isLoading = true
            // 等缓冲不算播稳：放开计时取消，播起来再重计。
            capLiftTask?.cancel()
            scheduleStallKick()
            scheduleStallKick()
        @unknown default:
            break
        }
    }

    /// 卡住兜底：等数据超过 2 秒还没播起来、且用户还想播，再补一次 play()。
    /// 只认 shouldPlay，不会盖掉用户刚点的暂停。
    private func scheduleStallKick() {
        stallKickTask?.cancel()
        guard shouldPlay, let item = currentItem, item.status == .readyToPlay else { return }
        stallKickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.shouldPlay,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  self.player.currentItem === self.currentItem else { return }
            self.player.play()
        }
    }

    /// 起播码率封顶的放开：连续播满 12 秒才放开（800Kbps + 720p → 不限），
    /// 中间一旦暂停/等缓冲就取消重计；每个新 item 重新封顶、重新计时。
    /// 放开只是撤掉“起播求稳”的上限，画质仍由 AVPlayer 按带宽自适应。
    private func scheduleCapLift() {
        guard !capsLifted, currentItem != nil else { return }
        capLiftTask?.cancel()
        capLiftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.player.timeControlStatus == .playing,
                  let item = self.currentItem, item.status == .readyToPlay else { return }
            item.preferredPeakBitRate = 0
            item.preferredPeakBitRateForExpensiveNetworks = 0
            item.preferredMaximumResolution = .zero
            self.capsLifted = true
        }
    }

    /// accessLog 采样（DEBUG 日志用）：卡顿到底是带宽不够还是首字节延迟，
    /// 看 observedBitrate（实测带宽）和 numberOfStalls（卡顿次数）才知道，
    /// 不能只凭感觉加缓冲。采样本身不影响播放。
    /// errorLog 也被动采（PlaybackPreflight 的一部分）：只在有错误事件时打印，
    /// 供定位播单/key/分片是哪一层先死。
    private func sampleAccessLog(_ item: AVPlayerItem) {
        guard let event = item.accessLog()?.events.last else { return }
        #if DEBUG
        print("[HLS] observedBitrate=\(Int(event.observedBitrate)) indicatedBitrate=\(Int(event.indicatedBitrate)) stalls=\(event.numberOfStalls) uri=\(event.uri ?? "")")
        if let errorEvent = item.errorLog()?.events.last, errorEvent.errorStatusCode != 0 {
            print("[HLS] errorLog domain=\(errorEvent.errorDomain ?? "") code=\(errorEvent.errorStatusCode) comment=\(errorEvent.errorComment ?? "")")
        }
        #endif
    }

    private func handlePeriodicTime(_ time: CMTime) {
        currentTime = time.seconds
        if let item = currentItem {
            updateDuration(item)
            updateBuffered(item)
            // 兜底：item 万一进了 failed、KVO/通知又没抓到（回调丢了），
            // 这里每 0.25 秒扫一次也能发现，立刻走失败切线；handleItemFailure
            // 自带“同一 URL 只认一次” guard，重复调无害。
            if item.status == .failed {
                handleItemFailure(item)
            }
            // 每 2 秒采一次 accessLog（8 次 × 0.25 秒）。
            accessLogSampleCount += 1
            if accessLogSampleCount >= 8 {
                accessLogSampleCount = 0
                sampleAccessLog(item)
            }
        }
    }

    private func updateDuration(_ item: AVPlayerItem) {
        let d = item.duration.seconds
        if d.isFinite && d > 0 { duration = d }
    }

    private func updateBuffered(_ item: AVPlayerItem) {
        guard let range = item.loadedTimeRanges.first?.timeRangeValue else { return }
        let end = CMTimeAdd(range.start, range.duration).seconds
        if end.isFinite { bufferedEnd = max(bufferedEnd, end) }
    }

    /// 播失败只认一次（同一条 URL）：KVO .failed 和失败通知可能先后都到，
    /// 重复报会把刚切上的下一条线也误标失败。走 viewModel.markFailed() 自动切下一条线。
    /// -12881 检测（分片需头信号）：拦截器只拦播单+key，分片是 AVPlayer 直接拉的；
    /// 分片要头时这里报 -12881，记 LoopbackProxy.segmentNeedsHeaders（回环代理触发条件），
    /// 并以 .segmentFetch 分层报给 markFailed，由它回退 hls.js。
    private func handleItemFailure(_ item: AVPlayerItem?) {
        guard let url = lastURL, didMarkFailedURL != url else { return }
        didMarkFailedURL = url
        // FairPlay（skd://）：拦截器已在播单里见到，报明确错误，不走通用失败文案。
        if viewModel.resourceLoader?.encounteredFairPlay == true {
            viewModel.markFailed("这条线路用了 FairPlay 加密（skd://），当前播放器不支持，请换一条线路")
            return
        }
        let nsError = item?.error as NSError?
        if nsError?.code == -12881 {
            LoopbackProxy.segmentNeedsHeaders = true
            viewModel.markFailed("分片拉取失败（分片可能需要请求头，拦截器覆盖不了）", stage: .segmentFetch)
            return
        }
        let detail = item?.error?.localizedDescription ?? "未知错误"
        viewModel.markFailed("这条线路播放失败（\(detail)）")
    }

    /// 播到片尾：停在 0:00（不循环、不续播），控制条常显，等用户再点播放。
    private func handleDidPlayToEnd() {
        isPlaying = false
        controlsVisible = true
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.currentTime = 0 }
        }
    }

    // MARK: - 播放 / 暂停 / 快进

    func togglePlayPause() {
        if isPlaying {
            pauseByUser()
        } else {
            playByUser()
        }
    }

    func pauseByUser() {
        shouldPlay = false
        player.pause()
        controlsVisible = true
    }

    func playByUser() {
        shouldPlay = true
        player.play()
        showControlsTemporarily()
    }

    /// 开始拖进度条：记下拖之前用户是不是想播，拖动期间先停播（seek 干净不卡）。
    /// 用 shouldPlay（用户意图）记，不用 isPlaying（瞬时 timeControlStatus）：
    /// 播着的片在等缓冲时会短暂进 .waitingToPlayAtSpecifiedRate，isPlaying=false，
    /// 用它记就会把“在播”记成“暂停”，松手不续播；shouldPlay 只有用户点暂停才变 false。
    func beginScrub() {
        wasPlayingBeforeScrub = shouldPlay
        player.pause()
    }

    /// 拖动中：实时 seek（AVPlayer 会合并连续 seek），进度条跟手。
    func scrub(to seconds: Double) {
        guard let item = currentItem, item.status == .readyToPlay, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 松手：精确定位到拖到的位置；拖之前在播就恢复播放（不拖完停在暂停态）。
    func endScrub(to seconds: Double) {
        guard let item = currentItem, item.status == .readyToPlay, duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        let resume = wasPlayingBeforeScrub
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = clamped
                if resume {
                    self.shouldPlay = true
                    self.player.play()
                }
            }
        }
        // 兜底：seek 回调万一丢了（被后一次 seek 顶掉、手势异常结束），
        // 也不要一直停在暂停态——先直接补一次 play()，回调里再补一次也无害。
        if resume {
            shouldPlay = true
            player.play()
        }
    }

    // MARK: - 画质

    func refreshQualityOptions() {
        let lines = viewModel.lines
        var seen = Set<String>()
        var options: [QualityOption] = []
        for line in lines {
            let label = qualityLabel(for: line)
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            options.append(QualityOption(id: line.url, label: label, line: line))
        }
        qualityOptions = options
        if let current = viewModel.currentURL?.absoluteString,
           let line = lines.first(where: { $0.url == current }) {
            currentQualityLabel = qualityLabel(for: line)
        } else if let first = options.first {
            currentQualityLabel = first.label
        } else {
            currentQualityLabel = "自动"
        }
    }

    /// 切画质=切线路（同片同 generation，load 时保当前进度，不回 0:00）。
    func switchQuality(to option: QualityOption) {
        viewModel.switchLine(option.line)
        showControlsTemporarily()
    }

    // MARK: - 控制条显隐与全屏

    /// 播时显示控制条，3 秒无操作自动藏；暂停时常显。
    func showControlsTemporarily() {
        controlsVisible = true
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isPlaying { self.controlsVisible = false }
        }
    }

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { showControlsTemporarily() }
    }

    func enterFullscreen() {
        isFullscreen = true
    }
}

// MARK: - 直链自定义播放器（16:9 内嵌）

/// 直链自定义播放器：AVPlayerLayer 出画面 + 自绘底条。
/// 16:9 内嵌在详情页顶部小窗口，不弹全屏；全屏靠底条上的全屏按钮（横屏呈现，退出回原位）。
struct CustomPlayerView: View {
    let player: AVPlayer
    let url: URL?
    let headers: [String: String]?
    let viewModel: PlayerViewModel
    /// 全屏状态上行到 DetailView：详情页靠它判断 onDisappear 是不是全屏引起的，
    /// 全屏时不拆播放器、不停播；退出全屏回来接着播。
    @Binding var isFullscreen: Bool

    @StateObject private var controller: CustomPlayerController

    init(player: AVPlayer, url: URL?, headers: [String: String]?, viewModel: PlayerViewModel, isFullscreen: Binding<Bool>) {
        self.player = player
        self.url = url
        self.headers = headers
        self.viewModel = viewModel
        _isFullscreen = isFullscreen
        _controller = StateObject(wrappedValue: CustomPlayerController(player: player, viewModel: viewModel))
    }

    var body: some View {
        ZStack {
            PlayerLayerView(player: player)
                .onTapGesture { controller.toggleControls() }
            if controller.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }
            VStack {
                Spacer()
                if controller.controlsVisible {
                    PlayerControlBar(
                        isPlaying: controller.isPlaying,
                        isBuffering: controller.isLoading,
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        bufferedEnd: controller.bufferedEnd,
                        showsProgress: true,
                        qualityLabel: controller.currentQualityLabel,
                        qualityOptions: controller.qualityOptions,
                        onQualitySelected: { controller.switchQuality(to: $0) },
                        isFullscreen: false,
                        onFullscreen: { controller.enterFullscreen() },
                        onClose: nil,
                        statusText: nil,
                        onPlayPause: { controller.togglePlayPause() },
                        onScrubStart: { controller.beginScrub() },
                        onScrub: { controller.scrub(to: $0) },
                        onScrubEnd: { controller.endScrub(to: $0) }
                    )
                }
            }
        }
        .background(Color.black)
        .onAppear { controller.load(url: url, headers: headers) }
        .onChange(of: url) { _, newURL in controller.load(url: newURL, headers: headers) }
        .onChange(of: headers) { _, newHeaders in controller.load(url: url, headers: newHeaders) }
        .onChange(of: controller.isFullscreen) { _, fullscreen in
            // 全屏状态同步给 DetailView（它靠这个判断 onDisappear 是不是全屏引起的）。
            isFullscreen = fullscreen
            if fullscreen {
                FullscreenPlayerPresenter.present(
                    player: player,
                    controller: controller,
                    viewModel: viewModel
                ) {
                    controller.isFullscreen = false
                }
            }
        }
    }
}

// MARK: - 全屏呈现（横屏，同一 AVPlayer、同一 controller）

/// 全屏版播放器内容：同一 AVPlayerLayer、同一 controller、同一套底条，
/// 只是铺满横屏（全屏按钮显示“退出全屏”图标）。
struct FullscreenPlayerContent: View {
    let player: AVPlayer
    @ObservedObject var controller: CustomPlayerController
    let viewModel: PlayerViewModel
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: player)
                .ignoresSafeArea()
                .onTapGesture { controller.toggleControls() }
            if controller.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }
            VStack {
                Spacer()
                if controller.controlsVisible {
                    PlayerControlBar(
                        isPlaying: controller.isPlaying,
                        isBuffering: controller.isLoading,
                        currentTime: controller.currentTime,
                        duration: controller.duration,
                        bufferedEnd: controller.bufferedEnd,
                        showsProgress: true,
                        qualityLabel: controller.currentQualityLabel,
                        qualityOptions: controller.qualityOptions,
                        onQualitySelected: { controller.switchQuality(to: $0) },
                        isFullscreen: true,
                        onFullscreen: { onExit() },
                        onClose: nil,
                        statusText: nil,
                        onPlayPause: { controller.togglePlayPause() },
                        onScrubStart: { controller.beginScrub() },
                        onScrub: { controller.scrub(to: $0) },
                        onScrubEnd: { controller.endScrub(to: $0) }
                    )
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { controller.showControlsTemporarily() }
    }
}

/// 全屏播放控制器：横屏承载全屏版播放器；只能用全屏按钮退出（不手势滑掉），
/// 退出后内嵌播放器还在同一进度（同一 AVPlayer、同一 item）。
final class FullscreenPlayerViewController: UIViewController {
    private let player: AVPlayer
    private let controller: CustomPlayerController
    private let viewModel: PlayerViewModel
    private let onExit: () -> Void

    init(player: AVPlayer, controller: CustomPlayerController, viewModel: PlayerViewModel, onExit: @escaping () -> Void) {
        self.player = player
        self.controller = controller
        self.viewModel = viewModel
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        // overFullScreen（不是 fullScreen）：盖全屏时底下的详情页不从层级里摘掉，
        // DetailView 的 onDisappear/onAppear 不触发，播放器不被拆、不重播。
        // 用 fullScreen 的话，盖上来就触发 onDisappear 拆播放器，退出又触发 onAppear 从头重播。
        modalPresentationStyle = .overFullScreen
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let content = FullscreenPlayerContent(player: player, controller: controller, viewModel: viewModel, onExit: { [weak self] in
            self?.dismiss(animated: true, completion: nil)
            self?.onExit()
        })
        let hosting = UIHostingController(rootView: content)
        hosting.view.backgroundColor = .black
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
    }
}

/// 全屏呈现器：从最顶层控制器 present 横屏全屏播放器。
enum FullscreenPlayerPresenter {
    @MainActor
    static func present(player: AVPlayer, controller: CustomPlayerController, viewModel: PlayerViewModel, onExit: @escaping () -> Void) {
        guard let top = topViewController() else { return }
        if top is FullscreenPlayerViewController { return }
        let vc = FullscreenPlayerViewController(player: player, controller: controller, viewModel: viewModel, onExit: onExit)
        top.present(vc, animated: true, completion: nil)
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var vc = window.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
