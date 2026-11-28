import Combine
import SwiftUI
import UIKit

#if canImport(KSPlayer)
import KSPlayer
#endif

// MARK: - 软解播放器（C 路 Wave 2，KSPlayer / FFmpeg）
//
// 选型：KSPlayer（kingslay/KSPlayer，SPM，product / module 名均为 KSPlayer，
// 与 PlayerEngine.swift 的 `#if canImport(KSPlayer)` 判断一致；project.yml
// 里 `from: "2.3.4"`（2026-11-25 实测：KSPlayer 根本没有 2.7.3 这个 tag，
// 现有 tag 只有 2.0.7–2.3.4 与 5.6.2；5.6.2 是预编译 xcframework 且无 iOS
// 切片，#57 归档失败，改用源码版 2.3.4；#56 即因 2.7.3 不存在而解析失败。
// KSPlayer 官方 README 只给 `.branch("main")`，若 2.3.4 解析失败再试 main）。
//  - KSPlayer：SPM 原生、Swift 编写、FFmpeg 7.0.2（GPL 版 6.1.0）、iOS 13+，
//    维护活跃（配套 TracyPlayer 在 App Store 持续更新）；API 有据可查：
//    KSPlayerLayer(url:options:delegate:) / play() / pause() /
//    seek(time:autoPlay:completion:) / stop() / prepareToPlay()、
//    KSPlayerLayerDelegate 四个回调、
//    KSOptions.isAutoPlay / isLoopPlay / startPlayTime / hardwareDecode /
//    registerRemoteControll / referer / userAgent / appendHeader、
//    KSOptions.firstPlayerType / secondPlayerType = KSMEPlayer.self。
//  - ijkplayer 否决：无 SPM（只有 CocoaPods + 手工编译 FFmpeg）、
//    上游最后稳定版 0.8.8 基于 FFmpeg 3.4（2018 年）、事实上停更；
//    CocoaPods 本身 2024-08 已进维护模式、trunk 2026-12-02 只读，
//    接它还要改 codemagic.yaml 加 pod install，侵入大、收益为负。
//  - 许可证（必须让用户知道）：KSPlayer 默认 GPL v3（README 原话）。
//    本软件只侧载给用户自己用、不对外分发，不触发 GPL 的源码公开义务；
//    若以后要分发给别人，须开源本软件源码或向作者买 LGPL/商业授权
//    （kingslay@icloud.com）。FFmpeg 本体是 LGPL，GPL 来自 KSPlayer 这一层。
//
// 定位：只在路由表判给 .softDecoder 时挂载（非原生容器 .mkv/.flv/.avi/
// .webm，或无 dash.js 时的 .mpd）。不是默认回退：没有软解内核时路由不会
// 选它；软解失败直接 markFailed 切线，不无意义重试。
//
// 结构（对标 CustomPlayerController / HLSJSPlayerController）：
// 只用 KSPlayer 最底层的 KSPlayerLayer（CALayer 子类），不用
// KSVideoPlayerView（它自带控制条/AirPlay/PiP 按钮，会破坏本软件统一外观
// 与“不要 AirPlay/画中画/灵动岛”的铁律）；画面用 layer.player.view 挂进
// 容器 UIView（用法与 KSPlayer 官方示例一致），控制条复用 PlayerControlBar。
// 不用 KSComplexPlayerLayer（PiP 与后台/远程控制都在那一层）。
//
// 外观与行为（与原生播放器一致，不发明新 UI）：
// 16:9 内嵌在详情页顶部小窗口，自绘底条复用 PlayerControlBar（播放/暂停、
// 进度条、时间、画质菜单、全屏）；不用 AVPlayerViewController，不触发系统
// Now Playing（无灵动岛）；KSOptions.registerRemoteControll=false 再保一层；
// 不走 AirPlay、不开画中画；每次新片/新一集从 0:00 起播，不自动续播；
// 同片切线保当前进度（playGeneration 语义与 CustomPlayerController 一致）；
// 失败调 viewModel.markFailed 自动切线；离页停播（onDisappear/dismantle
// 停层销毁，不后台继续播）。automaticallyWaitsToMinimizeStalling=true 只
// 约束 AVPlayer，本播放器是 FFmpeg，不要去碰它；缓冲由 FFmpeg 自己管。
//
// 画质：KSPlayer 不像 hls.js/dash.js 那样暴露码率档位列表（tracks 只是音视频
// 轨，不是清晰度档），所以画质菜单复用原生做法——从 viewModel.lines 推导
// （切画质=切线路，同片同 generation 保进度）；只有“自动”一档时按钮自动隐藏
// （PlayerControlBar 要求选项 >= 2 才显示）。
//
// 已核实的 API（核实来源写在各调用处注释里；本地无 Xcode，只能人工审，
// Codemagic 构建是确认关口）：
//  - KSPlayerLayer(url:options:delegate:) / play() / pause() /
//    seek(time:autoPlay:completion:) / stop() / prepareToPlay()、
//    KSPlayerLayerDelegate 的
//    player(layer:state:) / player(layer:currentTime:totalTime:) /
//    player(layer:finish:) / player(layer:bufferedCount:consumeTime:)——
//    均见 KSPlayer 官方 README 与 Streamyfin 的 KSPlayerLayer 文档示例原文。
//  - state == .readyToPlay、state.isPlaying——.readyToPlay 见官方示例原文；
//    isPlaying 见 Streamyfin FullPlayerView 示例（coordinator.state.isPlaying）。
//    除此二者外不依赖 KSPlayerState 的任何其他 case；.error / 播完都走
//    finish(error:)（error 非空=失败，空=自然播完）。
//  - layer.player.view（UIView?）——见官方示例原文；player 本身非可选。

