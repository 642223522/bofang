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
    /// 本次 seek 实际使用的容差（秒）：completeSeek 的落点校验与踢活窗口都用它。
    private var seekAppliedToleranceSeconds: Double = 1.0
    /// 观测到的分片时长（秒）：正常播放时 bufferedEnd 每次跳变的步长；
    /// 供 seek 容差用（见 seekToleranceSeconds()）。
    private var observedSegmentDurationSeconds: Double?
    /// 上次 updateBuffered 记下的缓冲末端（算跳变步长用）。
    private var lastBufferedEnd: Double = 0
    /// Stage 2 重建 item 后待执行的 seek 尝试次数（非 nil = 正在做 seek 卡死恢复，不是新片）。
    private var pendingSeekRecoveryAttempt: Int?
    /// 前台才计时的 seek 看门狗（DispatchWorkItem；后台暂停计时，回前台续计剩余时间）。
    private var seekWatchdogWorkItem: DispatchWorkItem?
    /// 看门狗到期时刻（ProcessInfo.systemUptime 计），后台时据此算剩余时间。
    private var seekWatchdogDeadline: TimeInterval?
    /// 看门狗剩余秒数（后台暂停时冻结，start 时重置为本次预算）。
    private var seekWatchdogRemaining: TimeInterval = 0
    /// App 是否在前台（seek 看门狗只在前台计时）。
    private var seekAppIsActive = true
    /// 前后台切换监听（seek 看门狗暂停/续计用）。
    private var seekLifecycleObservers: [NSObjectProtocol] = []
    /// 看门狗进展基线（seek 发起时采样）与上一次 2 秒采样快照、最近一次
    /// 观测到进展的时刻（systemUptime）。延长看门狗时拿上一次快照作差分。
    private var seekProgressBaseline: SeekProgressSnapshot?
    private var seekPreviousProgressSnapshot: SeekProgressSnapshot?
    private var seekLastProgressUptime: TimeInterval = 0
    /// 看门狗已延长次数（仅计数诊断用，不设上限——每次延长都要重新采样，
    /// 完整一个窗口零推进就不再延长）。
    private var seekExtensionCount: Int = 0
    /// 自适应看门狗预算（秒）：按实测 observedBitrate 估算 2 个分片下载 +
    /// 建连余量，钳制在 [seekMinTimeoutSeconds, seekMaxTimeoutSeconds]；
    /// 没有 observedBitrate 时默认 seekDefaultTimeoutSeconds。
    /// 固定 10 秒一刀切已删：慢网上 10 秒必误杀正在下的分片。
    private static let seekMinTimeoutSeconds: TimeInterval = 22
    private static let seekDefaultTimeoutSeconds: TimeInterval = 30
    private static let seekMaxTimeoutSeconds: TimeInterval = 45
    /// 检测到真实进展时每次延长的秒数（延长时不递增 seekPhaseToken，
    /// 在途 player.seek 的真实回调必须继续有效）。
    private static let seekProgressExtensionSeconds: TimeInterval = 10
    /// 目标已缓冲时 waitingForPlayback 的等待上限（秒）：已缓冲还卡 waiting
    /// 说明不是下载慢，是起播卡住了，8 秒后踢活/恢复接手。
    private static let seekBufferedWaitTimeoutSeconds: TimeInterval = 8
    /// Stage 1 playImmediately 踢活的观察窗口（秒）：给异步切到 .playing 留时间，
    /// 绝不紧接着同步重 seek 把踢活打断。
    private static let seekKickGraceSeconds: TimeInterval = 2.5
    /// seek 回调已回 finished==true、但实际落点不在容差内时的重武间隔（秒）：
    /// seek 本身已结束，短重武看门狗让踢活/延长/重建尽快接手，不用等满整个预算。
    private static let seekFarLandingRearmSeconds: TimeInterval = 3.0
    /// 从后台回前台时的最小宽限秒数：避免刚回前台网络/解码器未苏醒就被 0.1 秒剩余时间误杀。
    private static let foregroundResumeMinGraceSeconds: TimeInterval = 3.0

    /// Seek 恢复完整阶段（attempt：1 = 首次 seek；2 = 仅 finished==false 时的
    /// 立刻重试；3 = 重建 item 后的 seek）：
    /// seeking(1) -> (finished) waitingForPlayback(1)
    /// -> (看门狗到期) kickingPlayback（仅目标已缓冲）/ 延长 / 重建
    /// -> waitingForReplacement -> seeking(3) -> waitingForPlayback(3) -> 终端。
    private enum SeekPhase: Equatable {
        case seeking(attempt: Int)
        case kickingPlayback(attempt: Int)
        case waitingForReplacement
        case waitingForPlayback(attempt: Int)
    }

    /// AVPlayerItem 可观测的真实进展快照（全为公开 AVFoundation API）：
    /// accessLog 是按分片完成刷新的累计值，必须自己做差分；
    /// loadedTimeRanges 在单个分片下载途中纹丝不动、分片完成时才跳变，
    /// 所以“总时长增长”只能证明“有分片落袋”，不能证明“单片下载中”——
    /// 单片下载中的唯一保护是按实测网速算出的自适应预算，不是 2 秒采样。
    private struct SeekProgressSnapshot {
        let totalBytesTransferred: Int64
        let totalMediaRequests: Int
        let bufferedDuration: Double
        let bufferedNearTarget: Double
        let errorLogCount: Int
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
            // 回环监听还没就绪、playerURL 还是原地址：不建 asset（免得裸播原地址
            // 把代理绕过去）；上一引擎不是 proxy 时先拆旧 item，免得旧画面残留。
            if lastEngine != nil && lastEngine != .proxy {
                unloadCurrentItem()
            }
            return
        }
        // 代理时头由代理统一带（UA/Referer/模块头/Cookie），不挂到回环 asset 上；
        // 回环地址不需要头，挂了反而把身份暴露给 AVPlayer 的日志。
        let effectiveHeaders = engine == .proxy ? nil : headers
        let engineChanged = lastEngine != engine
        // run #36 P0-12：去重条件须纳入代际与失败态，否则同 URL/头/引擎的
        // 手动重试（switchLine）或同分集重播（playGeneration 已换）会直接早退，
        // status 永久卡在“正在解析播放线路…”。拦截器路还要比 resourceLoader 身份：
        // ViewModel 换了新拦截器实例时，当前 item 绑的还是旧的，必须重建。
        // HLSResourceLoader 是 class（final class，NSObject 子类），!== 合法。
        let loaderChanged = engine == .nativeIntercepted
            && viewModel.resourceLoader !== activeResourceLoader
        guard lastURL != url || lastHeaders != effectiveHeaders || engineChanged
            || viewModel.playGeneration != lastGeneration || didMarkFailedURL != nil
            || loaderChanged else { return }
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
        // 全屏开着时引擎切走：全屏模态是顶层 present 的，视图卸载不会自动关；
        // 不主动关会留黑屏模态（与软解 teardown 调 dismissActive 同款）。
        if isFullscreen {
            isFullscreen = false
            FullscreenPlayerPresenter.dismissActive()
        }
        replaceItem(nil, headers: nil, resumeAt: nil)
    }

    /// 请求头大小写不敏感取值（模块可能给 "user-agent" 等写法）。
    private static func headerValue(_ headers: [String: String]?, _ name: String) -> String? {
        headers?.first(where: { $0.key.lowercased() == name.lowercased() })?.value
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
            let userAgent = Self.headerValue(headers, "User-Agent") ?? PlaybackEngine.iPhoneUserAgent
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
                    performSeek(
                        to: resumeAt,
                        phase: .seeking(attempt: recoveryAttempt ?? 1)
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
                case .seeking, .waitingForReplacement:
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
            // 每 2 秒采一次 accessLog（8 次 × 0.25 秒），同时采 seek 进展
            //（只在前台走，切后台冻结，与看门狗一致）。
            accessLogSampleCount += 1
            if accessLogSampleCount >= 8 {
                accessLogSampleCount = 0
                sampleAccessLog(item)
                sampleSeekProgress(item)
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
            lastBufferedEnd = 0
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
        // 正常播放时缓冲末端的跳变步长 ≈ 一个分片时长（HLS 按完整分片提交区间）：
        // 只在非 seek/非拖动时采，跳变在 2–12 秒内才认（一次来两片会跳 16 秒以上，
        // 那不是单片时长，不采）。供 seek 容差用；采不到就走时长默认值。
        if !isSeekingInFlight && !isScrubbing, lastBufferedEnd > 0 {
            let jump = bufferedEnd - lastBufferedEnd
            if jump >= 2.0 && jump <= 12.0 {
                observedSegmentDurationSeconds = jump
            }
        }
        lastBufferedEnd = bufferedEnd
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
            viewModel.markFailed("这条线路用了 FairPlay 加密（skd://），当前播放器不支持，请换一条线路", failedURL: url)
            return
        }
        let nsError = item.error as NSError?
        if nsError?.code == -12881 {
            viewModel.markFailed("分片拉取失败（分片可能需要请求头，拦截器覆盖不了）", stage: .segmentFetch, failedURL: url)
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
        // 播完即用户意图 = 不播：不清 shouldPlay 的话，复位 seek 后一旦进
        // waiting，2 秒 stallKick 会按 shouldPlay 补 play()，违背“不自动续播”铁律。
        shouldPlay = false
        player.pause()
        stallKickTask?.cancel()
        stallKickTask = nil
        isPlaying = false
        isLoading = false
        controlsVisible = true
        player.currentItem?.cancelPendingSeeks()
        // 片尾复位是位置重置、不是用户快进：唯一保留在状态机之外的直接 seek。
        // 回调只认当初那一项、且不在拖动中：换片/拖动途中回来的旧回调把
        // currentTime 写 0 会打掉新片时间或用户刚拖到的位置。
        let finishedItem = currentItem
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItem === finishedItem, !self.isScrubbing else { return }
                self.currentTime = 0
            }
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
            case .seeking, .waitingForReplacement:
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

    /// 3. 松手：发出唯一一次精确 seek（自适应容差），仅在 seek 完成且用户仍想播时 play()，
    /// 并挂前台自适应预算看门狗（目标已缓冲先踢活；预算耗尽 + 完整窗口零推进才重建 item）。
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
            performSeek(to: target, phase: .seeking(attempt: 1))
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

    /// 执行单次串行精确 seek（自适应容差 + 代际号/阶段令牌防旧回调 +
    /// 前台自适应预算看门狗 + 2 秒进展采样）。
    /// 单一 seek 入口：除片尾复位外，所有 AVPlayer.seek 都走这里。
    /// 没有 5 秒兜底 Task：seek 回调 5 秒不回时强制 completeSeek 是本次
    /// 事故的根因之一——它用 player.currentTime() 发布的陈旧时间把进度条
    /// 打回旧位置，还会把未落点的 item 强制 play() 回 0:00；
    /// 回调不回时由看门狗 + 进展采样接管（延长/重建），不伪造完成。
    private func performSeek(to targetTime: CMTime, phase: SeekPhase) {
        let operation = seekGeneration
        seekPhaseToken &+= 1
        let token = seekPhaseToken
        seekPhase = phase
        seekTarget = targetTime
        seekAppliedToleranceSeconds = seekToleranceSeconds()
        isSeekingInFlight = true
        isLoading = true

        // cancelPendingSeeks 只在新用户操作（attempt 1）时调用：
        // 重试（attempt 2）与重建后（attempt 3）路径不取消——
        // 前者回调已回、无在途 seek；后者是全新 item、无旧 seek 可取。
        if case .seeking(attempt: 1) = phase {
            player.currentItem?.cancelPendingSeeks()
        }

        // 看门狗基线：seek 发起时采样，供进展判断作起点。
        // 最近进展时刻初值 = 0（“还没观测到进展”）：2 秒采样发现增长才刷新。
        // 绝不能初值 = 发起时刻——远落点 3 秒重武/踢活 2.5 秒重武到期时，
        // 距发起还不到 4 秒，看门狗会误判“最近 4 秒有进展”白延 10 秒。
        seekProgressBaseline = captureProgressSnapshot()
        seekPreviousProgressSnapshot = seekProgressBaseline
        seekLastProgressUptime = 0
        seekExtensionCount = 0

        startSeekWatchdog(operation: operation, token: token, timeout: adaptiveSeekTimeout())

        let tolerance = CMTime(seconds: seekAppliedToleranceSeconds, preferredTimescale: 600)
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
                    self.handleSeekReturnedFalse(operation: operation, phase: phase)
                }
            }
        }
    }

    /// seek 真实回调 finished==true：只在落点在自适应容差内时才发布 actual；
    /// 落点离目标超过容差（远落点）时不切换阶段、不调 player.play()、
    /// 不发布 actual——currentTime 保持 seekTarget，进度条锁在目标不动，
    /// 只重武当前阶段的看门狗（3 秒），让踢活/延长/重建尽快接手。
    /// 播不播以 live shouldPlay 为准（用户在 seek 中途点暂停/播放都以最新意图为准）。
    /// 若用户仍想播，切到 .waitingForPlayback 并保持看门狗运行直到 timeControlStatus
    /// 真正进入 .playing（play() 后若卡在 waiting，看门狗按阶段升级兜底）。
    private func completeSeek(operation: UInt64, fromPhase: SeekPhase) {
        let actual = player.currentTime()
        let tol = seekAppliedToleranceSeconds
        let landedNearTarget: Bool
        if actual.isNumeric, actual.seconds.isFinite {
            landedNearTarget = abs(actual.seconds - seekTarget.seconds) <= tol
        } else {
            landedNearTarget = false
        }
        guard landedNearTarget else {
            // 远落点：不发布 actual、不切换阶段、不 play()。
            // currentTime 保持 seekTarget（进度条锁在目标），
            // 短重武 3 秒看门狗：seek 本身已结束，尽快让踢活/延长/重建接手。
            #if DEBUG
            print("[Seek] far landing: actual=\(actual.seconds) target=\(seekTarget.seconds) tol=\(tol), re-arming watchdog")
            #endif
            // 远落点重武 3 秒：最近进展时刻归零，否则重武到期时距上次分片落袋
            // 不足 4 秒会误判“最近 4 秒有进展”白延 10 秒（与 performSeek 初值 0 同理）。
            seekLastProgressUptime = 0
            stopSeekWatchdog()
            seekWatchdogRemaining = Self.seekFarLandingRearmSeconds
            scheduleSeekWatchdog(operation: operation, token: seekPhaseToken)
            return
        }
        // 落点在容差内：发布 actual（与目标差 ≤ 容差，进度条不跳变）。
        if actual.isNumeric {
            currentTime = actual.seconds
        } else {
            currentTime = seekTarget.seconds
        }
        if shouldPlay && !isScrubbing {
            let attempt = attempt(of: fromPhase)
            seekPhaseToken &+= 1
            let token = seekPhaseToken
            seekPhase = .waitingForPlayback(attempt: attempt)
            isSeekingInFlight = true
            isLoading = true
            player.play()
            if player.timeControlStatus == .playing {
                playbackDidBecomeActive()
            } else {
                // 重建后 seek（attempt 3）：目标分片在重建前已确认下载过，
                // 落点后等起播的上限是 8 秒——已缓冲还卡 waiting 说明是起播卡住，
                // 不是下载慢，8 秒后踢活/恢复接手。
                // 初次/重试 seek：落点后等起播用自适应预算（目标分片可能还在下）。
                let timeout = attempt == 3 ? Self.seekBufferedWaitTimeoutSeconds : adaptiveSeekTimeout()
                startSeekWatchdog(operation: operation, token: token, timeout: timeout)
            }
        } else {
            isSeekingInFlight = false
            seekPhase = nil
            stopSeekWatchdog()
            isLoading = false
        }
    }

    /// seek 真实回调 finished==false：只重试一次（attempt 1 -> 2），
    /// 不取消、不重建——finished==false 只是这次 seek 被取消/打断，
    /// 不是卡死；卡死的恢复只走看门狗到期。
    private func handleSeekReturnedFalse(operation: UInt64, phase: SeekPhase) {
        guard operation == seekGeneration,
              isSeekingInFlight,
              seekPhase == phase else { return }
        if case let .seeking(attempt: attempt) = phase, attempt == 1 {
            performSeek(to: seekTarget, phase: .seeking(attempt: 2))
        } else {
            // attempt 2/3 回 false：不再重试，等在途看门狗到期接管
            //（重试路径不取消，旧看门狗继续跑）。
            #if DEBUG
            print("[Seek] seek returned false on \(phase), watchdog continues")
            #endif
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
        stopSeekWatchdog()
        player.currentItem?.cancelPendingSeeks()
        isSeekingInFlight = false
        seekPhase = nil
    }

    /// 看门狗到期时的恢复（按当前事实决策，不按固定次数）：
    /// 1) 目标已缓冲 → 踢活（窗口化判定，2.5 秒异步观察窗）；
    ///    已在踢活阶段且踢活没起效 → 不再重复踢活，直接进重建/终结。
    /// 2) 目标未缓冲、但最近 4 秒内有真实进展（分片刚落袋）→ 延长 10 秒，
    ///    不递增 seekPhaseToken（在途 player.seek 的真实回调继续有效），
    ///    延长次数不限——每次到期都重新判断，完整窗口零推进才进重建。
    /// 3) 目标未缓冲且完整窗口零推进 → 重建 item（仅一次）或终结。
    /// 注意：延长看的是“最近进展时刻”（2 秒采样刷新），不是“上一快照”——
    /// loadedTimeRanges/accessLog 只在分片完成时刷新，单个分片下载途中
    /// 纹丝不动；单片下载中的保护是自适应预算本身，不是 2 秒采样。
    private func advanceSeekRecovery(operation: UInt64, phase: SeekPhase, reason: String) {
        guard operation == seekGeneration,
              isSeekingInFlight,
              seekPhase == phase else { return }
        stopSeekWatchdog()

        // 暂停态：绝不触发重 seek/重建/踢活——直接作废这次 seek（停在当前位置，
        // 不清 shouldPlay、不暂停播放器；用户再点播放就从当前位置播，不挂死）。
        // 正常播放态才进下面的踢活/延长/重建。
        // 注意：pauseByUser 只在 .waitingForPlayback/.kickingPlayback 作废，
        // .seeking 阶段用户点暂停时 seek 还在途，所以这里必须再拦一道。
        guard shouldPlay else {
            #if DEBUG
            print("[Seek] watchdog expired while paused (\(reason)), abandoning seek")
            #endif
            invalidateSeekOperation()
            return
        }

        // 1. 目标已缓冲 → 踢活（窗口化判定：缓冲区间与 [目标±容差] 相交即算）。
        let attempt = attempt(of: phase)
        if shouldPlay, isTimeBufferedNear(seekTarget) {
            // 已在踢活阶段且踢活没起效：不再重复踢活，直接进重建/终结。
            if case .kickingPlayback = phase {
                rebuildOrFailSeek(operation: operation, attempt: attempt, reason: reason)
                return
            }
            seekPhaseToken &+= 1
            let token = seekPhaseToken
            seekPhase = .kickingPlayback(attempt: attempt)
            player.playImmediately(atRate: 1.0)
            if player.timeControlStatus == .playing {
                playbackDidBecomeActive()
            } else {
                startSeekWatchdog(operation: operation, token: token, timeout: Self.seekKickGraceSeconds)
            }
            return
        }

        // 2. 最近 4 秒内有真实进展（分片刚落袋）→ 延长 10 秒，不递增 token。
        let now = ProcessInfo.processInfo.systemUptime
        if now - seekLastProgressUptime <= 4.0 {
            seekExtensionCount += 1
            #if DEBUG
            print("[Seek] progress observed (\(reason)), extending watchdog +10s (count=\(seekExtensionCount))")
            #endif
            seekWatchdogRemaining = Self.seekProgressExtensionSeconds
            scheduleSeekWatchdog(operation: operation, token: seekPhaseToken)
            return
        }

        // 3. 目标未缓冲且完整窗口零推进 → 重建（仅一次）或终结。
        rebuildOrFailSeek(operation: operation, attempt: attempt, reason: reason)
    }

    /// 重建 item（仅一次）或终结：attempt < 3 → 重建；
    /// 已是 attempt 3（重建后）→ failSeek。
    /// 重建的前提是“预算已耗尽 + 完整窗口零推进 + 踢活已失败”
    ///（调用方 advanceSeekRecovery 已做完踢活/延长判断，这里只看 attempt）。
    /// 重建 item 也挂进展采样看门狗（handleItemStatus 就绪后 performSeek
    /// 会重建基线并重武自适应预算；就绪窗口内未就绪则 failSeek）。
    private func rebuildOrFailSeek(operation: UInt64, attempt: Int, reason: String) {
        guard attempt < 3 else {
            failSeek("Seek failed after item rebuild: \(reason)")
            return
        }
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
        // 重建 item 的就绪窗口也用前台自适应预算看门狗兜底。
        startSeekWatchdog(operation: operation, token: token, timeout: adaptiveSeekTimeout())
    }

    /// Seek 终端失败：停看门狗、取消待处理 seek、停播、清意图，不再重试。
    /// 原因只打 DEBUG 日志（不弹用户可见报错，用户点播放可重试）。
    private func failSeek(_ reason: String) {
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

    /// 窗口化缓冲判定：任一缓冲区间与 [目标 − 容差, 目标 + 容差] 相交即算
    /// 目标已缓冲（旧 containsTime(目标) 在容差下会误判：落点可以不在目标点上，
    /// 只要在容差窗内就算落点有效、缓冲有效）。
    private func isTimeBufferedNear(_ time: CMTime) -> Bool {
        guard let ranges = player.currentItem?.loadedTimeRanges, !ranges.isEmpty else { return false }
        let tol = seekAppliedToleranceSeconds
        let windowStart = max(0, time.seconds - tol)
        let windowEnd = time.seconds + tol
        return ranges.contains { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { return false }
            return start <= windowEnd && start + duration >= windowStart
        }
    }

    /// [目标 − 容差, 目标 + 容差] 窗口内已缓冲的秒数（进展快照用）。
    private func bufferedForwardSecondsNear(_ time: CMTime) -> Double {
        guard let ranges = player.currentItem?.loadedTimeRanges else { return 0 }
        let tol = seekAppliedToleranceSeconds
        let windowStart = max(0, time.seconds - tol)
        let windowEnd = time.seconds + tol
        return ranges.reduce(0.0) { partial, value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { return partial }
            let overlapStart = max(start, windowStart)
            let overlapEnd = min(start + duration, windowEnd)
            return partial + max(0, overlapEnd - overlapStart)
        }
    }

    /// 取 SeekPhase 的 attempt（1 = 首次 seek；2 = finished==false 的立刻重试；
    /// 3 = 重建 item 后的 seek；.waitingForReplacement 正在等重建，算 3）。
    private func attempt(of phase: SeekPhase) -> Int {
        switch phase {
        case .seeking(let attempt), .kickingPlayback(let attempt), .waitingForPlayback(let attempt):
            return attempt
        case .waitingForReplacement:
            return 3
        }
    }

    /// seek 容差与预算共用的分片时长（秒），来源链：
    /// 1) 拦截器解析到的播单 #EXT-X-TARGETDURATION（最准）；
    /// 2) 正常播放时观测到的 loadedTimeRanges 跳变步长；
    /// 3) 时长 > 60 秒的长视频默认 8.34 秒（memojav 实测）、短视频默认 2 秒。
    private func seekSegmentDurationSeconds() -> Double {
        if let targetDuration = viewModel.resourceLoader?.targetDurationSeconds, targetDuration > 0 {
            return targetDuration
        }
        if let observed = observedSegmentDurationSeconds, observed > 0 {
            return observed
        }
        return duration > 60 ? 8.34 : 2.0
    }

    /// 自适应 seek 容差：长视频（> 60 秒）= 分片时长/2 + 0.5 秒
    ///（8.34 秒分片 → 4.5 秒，覆盖“落点在段首、目标在段内”的情况）；
    /// 短视频 = 1.0 秒。容差太小（±1 秒）等于零容差：
    /// 8.34 秒分片里只有约 24% 的目标落在段首 ±1 秒内（2/8.34）。
    private func seekToleranceSeconds() -> Double {
        guard duration > 60 else { return 1.0 }
        return seekSegmentDurationSeconds() / 2.0 + 0.5
    }

    /// 自适应看门狗预算：2 个分片的下载时间 + 建连余量 8 秒，钳制 [22, 45]。
    /// 单分片下载时间 = 分片时长 × (媒体码率 / 实测网速)：实测网速是 accessLog
    /// 最近一次事件的 observedBitrate（网络侧实测吞吐），媒体码率是同一事件的
    /// indicatedBitrate。网速 ≥ 媒体码率时 1 个分片 ≤ 1 个分片时长；
    /// 网速只有媒体码率一半时 1 个分片要 2 个分片时长——预算跟着实测走。
    /// 没有 observedBitrate（还没播过、accessLog 为空）或 ≤ 50_000 bps 时默认 30 秒。
    /// 依据：memojav 沙箱实测——远 seek 只需 1 个 2.2 MB 分片（~4 秒纯网络），
    /// 慢手机上 10–20 秒是正常慢、不是卡死；固定 10 秒必误杀。
    private func adaptiveSeekTimeout() -> TimeInterval {
        guard let event = player.currentItem?.accessLog()?.events.last,
              event.observedBitrate.isFinite, event.observedBitrate > 50_000,
              event.indicatedBitrate.isFinite, event.indicatedBitrate > 0 else {
            return Self.seekDefaultTimeoutSeconds
        }
        let segment = seekSegmentDurationSeconds()
        let ratio = event.indicatedBitrate / event.observedBitrate
        let budget = 2.0 * segment * ratio + 8.0
        return min(max(budget, Self.seekMinTimeoutSeconds), Self.seekMaxTimeoutSeconds)
    }

    /// 采样当前可观测进展（公开 AVFoundation API；resourceLoader 字节
    /// 对 native/.nativeIntercepted 不可见，不作判据）：
    /// - accessLog 累计字节/事件数（分片完成时刷新，须做差分）；
    /// - loadedTimeRanges 总缓冲时长（分片完成时跳变）；
    /// - 目标附近缓冲时长（踢活“目标分片已落地、缓冲末端逼近目标”的信号）；
    /// - errorLog 条数（真故障信号：条数增加说明 item 在报错，不是下载慢）。
    private func captureProgressSnapshot() -> SeekProgressSnapshot {
        let item = player.currentItem
        let log = item?.accessLog()
        let totalBytes = log?.events.reduce(into: Int64(0)) { partial, event in
            partial += event.numberOfBytesTransferred
        } ?? 0
        let bufferedTotal = item?.loadedTimeRanges.reduce(0.0) { partial, value in
            let range = value.timeRangeValue
            let duration = range.duration.seconds
            return partial + (duration.isFinite ? duration : 0)
        } ?? 0
        let errorCount = item?.errorLog()?.events.count ?? 0
        return SeekProgressSnapshot(
            totalBytesTransferred: totalBytes,
            totalMediaRequests: log?.events.count ?? 0,
            bufferedDuration: bufferedTotal,
            bufferedNearTarget: bufferedForwardSecondsNear(seekTarget),
            errorLogCount: errorCount
        )
    }

    /// 两次快照之间是否有真实进展（任一信号增长即算）：
    /// loadedTimeRanges 总时长、accessLog 累计字节/事件数、目标附近缓冲。
    /// errorLog 条数增加不算进展——那是真故障信号（调用方据此可直接进恢复，
    /// 这里只返回“无进展”，让恢复链接手）。
    private func hasSeekProgress(since previous: SeekProgressSnapshot, current: SeekProgressSnapshot) -> Bool {
        current.bufferedDuration > previous.bufferedDuration
            || current.totalBytesTransferred > previous.totalBytesTransferred
            || current.totalMediaRequests > previous.totalMediaRequests
            || current.bufferedNearTarget > previous.bufferedNearTarget
    }

    /// 2 秒进展采样（handlePeriodicTime 每 2 秒调一次，仅前台）：
    /// 任一信号增长就刷新“最近进展时刻”；快照每次都更新作下轮差分基线。
    /// 注意：loadedTimeRanges/accessLog 只在分片完成时刷新，单个分片下载途中
    /// 纹丝不动——所以采样只能证明“有分片落袋”，不能证明“单片下载中”；
    /// 单片下载中的唯一保护是按实测网速算出的自适应预算，不是 2 秒采样。
    private func sampleSeekProgress(_ item: AVPlayerItem) {
        guard isSeekingInFlight, seekPhase != nil else { return }
        guard seekAppIsActive else { return }
        guard let previous = seekPreviousProgressSnapshot ?? seekProgressBaseline else { return }
        let current = captureProgressSnapshot()
        if hasSeekProgress(since: previous, current: current) {
            seekLastProgressUptime = ProcessInfo.processInfo.systemUptime
        }
        seekPreviousProgressSnapshot = current
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
        .onDisappear {
            // 全屏失败切走非原生引擎时视图卸载，.onChange(of: controller.isFullscreen)
            // 已失效：即使 unloadCurrentItem 随后关了模态、controller.isFullscreen
            // 回 false，DetailView 的 isFullscreen 仍可能卡 true，离页 guard
            // !isFullscreen 会阻断停播。只在引擎已切走非原生时清（原生全屏是
            // overFullScreen，不触发这里；即使触发，引擎仍是原生三引擎之一，
            // 条件不成立，不误清正常全屏进出状态）。
            let engine = viewModel.currentEngine
            if engine != .native && engine != .nativeIntercepted && engine != .proxy && isFullscreen {
                isFullscreen = false
                controller.unloadCurrentItem()
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
/// 整体 @MainActor：topViewController() 直接访问 UIApplication.shared，
/// 非隔离会有 Swift 6 隔离违规。调用方只有 CustomPlayerView 的
/// .onChange（SwiftUI 主线程上下文）与本文件内，无非隔离调用方受影响。
@MainActor
enum FullscreenPlayerPresenter {
    /// 正在呈现的全屏 VC（弱引用）：全屏期引擎切走时 CustomPlayerView 卸载，
    /// 没人持有这个模态——不主动关会飘在详情页上面播黑屏。
    private static weak var activeVC: FullscreenPlayerViewController?

    @MainActor
    static func present(player: AVPlayer, controller: CustomPlayerController, viewModel: PlayerViewModel, onExit: @escaping () -> Void) {
        // 拿不到顶层控制器（转场/退后台瞬间）：直接调 onExit 把 isFullscreen
        // 复位，不然 controller.isFullscreen 一直 true、再也退不出来。
        guard let top = topViewController() else {
            onExit()
            return
        }
        // 已经在全屏里：不调 onExit（调了会把 isFullscreen 复位，全屏 VC 还在上面，
        // 画面门控会把 video view 从全屏容器摘掉，反而黑屏），直接返回。
        // （与 SoftDecoderFullscreenPresenter 同款。）
        if top is FullscreenPlayerViewController { return }
        let vc = FullscreenPlayerViewController(player: player, controller: controller, viewModel: viewModel, onExit: onExit)
        activeVC = vc
        top.present(vc, animated: true, completion: nil)
    }

    /// 引擎切走/离页时主动关掉还开着的全屏（CustomPlayerController.unloadCurrentItem 调；
    /// 退出按钮走 VC 自己的 onExit，不走这里，不会重复关）。
    @MainActor
    static func dismissActive() {
        guard let vc = activeVC else { return }
        activeVC = nil
        vc.dismiss(animated: true, completion: nil)
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              var vc = window.rootViewController else { return nil }
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
