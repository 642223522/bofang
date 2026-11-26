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
    /// 当前是否正在拖动进度条（拖动时不发 AVPlayer.seek，周期时间回调也不回写 currentTime）。
    private var isScrubbing = false
    /// 当前是否有一次精确 seek 在途（完成或取消前不让周期回调把时间跳回旧位置）。
    private var isSeekingInFlight = false
    /// Seek 操作代际号：一次用户操作（松手 seek / 切线恢复 seek）一个号；新操作使旧回调与旧看门狗失效。
    private var seekGeneration: UInt64 = 0
    /// Seek 阶段令牌：同一次操作内的每次尝试（初次/重试/重建后）各一个号；旧尝试的回调与看门狗失效。
    private var seekPhaseToken: UInt64 = 0
    /// 当前 seek 阶段（nil = 不在 seek 恢复流程里）。
    private var seekPhase: SeekPhase?
    /// 当前 seek 的目标时间（看门狗重试/重建时复用）。
    private var seekTarget: CMTime = .zero
    /// 当前 seek 发起时用户是否想播（Stage 1 踢活判断用；最终播不播以 live shouldPlay 为准）。
    private var seekShouldResume = false
    /// Stage 2 重建 item 后待执行的 seek 尝试次数（非 nil = 正在做 seek 卡死恢复，不是新片）。
    private var pendingSeekRecoveryAttempt: Int?
    /// 前台才计时的 seek 看门狗（DispatchWorkItem；后台暂停计时，回前台续计剩余时间）。
    private var seekWatchdogWorkItem: DispatchWorkItem?
    /// 看门狗到期时刻（ProcessInfo.systemUptime 计），后台时据此算剩余时间。
    private var seekWatchdogDeadline: TimeInterval?
    /// 看门狗剩余秒数（后台暂停时冻结，start 时重置为 seekTimeoutSeconds）。
    private var seekWatchdogRemaining: TimeInterval = 0
    /// App 是否在前台（seek 看门狗只在前台计时）。
    private var seekAppIsActive = true
    /// 前后台切换监听（seek 看门狗暂停/续计用）。
    private var seekLifecycleObservers: [NSObjectProtocol] = []
    /// 精确 seek 的前台超时（秒）：超过仍未恢复播放即按两阶段重试（重试 → 重建 item）。
    private static let seekTimeoutSeconds: TimeInterval = 10
    /// Stage 1 playImmediately 踢活的观察窗口（秒）：给异步切到 .playing 留时间，
    /// 绝不紧接着同步重 seek 把踢活打断。
    private static let seekKickGraceSeconds: TimeInterval = 2.5
    /// 从后台回前台时的最小宽限秒数：避免刚回前台网络/解码器未苏醒就被 0.1 秒剩余时间误杀。
    private static let foregroundResumeMinGraceSeconds: TimeInterval = 3.0
    /// 精确 seek 的容差（秒）：±1s 让 CoreMedia 落在最近关键帧，不做逐帧精确查找。
    private static let seekToleranceSeconds: Double = 1.0
    /// performExactSeek 的 5 秒兜底：seek 回调 5 秒不回就强制 completeSeek
    ///（CoreMedia 卡住时回调可能永远不来）；completeSeek 里取消它。
    private var seekCompleteFallbackTask: Task<Void, Never>?

    /// Seek 恢复完整阶段：
    /// initialSeek -> (finished) waitingForPlayback(1)
    /// -> (timeout) kickingPlayback（仅已缓冲）-> retrySeek -> waitingForPlayback(2)
    /// -> waitingForReplacement -> rebuiltSeek -> waitingForPlayback(3) -> 终端。
    private enum SeekPhase: Equatable {
        case initialSeek
        case kickingPlayback
        case retrySeek
        case waitingForReplacement
        case rebuiltSeek
        case waitingForPlayback(attempt: Int)
    }

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
        installSeekLifecycleObservers()
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
                    // playerURL：代理时为回环地址，否则为线路原地址。
                    self.load(url: self.viewModel.playerURL, headers: self.viewModel.currentHeaders)
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
        seekCompleteFallbackTask?.cancel()
        seekWatchdogWorkItem?.cancel()
        for observer in seekLifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 换项与自动播

    /// 新 URL 到达时调（DetailView 传进来的 playerURL/headers 变化）。
    /// URL/请求头/引擎没变不重建，避免 SwiftUI 刷新打断正在播的 play()。
    /// 非原生引擎（hlsjs/dash/软解/webView）不归 AVPlayer：拆掉当前 item，
    /// 由视图层按 currentEngine 显示对应播放器。
    /// .proxy 时只认回环地址：监听就绪前 playerURL 还是原始 https 地址，
    /// 此时不建 asset（等 proxyURL 到来再建），免得裸播原地址、把代理绕过去；
    /// 代理时头由代理统一带，不挂到回环 asset 上。
    func load(url: URL?, headers: [String: String]?) {
        let engine = viewModel.currentEngine
        guard engine == .native || engine == .nativeIntercepted || engine == .proxy else {
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
        if engine == .proxy, url.host != "127.0.0.1" {
            return
        }
        // 代理时头由代理统一带（UA/Referer/模块头/Cookie），不挂到回环 asset 上；
        // 回环地址不需要头，挂了反而把身份暴露给 AVPlayer 的日志。
        let effectiveHeaders = engine == .proxy ? nil : headers
        let engineChanged = lastEngine != engine
        guard lastURL != url || lastHeaders != effectiveHeaders || engineChanged else { return }
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
        lastHeaders = effectiveHeaders
        lastEngine = engine
        refreshQualityOptions()
        let loader = engine == .nativeIntercepted ? viewModel.resourceLoader : nil
        replaceItem(url, headers: effectiveHeaders, resumeAt: resumeAt, resourceLoader: loader)
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
    private func replaceItem(_ url: URL?, headers: [String: String]?, resumeAt: CMTime?, resourceLoader: HLSResourceLoader? = nil, preserveSeekRecovery: Bool = false) {
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
        if !preserveSeekRecovery {
            // 新片/切线换项：旧 seek 操作作废（代际号+1 使旧回调与旧看门狗失效），
            // 拖动标志与 Stage 2 恢复标记清掉；Stage 2 重建 item 时跳过这里，
            // 让 pendingSeekRecoveryAttempt 活到新 item 就绪。
            invalidateSeekOperation()
            isScrubbing = false
            pendingSeekRecoveryAttempt = nil
        }
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
            activeResourceLoader = nil
            item = AVPlayerItem(asset: asset)
        } else {
            activeResourceLoader = nil
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
        // 若是 Stage 2 seek 卡死恢复或切线恢复进度，等 readyToPlay 后先 exact seek 再 play，
        // 避免新 item 先从 0:00 起播再和 seek 竞争。普通新片（resumeAt == nil）直接从 0:00 播。
        if resumeAt == nil && shouldPlay {
            player.play()
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard item === currentItem else { return }
        switch item.status {
        case .readyToPlay:
            updateDuration(item)
            updateBuffered(item)
            // 同片切线恢复进度 或 Stage 2 seek 卡死恢复：走统一的安全精确 seek；
            // 新片/新一集（resumeAt == nil）恒从 0:00 起播，不做自动续播。
            if let resumeAt = pendingResumeAt {
                pendingResumeAt = nil
                let recoveryAttempt = pendingSeekRecoveryAttempt
                pendingSeekRecoveryAttempt = nil
                if resumeAt.seconds > 1 || recoveryAttempt != nil {
                    // 不管是不是重建恢复，代际号都要 +1：重建恢复不 +1 时，
                    // 重建前那次 seek 的旧回调还能对上号、误触 completeSeek。
                    seekGeneration &+= 1
                    performExactSeek(
                        to: resumeAt,
                        shouldResume: shouldPlay,
                        phase: recoveryAttempt != nil ? .rebuiltSeek : .initialSeek
                    )
                } else if shouldPlay {
                    player.play()
                }
            } else if shouldPlay {
                player.play()
            }
        case .failed:
            // Stage 2 重建的 item 也失败：seek 恢复已穷尽，终端失败，不再走切线。
            if seekPhase == .waitingForReplacement {
                failSeek("Replacement item failed")
            } else {
                invalidateSeekOperation()
                handleItemFailure(item)
            }
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
            stallKickTask?.cancel()
            // 仅在“seek 完成等起播”或“Stage 1 踢活”阶段解除看门狗，拦截拖动前排队的过时 .playing KVO
            //（旧代码无条件 playbackDidBecomeActive()，一次旧 .playing 就能把刚发起的 seek 误杀）。
            if let phase = seekPhase {
                switch phase {
                case .waitingForPlayback, .kickingPlayback:
                    playbackDidBecomeActive()
                case .initialSeek, .retrySeek, .waitingForReplacement, .rebuiltSeek:
                    break
                }
            }
            if !isSeekingInFlight {
                isLoading = false
            }
            // 真正出帧 → markPlaying（“正在解析播放线路…”由此消失）。
            if let url = lastURL, didMarkPlayingURL != url {
                didMarkPlayingURL = url
                // 账本：首帧时把 AVPlayer 自身的 accessLog 记下来
                //（实际连到了哪台 IP、有没有换过服务器）。
                let accessEvent = currentItem?.accessLog()?.events.last
                viewModel.recordPlayerLogs(
                    errorURI: nil,
                    serverAddress: accessEvent?.serverAddress,
                    addressChanges: Int(accessEvent?.numberOfServerAddressChanges ?? 0)
                )
                viewModel.markPlaying()
            }
            showControlsTemporarily()
            // 播稳了就开始计 12 秒，满了放开起播码率封顶。
            scheduleCapLift()
        case .paused:
            isPlaying = false
            stallKickTask?.cancel()
            capLiftTask?.cancel()
            // seek 在途时别把 isLoading 清掉（周期回调与转圈仍以 seek 状态为准）。
            if !isSeekingInFlight {
                isLoading = false
            }
            // 暂停时控制条常显，不自动藏。
            controlsVisible = true
        case .waitingToPlayAtSpecifiedRate:
            // 等数据/缓冲：不算在播（按钮显示“播放”），画面转圈。
            isPlaying = false
            isLoading = true
            // 等缓冲不算播稳：放开计时取消，播起来再重计。
            capLiftTask?.cancel()
            // 精确 seek 在途时由 10 秒 seek 看门狗接管，不让 2 秒 stallKick 提前插手打断。
            if !isSeekingInFlight && !isScrubbing {
                scheduleStallKick()
            }
        @unknown default:
            break
        }
    }

    /// 卡住兜底：非 seek 期间等数据超过 2 秒还没播起来、且用户还想播，补一次 play()。
    /// 只认 shouldPlay，不会盖掉用户刚点的暂停；seek/拖动期间不插手（看门狗接管）。
    private func scheduleStallKick() {
        stallKickTask?.cancel()
        guard shouldPlay, !isScrubbing, !isSeekingInFlight,
              let item = currentItem, item.status == .readyToPlay else { return }
        stallKickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.shouldPlay, !self.isScrubbing, !self.isSeekingInFlight,
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
        // 拖动或精确 seek 在途时不回写 currentTime，免得滑块/时间码跳回旧位置。
        if !isScrubbing && !isSeekingInFlight, time.seconds.isFinite {
            currentTime = time.seconds
        }
        if let item = currentItem {
            updateDuration(item)
            updateBuffered(item)
            // 兜底：item 万一进了 failed、KVO/通知又没抓到（回调丢了），
            // 这里每 0.25 秒扫一次也能发现，立刻走失败切线；handleItemFailure
            // 自带“同一 URL 只认一次” guard，重复调无害。
            if item.status == .failed {
                // Stage 2 重建的 item 也失败：seek 恢复已穷尽，终端失败，不再走切线。
                if seekPhase == .waitingForReplacement {
                    failSeek("Replacement item failed")
                } else {
                    handleItemFailure(item)
                }
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
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else {
            bufferedEnd = 0
            return
        }
        // 优先取包含当前播放点的区间（seek 后缓冲段会变），没有才取最后一段；
        // 直接赋值、不做 max，避免缓冲条卡在旧位置下不来。
        let refTime = CMTime(seconds: currentTime, preferredTimescale: 600)
        if let matching = ranges.first(where: { $0.containsTime(refTime) }) {
            let end = CMTimeAdd(matching.start, matching.duration).seconds
            if end.isFinite { bufferedEnd = end }
        } else if let last = ranges.last {
            let end = CMTimeAdd(last.start, last.duration).seconds
            if end.isFinite { bufferedEnd = end }
        }
    }

    /// 播失败只认一次（同一条 URL）：KVO .failed 和失败通知可能先后都到，
    /// 重复报会把刚切上的下一条线也误标失败。走 viewModel.markFailed() 自动切下一条线。
    /// -12881 检测（分片需头信号）：拦截器只拦播单+key，分片是 AVPlayer 直接拉的；
    /// 分片要头时这里报 -12881，以 .segmentFetch 分层报给 markFailed，
    /// 由它回退 hls.js / 升级回环代理（见 markFailed 的 D → P → J）。
    /// 账本：失败时把 AVPlayer 自身的 errorLog URI 与 accessLog 记下来
    ///（绕过判定与分层诊断用），先记日志、再报失败。
    private func handleItemFailure(_ item: AVPlayerItem?) {
        // 拦截旧 item 的迟到失败回调；Stage 2 重建失败由 failSeek 接管，不误触发切线。
        guard let item, item === currentItem else { return }
        if seekPhase == .waitingForReplacement {
            failSeek("Replacement item failed")
            return
        }
        guard let url = lastURL, didMarkFailedURL != url else { return }
        didMarkFailedURL = url
        // 账本：把 AVPlayer 自身的 errorLog/accessLog 记下来（绕过判定与分层诊断用）。
        // errorLog 的 URI 是 AVPlayer 实际请求失败的地址；accessLog 的 serverAddress
        // 说明实际连到了哪台 IP、有没有换过服务器。
        let errorEvent = item.errorLog()?.events.last
        let accessEvent = item.accessLog()?.events.last
        viewModel.recordPlayerLogs(
            errorURI: errorEvent?.uri,
            serverAddress: accessEvent?.serverAddress,
            addressChanges: Int(accessEvent?.numberOfServerAddressChanges ?? 0)
        )
        // FairPlay（skd://）：拦截器或代理已在播单里见到，报明确错误，不走通用失败文案。
        if viewModel.resourceLoader?.encounteredFairPlay == true || viewModel.proxyEncounteredFairPlay {
            viewModel.markFailed("这条线路用了 FairPlay 加密（skd://），当前播放器不支持，请换一条线路")
            return
        }
        let nsError = item.error as NSError?
        if nsError?.code == -12881 {
            viewModel.markFailed("分片拉取失败（分片可能需要请求头，拦截器覆盖不了）", stage: .segmentFetch)
            return
        }
        // HTTP 状态码从 errorLog 取（404 这类 HTTP 失败 errorStatusCode 就是状态码，
        // 非 HTTP 错误时为 0）；拿不到就退回拦截器记的最近一次失败状态码。
        // 传给 markFailed 做 404 判定：404 不走同线引擎升级，直接切备用线。
        let httpStatusCode = (errorEvent?.errorStatusCode).flatMap { $0 > 0 ? $0 : nil }
            ?? viewModel.resourceLoader?.lastFailureStatusCode
        let detail = item.error?.localizedDescription ?? "未知错误"
        viewModel.markFailed("这条线路播放失败（\(detail)）", httpStatusCode: httpStatusCode, failedURL: url)
    }

    /// 播到片尾：停在 0:00（不循环、不续播），控制条常显，等用户再点播放。
    private func handleDidPlayToEnd() {
        invalidateSeekOperation()
        isPlaying = false
        isLoading = false
        controlsVisible = true
        player.currentItem?.cancelPendingSeeks()
        // 片尾复位是位置重置、不是用户快进：唯一保留在状态机之外的直接 seek。
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.currentTime = 0 }
        }
    }

    // MARK: - 播放 / 暂停 / 安全精确快进（Seek 状态机）

    func togglePlayPause() {
        if isPlaying {
            pauseByUser()
        } else {
            playByUser()
        }
    }

    /// 用户点暂停：只改意图并 pause，不取消在途 seek——seek 完成后
    /// completeSeek 按 live shouldPlay 决定不续播，seek 本身仍会落点。
    /// 例外：seek 已落点、仅在等起播/踢活时，用户主动暂停直接收尾，
    /// 不让看门狗在暂停态触发重建。
    func pauseByUser() {
        shouldPlay = false
        player.pause()
        if let phase = seekPhase {
            switch phase {
            case .waitingForPlayback, .kickingPlayback:
                invalidateSeekOperation()
            case .initialSeek, .retrySeek, .waitingForReplacement, .rebuiltSeek:
                break
            }
        }
        isLoading = false
        controlsVisible = true
    }

    /// 用户点播放：只改意图；seek 在途时不直接 play()，等 seek 完成时
    /// completeSeek 按 live shouldPlay 续播，避免 play 与 seek 抢跑。
    /// 若此前因 failSeek 导致当前 item 处于 .failed，点播放时重建 item 恢复，避免永久死播。
    func playByUser() {
        shouldPlay = true
        if currentItem?.status == .failed, let url = lastURL {
            let target = currentTime > 1 ? CMTime(seconds: currentTime, preferredTimescale: 600) : nil
            let loader = (lastEngine == .nativeIntercepted) ? (activeResourceLoader ?? viewModel.resourceLoader) : nil
            replaceItem(url, headers: lastHeaders, resumeAt: target, resourceLoader: loader)
        } else if !isSeekingInFlight && !isScrubbing {
            player.play()
        }
        showControlsTemporarily()
    }

    /// 1. 开始拖进度条：记录意图、作废旧 seek 操作（含待恢复的重建定位）、暂停播放器，但绝不发 seek。
    func beginScrub() {
        isScrubbing = true
        wasPlayingBeforeScrub = shouldPlay
        invalidateSeekOperation()
        pendingResumeAt = nil
        pendingSeekRecoveryAttempt = nil
        stallKickTask?.cancel()
        hideTask?.cancel()
        controlsVisible = true
        player.pause()
    }

    /// 2. 拖动中：只更新 UI 时间显示，绝不调用 AVPlayer.seek（避免 60Hz 零容差请求风暴把 HLS 管线卡死）。
    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
    }

    /// 3. 松手：发出唯一一次精确（±1s）seek，仅在 seek 完成且用户仍想播时 play()，
    /// 并挂前台 10 秒看门狗（Stage 1 取消并重 seek；Stage 2 重建 AVPlayerItem 刷新 CoreMedia/mediaserverd 状态）。
    /// 若 item 仍在重建（.unknown）则更新 pendingResumeAt，等就绪后跳到最新目标，不丢用户操作；
    /// item 已 .failed 则重建 item 到目标时间。
    func endScrub(to seconds: Double) {
        isScrubbing = false
        let resume = wasPlayingBeforeScrub
        shouldPlay = resume
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        if duration > 0 {
            currentTime = clamped
        }
        guard let item = currentItem, duration > 0 else {
            if resume { player.play() }
            return
        }
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        switch item.status {
        case .readyToPlay:
            seekGeneration &+= 1
            performExactSeek(to: target, shouldResume: resume, phase: .initialSeek)
        case .unknown:
            pendingResumeAt = target
            pendingSeekRecoveryAttempt = nil
            isLoading = true
        case .failed:
            if let url = lastURL {
                let loader = (lastEngine == .nativeIntercepted) ? (activeResourceLoader ?? viewModel.resourceLoader) : nil
                replaceItem(url, headers: lastHeaders, resumeAt: target, resourceLoader: loader)
            }
        @unknown default:
            break
        }
    }

    /// 执行单次串行精确 seek（±1s 容差 + 代际号/阶段令牌防旧回调 + 前台 10 秒两阶段看门狗）。
    /// 单一 seek 入口：除片尾复位外，所有 AVPlayer.seek 都走这里。
    /// 另起一个 5 秒兜底 Task：seek 回调 5 秒不回（CoreMedia 卡住）就强制 completeSeek，
    /// 由 waitingForPlayback 的 10 秒看门狗继续接管恢复链；completeSeek 里取消它。
    private func performExactSeek(to targetTime: CMTime, shouldResume: Bool, phase: SeekPhase) {
        let operation = seekGeneration
        seekPhaseToken &+= 1
        let token = seekPhaseToken
        seekPhase = phase
        seekTarget = targetTime
        seekShouldResume = shouldResume
        isSeekingInFlight = true
        isLoading = true

        player.currentItem?.cancelPendingSeeks()

        startSeekWatchdog(operation: operation, token: token, timeout: Self.seekTimeoutSeconds)

        seekCompleteFallbackTask?.cancel()
        seekCompleteFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.seekGeneration == operation,
                  self.seekPhaseToken == token,
                  self.isSeekingInFlight,
                  self.seekPhase == phase,
                  !self.isScrubbing else { return }
            self.completeSeek(operation: operation, fromPhase: phase)
        }

        let tolerance = CMTime(seconds: Self.seekToleranceSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      self.seekGeneration == operation,
                      self.seekPhaseToken == token,
                      self.isSeekingInFlight,
                      self.seekPhase == phase,
                      !self.isScrubbing else { return }
                if finished {
                    self.completeSeek(operation: operation, fromPhase: phase)
                } else {
                    self.advanceSeekRecovery(operation: operation, phase: phase, reason: "Seek completion returned false")
                }
            }
        }
    }

    /// 一次精确 seek 成功落点：上报实际落点时间；播不播以 live shouldPlay 为准
    ///（用户在 seek 中途点暂停/播放都以最新意图为准）。
    /// 若用户仍想播，切到 .waitingForPlayback 并保持看门狗运行直到 timeControlStatus
    /// 真正进入 .playing（play() 后若卡在 waiting，看门狗 10 秒后按阶段升级兜底）。
    private func completeSeek(operation: UInt64, fromPhase: SeekPhase) {
        seekCompleteFallbackTask?.cancel()
        seekCompleteFallbackTask = nil
        let actual = player.currentTime()
        if actual.isNumeric {
            currentTime = actual.seconds
        } else {
            currentTime = seekTarget.seconds
        }
        if shouldPlay && !isScrubbing {
            let attempt: Int
            switch fromPhase {
            case .rebuiltSeek: attempt = 3
            case .retrySeek: attempt = 2
            default: attempt = 1
            }
            seekPhaseToken &+= 1
            let token = seekPhaseToken
            seekPhase = .waitingForPlayback(attempt: attempt)
            isSeekingInFlight = true
            isLoading = true
            player.play()
            if player.timeControlStatus == .playing {
                playbackDidBecomeActive()
            } else {
                startSeekWatchdog(operation: operation, token: token, timeout: Self.seekTimeoutSeconds)
            }
        } else {
            isSeekingInFlight = false
            seekPhase = nil
            stopSeekWatchdog()
            isLoading = false
        }
    }

    /// 播放器真正进入 .playing 后由 handleTimeControlStatus 调用，解除 seek 看门狗。
    private func playbackDidBecomeActive() {
        isSeekingInFlight = false
        seekPhase = nil
        isLoading = false
        stopSeekWatchdog()
    }

    /// 作废当前 seek 操作：代际号与阶段令牌 +1（旧回调/旧看门狗失效）、停看门狗、
    /// 取消待处理 seek、清在途标志。不改 shouldPlay、不暂停播放器。
    private func invalidateSeekOperation() {
        seekGeneration &+= 1
        seekPhaseToken &+= 1
        seekCompleteFallbackTask?.cancel()
        seekCompleteFallbackTask = nil
        stopSeekWatchdog()
        player.currentItem?.cancelPendingSeeks()
        isSeekingInFlight = false
        seekPhase = nil
    }

    /// 两阶段 seek 卡死恢复（每阶段限一次）：
    /// Stage 1（初次 10s 超时）：目标时间已在缓冲内先 playImmediately 踢活，
    /// 给 2.5 秒异步观察窗（绝不紧接着同步重 seek 把踢活打断），再重发一次精确 seek；
    /// Stage 2（重试 10s 超时）：重建 AVPlayerItem（等价于切后台再回前台，清空卡死的 CoreMedia 队列与 mediaserverd 连接），就绪后定位到目标时间；
    /// 终端（重建后 seek 仍失败，或重建 item 未就绪）：停播并报 DEBUG，不再无限循环。
    private func advanceSeekRecovery(operation: UInt64, phase: SeekPhase, reason: String) {
        guard operation == seekGeneration,
              isSeekingInFlight,
              seekPhase == phase else { return }
        stopSeekWatchdog()
        switch phase {
        case .initialSeek, .waitingForPlayback(attempt: 1):
            // 若目标已在缓冲内，先 playImmediately 踢活并给 2.5s 异步观察窗，
            // 绝不紧接着同步重 seek 把踢活打断。
            if seekShouldResume && shouldPlay && isTimeBuffered(seekTarget) {
                seekPhaseToken &+= 1
                let token = seekPhaseToken
                seekPhase = .kickingPlayback
                player.playImmediately(atRate: 1.0)
                if player.timeControlStatus == .playing {
                    playbackDidBecomeActive()
                } else {
                    startSeekWatchdog(operation: operation, token: token, timeout: Self.seekKickGraceSeconds)
                }
                return
            }
            performExactSeek(to: seekTarget, shouldResume: shouldPlay, phase: .retrySeek)
        case .kickingPlayback:
            performExactSeek(to: seekTarget, shouldResume: shouldPlay, phase: .retrySeek)
        case .retrySeek, .waitingForPlayback(attempt: 2):
            guard let url = lastURL else {
                failSeek("Seek stalled and no URL to rebuild: \(reason)")
                return
            }
            seekPhaseToken &+= 1
            let token = seekPhaseToken
            seekPhase = .waitingForReplacement
            pendingSeekRecoveryAttempt = 3
            let loader = (lastEngine == .nativeIntercepted) ? (activeResourceLoader ?? viewModel.resourceLoader) : nil
            replaceItem(
                url,
                headers: lastHeaders,
                resumeAt: seekTarget,
                resourceLoader: loader,
                preserveSeekRecovery: true
            )
            // 重建 item 的就绪窗口也用前台 10 秒看门狗兜底。
            startSeekWatchdog(operation: operation, token: token, timeout: Self.seekTimeoutSeconds)
        case .waitingForReplacement:
            failSeek("Replacement item did not become ready: \(reason)")
        case .rebuiltSeek, .waitingForPlayback(attempt: 3):
            failSeek("Seek failed after item rebuild: \(reason)")
        case .waitingForPlayback:
            // 防御：attempt 只会是 1/2/3（见文件头流程注释），走到这里
            // 说明流程出了预期外的值，干净地终结这次 seek，不无限重试。
            failSeek("Seek failed in unexpected waitingForPlayback phase: \(reason)")
        }
    }

    /// Seek 终端失败：停看门狗、取消待处理 seek、停播、清意图，不再重试。
    /// 原因只打 DEBUG 日志（不弹用户可见报错，用户点播放可重试）。
    private func failSeek(_ reason: String) {
        seekCompleteFallbackTask?.cancel()
        seekCompleteFallbackTask = nil
        stopSeekWatchdog()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        isSeekingInFlight = false
        isScrubbing = false
        shouldPlay = false
        seekPhase = nil
        pendingResumeAt = nil
        pendingSeekRecoveryAttempt = nil
        seekGeneration &+= 1
        seekPhaseToken &+= 1
        isLoading = false
        #if DEBUG
        print("[Seek] terminal failure: \(reason)")
        #endif
    }

    private func isTimeBuffered(_ time: CMTime) -> Bool {
        guard let ranges = player.currentItem?.loadedTimeRanges else { return false }
        return ranges.contains { $0.timeRangeValue.containsTime(time) }
    }

    // MARK: - Seek 看门狗（只在前台计时）

    private func startSeekWatchdog(operation: UInt64, token: UInt64, timeout: TimeInterval) {
        stopSeekWatchdog()
        seekWatchdogRemaining = timeout
        scheduleSeekWatchdog(operation: operation, token: token)
    }

    private func scheduleSeekWatchdog(operation: UInt64, token: UInt64) {
        guard seekAppIsActive,
              operation == seekGeneration,
              token == seekPhaseToken else { return }
        let delay = max(0, seekWatchdogRemaining)
        seekWatchdogDeadline = ProcessInfo.processInfo.systemUptime + delay
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.seekGeneration == operation,
                      self.seekPhaseToken == token,
                      self.isSeekingInFlight else { return }
                self.seekWatchdogWorkItem = nil
                self.seekWatchdogDeadline = nil
                guard let phase = self.seekPhase else { return }
                self.advanceSeekRecovery(operation: operation, phase: phase, reason: "Foreground seek watchdog expired")
            }
        }
        seekWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func stopSeekWatchdog() {
        seekWatchdogWorkItem?.cancel()
        seekWatchdogWorkItem = nil
        seekWatchdogDeadline = nil
        seekWatchdogRemaining = 0
    }

    private func installSeekLifecycleObservers() {
        seekAppIsActive = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        let resign = center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekApplicationWillResignActive()
            }
        }
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.seekApplicationDidBecomeActive()
            }
        }
        seekLifecycleObservers = [resign, active]
    }

    /// 切后台：看门狗暂停计时（冻结剩余秒数），不把后台时间算进 10 秒超时。
    private func seekApplicationWillResignActive() {
        seekAppIsActive = false
        if let deadline = seekWatchdogDeadline {
            seekWatchdogRemaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        }
        seekWatchdogWorkItem?.cancel()
        seekWatchdogWorkItem = nil
        seekWatchdogDeadline = nil
    }

    /// 回前台：seek 还在途就按剩余秒数续计看门狗。
    /// 给回前台后的网络/解码器至少 3 秒苏醒宽限，避免 0.1 秒剩余时间立刻误触发重建。
    private func seekApplicationDidBecomeActive() {
        seekAppIsActive = true
        guard isSeekingInFlight, seekPhase != nil else { return }
        seekWatchdogRemaining = max(seekWatchdogRemaining, Self.foregroundResumeMinGraceSeconds)
        scheduleSeekWatchdog(operation: seekGeneration, token: seekPhaseToken)
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
        guard let top = topViewController(), !(top is FullscreenPlayerViewController) else {
            // 拿不到顶层控制器、或已经在全屏里：直接调 onExit，
            // 不然 controller.isFullscreen 一直 true、再也退不出来。
            onExit()
            return
        }
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