#if canImport(KSPlayer)

// MARK: - 控制器（状态机，对标 CustomPlayerController）

/// 软解播放器的状态机（ObservableObject，@MainActor）。
/// 只管 KSPlayerLayer：换片、自动播、播放/暂停、快进、画质、缓冲、失败上报、
/// 全屏与控制条显隐。线路、路由、markPlaying/markFailed 仍走 PlayerViewModel，
/// 这里不重写。播放状态以 KSPlayerLayerDelegate 回调为准，不用本地旗子猜——
/// 与原生播放器“状态跟真实 timeControlStatus”的做法同源。
@MainActor
final class SoftDecoderPlayerController: ObservableObject {
    let viewModel: PlayerViewModel

    /// 真实播放状态：KSPlayerState.isPlaying 为 true 才为 true（按钮据此显示暂停/播放）。
    @Published var isPlaying = false
    /// 当前播放秒数（currentTime 回调；拖进度条时由 scrub 直接改，松手后回调接管）。
    @Published var currentTime: Double = 0
    /// 总时长秒数（未知为 0）。
    @Published var duration: Double = 0
    /// 已缓冲到的秒数（bufferedCount 回调估算，进度条浅灰段）。
    @Published var bufferedEnd: Double = 0
    /// 正在等数据/缓冲（画面中央转圈；与 PlayerControlBar 的 isBuffering 同义）。
    @Published var isLoading = false
    /// 控制条是否可见（播时 3 秒无操作自动藏，暂停时常显，点画面切换）。
    @Published var controlsVisible = true
    /// 是否在全屏（按钮图标据此切全屏/退出全屏；画面 view 的挂载门控也认它）。
    @Published var isFullscreen = false
    /// 画面层代际（run #36 P0-9）：KSPlayerLayer 重建（后端回退换出新
    /// player.view）或就绪时递增，作为值传给 SoftDecoderKSView，迫使
    /// SwiftUI 调用 updateUIView 把画面 view 重新挂回容器（只传 controller
    /// 同对象引用时结构体值不变、updateUIView 会被跳过，导致有声黑屏）。
    @Published var layerRevision = 0
    /// 画质选项（从 viewModel.lines 推导，与原生同款）与当前档位。
    @Published var qualityOptions: [QualityOption] = []
    @Published var currentQualityLabel: String = "自动"

    /// 用户意图：true=想播（自动播/点播放），false=点了暂停。
    /// 新 URL 时重置为 true；只有用户点暂停才变 false。
    private var shouldPlay = true
    private var lastURL: URL?
    private var lastHeaders: [String: String]?
    /// 上次见到的播放会话代际（PlayerViewModel.playGeneration）：
    /// 变了=新片/新一集（从 0:00 起），没变=同片切线（保当前进度）。
    private var lastGeneration: UUID?
    private var didMarkPlayingURL: URL?
    private var didMarkFailedURL: URL?
    /// 拖进度条前是不是在播（松手后据此恢复）。
    private var wasPlayingBeforeScrub = false
    /// 拖动中：拖动时只改本地 currentTime，不向 KSPlayer 狂发 seek；
    /// handleTime 回写也暂停，松手 endScrub 一次 seek。
    private var isScrubbing = false
    /// 松手 seek 在途（endScrub 发起、seek 回调回来之前）：handleTime 也要拦，
    /// 否则 seek 没落点前进度回调会把进度条弹回旧位置；与 isScrubbing 分开，
    /// 拖动结束（isScrubbing=false）不等于 seek 已完成。
    private var isSeeking = false
    /// 松手 seek 代际：beginScrub/endScrub/buildLayer/teardownLayer 递增，
    /// 旧 seek 回调回来时对不上号就丢弃，不覆盖用户暂停/新拖动/新层。
    private var seekToken: UInt64 = 0
    private var hideTask: Task<Void, Never>?
    /// 加载超时兜底：15 秒未出帧即按失败走切线（KSPlayer 有些失败只停住
    /// 不调 finish，不能让界面永远卡在“正在解析播放线路…”）。
    private var loadTimeoutTask: Task<Void, Never>?
    private var playerLayer: KSPlayerLayer?
    /// delegate 转接对象（KSPlayerLayer 的 delegate 是弱引用，controller
    /// 强持有，层活着它就活着；换层/拆层时释放）。
    private var layerDelegate: SoftDecoderLayerDelegate?
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        // 线路表是后台慢慢补的（loadResource），变了就重算画质选项（与原生同款）。
        viewModel.$lines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshQualityOptions() }
            .store(in: &cancellables)
        // 引擎监听（与 CustomPlayerController.init 同款）：currentEngine 一变就跟进。
        // 同一 URL 换引擎时 .onChange(of: currentURL) 不触发，全靠这里重建；
        // 同 URL 手动重试/重播也靠它把 playGeneration 的变化送进来（load 的去重
        // 条件认代际与失败态，见 load()）。load() 内有引擎门控：切走非软解引擎
        // 时走 teardown，不会误建层。
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
        hideTask?.cancel()
        loadTimeoutTask?.cancel()
        playerLayer?.stop()
    }

    // MARK: - 换片与自动播

    /// 新 URL 到达时调（SoftDecoderPlayerView 传进来的 currentURL/headers 变化）。
    /// URL/请求头没变不重建，避免 SwiftUI 刷新打断正在播的片。
    /// 非软解引擎不归 KSPlayer：拆层（视图只在 .softDecoder 时挂载；
    /// 引擎切走时视图卸载也会调 teardown，这里是第二道）。
    func load(url: URL?, headers: [String: String]?) {
        guard viewModel.currentEngine == .softDecoder else {
            teardown()
            return
        }
        guard let url else {
            lastURL = nil
            lastHeaders = nil
            teardownLayer()
            isPlaying = false
            isLoading = false
            currentTime = 0
            duration = 0
            bufferedEnd = 0
            return
        }
        guard lastURL != url || lastHeaders != headers
            || viewModel.playGeneration != lastGeneration || didMarkFailedURL != nil else { return }
        // 新片/新一集（generation 变了）从 0:00 起；同片切线保当前进度。
        let generation = viewModel.playGeneration
        let isNewSession = generation != lastGeneration
        lastGeneration = generation
        var resumeAt: Double = 0
        if !isNewSession, currentTime > 1 {
            resumeAt = currentTime
        }
        shouldPlay = true
        lastURL = url
        lastHeaders = headers
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        isLoading = true
        currentTime = 0
        duration = 0
        bufferedEnd = 0
        refreshQualityOptions()
        buildLayer(url: url, headers: headers, resumeAt: resumeAt)
    }

    /// 建新层：旧层先停掉释放；新层用 SoftDecoderSupport 的选项
    /// （Referer/UA/头、续播点、硬解优先、不注册远程控制）。
    /// KSPlayerLayer(url:options:delegate:) 的签名见官方示例原文。
    private func buildLayer(url: URL, headers: [String: String]?, resumeAt: Double) {
        // 新层：旧 seek 回调作废（代际+1），在途标志清掉。
        seekToken &+= 1
        isSeeking = false
        teardownLayer()
        let options = SoftDecoderSupport.makeOptions(headers: headers, startPlayTime: resumeAt)
        let delegate = SoftDecoderLayerDelegate(controller: self)
        let layer = KSPlayerLayer(url: url, options: options, delegate: delegate)
        layerDelegate = delegate
        playerLayer = layer
        layerRevision += 1
        layer.prepareToPlay()
        scheduleLoadTimeout()
    }

    /// 拆层（换片/停播时调）：停播销毁，不后台继续播；画面 view 一并摘掉。
    private func teardownLayer() {
        // 拆层：旧 seek 回调作废（代际+1），在途标志清掉（回调永不回来也不卡住）。
        seekToken &+= 1
        isSeeking = false
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        playerLayer?.player.view?.removeFromSuperview()
        playerLayer?.stop()
        playerLayer = nil
        layerDelegate = nil
    }

    /// 15 秒未出帧即按失败走切线。只认当前 URL（换片后旧任务不烧新片）。
    private func scheduleLoadTimeout() {
        loadTimeoutTask?.cancel()
        guard let url = lastURL else { return }
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.didMarkPlayingURL != url, self.lastURL == url {
                self.handleFatalError("软解播放器加载超时（15 秒未出帧）")
            }
        }
    }

    // MARK: - KSPlayerLayerDelegate 回调（经 SoftDecoderLayerDelegate 转接）

    /// 状态变化：只认当前层（旧层残留的回调不算数）。
    /// .readyToPlay 时补一次 play()（isAutoPlay=true 是第一道，就绪回调是第二道，
    /// 与原生“就绪后再 play”的双保险同源）；其余状态只认 isPlaying，不枚举
    /// 其他 case（见文件头：除 .readyToPlay 与 isPlaying 外不依赖任何 case）。
    func handleState(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === playerLayer else { return }
        if state == .readyToPlay {
            // 层就绪也可能换出新 player.view：递增代际，画面 view 重新挂载。
            layerRevision += 1
            if shouldPlay { layer.play() }
            return
        }
        let playing = state.isPlaying
        isPlaying = playing
        if playing {
            isLoading = false
            loadTimeoutTask?.cancel()
            // 真正出帧 → markPlaying（“正在解析播放线路…”由此消失）。
            if let url = lastURL, didMarkPlayingURL != url {
                didMarkPlayingURL = url
                viewModel.markPlaying()
            }
            showControlsTemporarily()
        } else {
            // 没在播：用户想播（shouldPlay）且片还在 → 等缓冲/加载中（转圈）；
            // 用户点了暂停 → 不转圈，控制条常显。
            isLoading = shouldPlay && lastURL != nil
            if !shouldPlay { controlsVisible = true }
        }
    }

    /// 进度回调：直接记当前时间与总时长（与原生周期观察同义）。
    /// 拖动中不回写（KSPlayer 还没 seek 完，回写会把用户刚拖到的时间 snap 回旧时间）。
    func handleTime(currentTime: TimeInterval, totalTime: TimeInterval) {
        guard !isScrubbing, !isSeeking else { return }
        self.currentTime = currentTime
        if totalTime.isFinite, totalTime > 0 { duration = totalTime }
    }

    /// 缓冲回调：bufferedCount 是 KSPlayer 回传的已缓冲秒数（整秒），
    /// bufferedCount == 0 表示首次加载（README 的 PlayerControllerDelegate
    /// 注释原话）。进度条浅灰段用它估算，只进不退；这是估算值，不是
    /// AVPlayer 的 loadedTimeRanges 精确值——外观一致即可，不宣称精确。
    func handleBuffered(count: Int, consumeTime: TimeInterval) {
        if count > 0 {
            bufferedEnd = max(bufferedEnd, Double(count))
        }
    }

    /// 播完/失败：error 非空=失败（走 markFailed 切线）；空=自然播完，
    /// 停在 0:00（不循环、不续播），控制条常显，等用户再点播放（与原生一致）。
    func handleFinish(layer: KSPlayerLayer, error: Error?) {
        guard layer === playerLayer else { return }
        if let error {
            handleFatalError("软解播放失败（\(error.localizedDescription)）")
            return
        }
        // 自然播完：用户意图 = 不播。不清 shouldPlay 的话，层下次就绪
        // （handleState .readyToPlay 里 `if shouldPlay { layer.play() }`）
        // 会自己播起来，违背“不自动续播”铁律。
        shouldPlay = false
        isPlaying = false
        isLoading = false
        controlsVisible = true
        currentTime = 0
        // 2.3.4 实测：KSPlayerLayer 只有 seek(time:autoPlay:completion:)，
        // 单参 seek(time:) 是 internal，调不到。自然播完停在 0:00，
        // autoPlay 必须 false（不能播完又自己播起来）。
        playerLayer?.seek(time: 0, autoPlay: false) { _ in }
    }

    /// fatal 级失败：同一条 URL 只认一次（finish 与超时兜底可能先后都到），
    /// 调 viewModel.markFailed 走正常切线。
    func handleFatalError(_ message: String) {
        guard let url = lastURL, didMarkFailedURL != url else { return }
        didMarkFailedURL = url
        loadTimeoutTask?.cancel()
        viewModel.markFailed(message, failedURL: url)
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
        playerLayer?.pause()
        controlsVisible = true
    }

    func playByUser() {
        shouldPlay = true
        playerLayer?.play()
        showControlsTemporarily()
    }

    /// 开始拖进度条：记下拖之前用户是不是想播，拖动期间先停播（seek 干净不卡）。
    /// 用 shouldPlay（用户意图）记，不用 isPlaying（瞬时状态）：
    /// 播着的片在等缓冲时会短暂不 playing，用它记就会把“在播”记成“暂停”，
    /// 松手不续播；shouldPlay 只有用户点暂停才变 false（与原生同款）。
    func beginScrub() {
        isScrubbing = true
        // 新拖动：旧的松手 seek 回调作废（代际+1），在途标志清掉。
        seekToken &+= 1
        isSeeking = false
        wasPlayingBeforeScrub = shouldPlay
        hideTask?.cancel()
        controlsVisible = true
        playerLayer?.pause()
    }

    /// 拖动中：只改本地 currentTime（进度条跟手），不向 KSPlayer 发 seek——
    /// 拖动是 60Hz 的连续调用，每帧都 seek 会把 FFmpeg 轰炸到卡死；
    /// 真正的 seek 只在松手时发一次（与原生/嵌页探针同款）。
    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
    }

    /// 松手：精确定位到拖到的位置；拖之前在播就恢复播放（不拖完停在暂停态）。
    func endScrub(to seconds: Double) {
        // 先清拖动标志再判时长：duration <= 0 早退也不能把 isScrubbing 落下，
        // 否则进度条永久冻结。
        isScrubbing = false
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        let resume = wasPlayingBeforeScrub
        // 意图提前在发起 seek 时写入：seek 途中用户点暂停会把 shouldPlay 改 false，
        // 回调按最新意图决定，不强行续播。
        shouldPlay = resume
        seekToken &+= 1
        let token = seekToken
        guard let layer = playerLayer else {
            isSeeking = false
            return
        }
        // isScrubbing 已清、isSeeking 接棒拦 handleTime：seek 没落点前进度条
        // 锁在拖到的目标不动，不弹回旧位置。
        isSeeking = true
        // autoPlay 必须 false：续播由 seek 完成回调里显式决定，不能让 seek 自己播
        //（否则拖之前是暂停也会被播起来）；seek 是异步的，play() 必须等 seek
        // 完成回调后再发，立即 play 会从旧位置先播一截再跳，与 seek 抢跑
        //（与原生 playByUser 在 seek 在途时不直接 play 同源）。
        layer.seek(time: clamped, autoPlay: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                // 代际/层身份双校验：旧回调（用户已暂停/新拖动/切线换层）直接丢弃。
                guard let self, self.seekToken == token, self.playerLayer === layer else { return }
                self.isSeeking = false
                guard !self.isScrubbing, self.shouldPlay else { return }
                layer.play()
                self.showControlsTemporarily()
            }
        }
    }

    // MARK: - 画质

    /// 与原生同款：从 viewModel.lines 推导画质选项（切画质=切线路，
    /// 同片同 generation 保当前进度，不回 0:00）。
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

    // MARK: - 画面挂载与控制条显隐、全屏、停播

    /// 把当前层的画面 view 挂到指定容器（内嵌/全屏二选一，由 isFullscreen 门控）。
    /// 内嵌容器与全屏容器同时存在（全屏是 overFullScreen 盖上去，底下详情页
    /// 不卸载），只有与 isFullscreen 一致的那边才挂画面，另一边摘掉；
    /// 同一个 view 在两个容器间搬家，不重建层、不重播、不丢进度。
    func attachVideoView(to container: UIView, fullscreenContainer: Bool) {
        guard let layer = playerLayer, let videoView = layer.player.view else { return }
        let shouldAttach = (fullscreenContainer == isFullscreen)
        if shouldAttach {
            if videoView.superview !== container {
                videoView.removeFromSuperview()
                videoView.frame = container.bounds
                videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.addSubview(videoView)
            }
        } else if videoView.superview === container {
            videoView.removeFromSuperview()
        }
    }

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

    /// 离页停播：停层销毁 + 状态复位。幂等（onDisappear 与引擎切走都会调）。
    /// 全屏开着时一并关掉全屏 VC（失败切线可能让引擎先切走、视图先卸载，
    /// 全屏 VC 是盖在顶层的模态，不主动关会飘在详情页上面播黑屏）。
    /// URL/代际记忆也清掉：同 URL 重挂载时 load() 的去重 guard 才不会
    /// 把“层已拆、需重建”误判成“没变、不重建”。
    func teardown() {
        hideTask?.cancel()
        hideTask = nil
        teardownLayer()
        if isFullscreen {
            isFullscreen = false
            SoftDecoderFullscreenPresenter.dismissActive()
        }
        lastURL = nil
        lastHeaders = nil
        lastGeneration = nil
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        bufferedEnd = 0
    }
}

// MARK: - KSPlayerLayerDelegate 转接

/// KSPlayerLayer 的 delegate 回调不一定在主线程跑（KSPlayer 内部线程），
/// 这里只做转接：收到就 hop 到 @MainActor 再调 controller 的处理方法，
/// 与 CustomPlayerController 把 KVO 回调包进 Task { @MainActor in … }
/// 的做法同源。四个方法签名照 KSPlayerLayerDelegate 的文档示例逐字写。
final class SoftDecoderLayerDelegate: NSObject, KSPlayerLayerDelegate {
    weak var controller: SoftDecoderPlayerController?

    init(controller: SoftDecoderPlayerController) {
        self.controller = controller
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        Task { @MainActor [weak self] in
            self?.controller?.handleState(layer: layer, state: state)
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        Task { @MainActor [weak self] in
            self?.controller?.handleTime(currentTime: currentTime, totalTime: totalTime)
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        Task { @MainActor [weak self] in
            self?.controller?.handleFinish(layer: layer, error: error)
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        Task { @MainActor [weak self] in
            self?.controller?.handleBuffered(count: bufferedCount, consumeTime: consumeTime)
        }
    }
}

// MARK: - KSPlayer 画面的 UIView 容器

/// 只负责装画面：黑底容器，画面 view 由 controller.attachVideoView 挂进来。
/// 换片不重建容器（层在 controller 手里换，画面 view 搬家即可）。
struct SoftDecoderKSView: UIViewRepresentable {
    let controller: SoftDecoderPlayerController
    /// true=全屏容器，false=内嵌容器（门控见 attachVideoView）。
    let isFullscreenContainer: Bool
    /// 画面层代际（controller.layerRevision）：值变了 SwiftUI 才会调
    /// updateUIView；只传 controller 时是同对象引用，值比对恒相等。
    let layerRevision: Int
    /// 全屏状态值（controller.isFullscreen）：退出全屏时值变了才会调
    /// updateUIView，把画面 view 从全屏容器搬回内嵌容器。
    let isFullscreen: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 只在代际或全屏状态变化时重挂：每次调用都无条件重建 view
        // 会打断正在播的画面。首调时 coordinator 里的旧值为 nil，必挂一次。
        if context.coordinator.lastLayerRevision != layerRevision
            || context.coordinator.lastIsFullscreen != isFullscreen {
            context.coordinator.lastLayerRevision = layerRevision
            context.coordinator.lastIsFullscreen = isFullscreen
            controller.attachVideoView(to: uiView, fullscreenContainer: isFullscreenContainer)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // 容器销毁时把画面 view 摘掉（层还在 controller 手里，全屏/切线时还会再挂）。
        uiView.subviews.forEach { $0.removeFromSuperview() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastLayerRevision: Int?
        var lastIsFullscreen: Bool?
    }
}

// MARK: - 软解播放器（SwiftUI：KSPlayerLayer + 同一套底条，16:9 内嵌）

/// 软解播放器：KSPlayerLayer（FFmpeg）播 viewModel.currentURL
///（.mkv/.flv/.avi/.webm 等 AVPlayer 播不了的封装/编码，或无 dash.js 时的 .mpd）。
/// 构造契约：`SoftDecoderPlayerView(viewModel: PlayerViewModel)`。
/// 外观与原生播放器一致：16:9 内嵌在详情页顶部小窗口，不弹全屏；全屏靠底条上的
/// 全屏按钮（横屏呈现，退出回原位）。离开页面 onDisappear 即停播。
struct SoftDecoderPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// 全屏状态上行到 DetailView：与 .webView 的 onFullscreenChange 同款回调模式，
    /// DetailView 接上后与 CustomPlayerView / .webView 共用同一个 @State isFullscreen，
    /// 靠它判断 onDisappear 是不是全屏引起的。
    var onFullscreenChange: ((Bool) -> Void)? = nil

    @StateObject private var controller: SoftDecoderPlayerController

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        _controller = StateObject(wrappedValue: SoftDecoderPlayerController(viewModel: viewModel))
    }

    var body: some View {
        ZStack {
            SoftDecoderKSView(controller: controller, isFullscreenContainer: false, layerRevision: controller.layerRevision, isFullscreen: controller.isFullscreen)
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
        .onAppear { controller.load(url: viewModel.currentURL, headers: viewModel.currentHeaders) }
        .onChange(of: viewModel.currentURL) { _, newURL in controller.load(url: newURL, headers: viewModel.currentHeaders) }
        .onChange(of: viewModel.currentHeaders) { _, newHeaders in controller.load(url: viewModel.currentURL, headers: newHeaders) }
        .onChange(of: controller.isFullscreen) { _, fullscreen in
            // 全屏状态同步给 DetailView（与 WebViewPlayerView 的
            // .onChange(of: probe.isFullscreen) 同款；放 present 之前，进出都报）。
            onFullscreenChange?(fullscreen)
            if fullscreen {
                SoftDecoderFullscreenPresenter.present(
                    controller: controller,
                    viewModel: viewModel
                ) {
                    controller.isFullscreen = false
                }
            }
        }
        // 全屏时不拆：与 HLSJS/DASH 同款 guard。正常进全屏是 overFullScreen 模态，
        // 不触发这里；引擎切走导致视图卸载时跳过，拆层走 controller 的
        // $currentEngine 订阅 → load() → teardown()，全屏模态由 teardown()
        // 里的 dismissActive() 关，不会飘在上面。
        // 引擎已切走且全屏还开着：视图卸载后 .onChange(of: controller.isFullscreen)
        // 已失效，controller 随后回 false 也传不上去，DetailView 的 isFullscreen
        // 会卡 true，离页 guard !isFullscreen 阻断停播。只在引擎已切走时清；
        // 正常全屏进出时引擎仍是本播放器，条件不成立，不误清。
        .onDisappear {
            if viewModel.currentEngine != .softDecoder && controller.isFullscreen { onFullscreenChange?(false) }
            if !controller.isFullscreen { controller.teardown() }
        }
    }
}

// MARK: - 全屏呈现（横屏，同一 KSPlayerLayer、同一 controller）

/// 全屏版播放器内容：同一层、同一 controller、同一套底条，只是铺满横屏
///（全屏按钮显示“退出全屏”图标）。画面 view 由门控从内嵌容器搬过来。
struct SoftDecoderFullscreenContent: View {
    @ObservedObject var controller: SoftDecoderPlayerController
    let viewModel: PlayerViewModel
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SoftDecoderKSView(controller: controller, isFullscreenContainer: true, layerRevision: controller.layerRevision, isFullscreen: controller.isFullscreen)
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
/// 退出后内嵌播放器还在同一进度（同一 KSPlayerLayer、同一 controller）。
/// 与原生全屏同款：overFullScreen（不是 fullScreen），盖全屏时底下的详情页
/// 不从层级里摘掉，DetailView 的 onDisappear/onAppear 不触发，播放器不被拆、不重播。
final class SoftDecoderFullscreenViewController: UIViewController {
    private let controller: SoftDecoderPlayerController
    private let viewModel: PlayerViewModel
    private let onExit: () -> Void

    init(controller: SoftDecoderPlayerController, viewModel: PlayerViewModel, onExit: @escaping () -> Void) {
        self.controller = controller
        self.viewModel = viewModel
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
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
        let content = SoftDecoderFullscreenContent(controller: controller, viewModel: viewModel, onExit: { [weak self] in
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

/// 全屏呈现器：从最顶层控制器 present 横屏全屏播放器（与原生同款写法）。
/// 整体 @MainActor：topViewController() 直接访问 UIApplication.shared，
/// activeVC 是 static weak var，非隔离会有 Swift 6 隔离违规。
@MainActor
enum SoftDecoderFullscreenPresenter {
    private static weak var activeVC: SoftDecoderFullscreenViewController?

    @MainActor
    static func present(controller: SoftDecoderPlayerController, viewModel: PlayerViewModel, onExit: @escaping () -> Void) {
        // 拿不到顶层控制器（转场/退后台瞬间）：直接调 onExit 把 isFullscreen
        // 复位，不然 isFullscreen 一直 true、内嵌容器又把画面摘了，只剩黑屏。
        guard let top = topViewController() else {
            onExit()
            return
        }
        // 已经在全屏里：不调 onExit（调了会把 isFullscreen 复位，全屏 VC 还在上面，
        // 画面门控会把 video view 从全屏容器摘掉，反而黑屏），直接返回。
        if top is SoftDecoderFullscreenViewController { return }
        let vc = SoftDecoderFullscreenViewController(controller: controller, viewModel: viewModel, onExit: onExit)
        activeVC = vc
        top.present(vc, animated: true, completion: nil)
    }

    /// 引擎切走/离页时主动关掉还开着的全屏（teardown 调；退出按钮走 VC
    /// 自己的 onExit，不走这里，不会重复关）。
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

#else

// MARK: - KSPlayer 未接入时的占位（构建不坏）
//
// hasSoftwareDecoder 为 false 时路由表不会选软解，本分支基本走不到；
// 万一走到（如 .mpd 无 dash.js 又无软解时路由仍返回 .dash，不走这里），
// 显示与原来占位视图同一文案的提示，不静默空白。
struct SoftDecoderPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// 与主分支同款签名（无 KSPlayer 时 DetailView 的调用也要能编译；占位无全屏，不调用）。
    var onFullscreenChange: ((Bool) -> Void)? = nil

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Text("该视频编码需要软解播放器，暂未集成")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
