import Combine
import SwiftUI
import WebKit

// MARK: - 真 HLS.js 播放器（B 路）
//
// 定位（2026-11-25 追补后的路由顺序）：hlsjs hint 的首选引擎——
// PlaybackCapabilities.hasHLSJS 为 true 时路由优先走这里；hls.js 失败才回退到
// Native HLS 兼容实现（AVPlayer + AVAssetResourceLoaderDelegate，即 A 路拦截器），
// 只回退一步，不循环（回退由 A 路的 markFailed 负责，本文件只负责报失败）。
// “拦截器那条”在本文件及交回里一律叫 Native HLS 兼容实现，不叫 hls.js。
//
// 为什么首选 hls.js 而不是拦截器（Claude + ChatGPT 两轮新证据）：
// AVPlayer 只把 playlist（.m3u8）和 key（#EXT-X-KEY）交给
// AVAssetResourceLoaderDelegate，.ts 分片不经过 delegate——分片需要头时拦截器
// 覆盖不了（报 -12881）；hls.js 经 xhrSetup/fetchSetup 能给 playlist、key、
// 分片全套加头，这是 hls.js 相对拦截器的优势。代价是 hls.js 要 MSE +
// ManagedMediaSource（运行时探测把关），且 XHR 跨域要站方回 CORS 头。
//
// 外观与行为（与原生播放器一致，不发明新 UI）：
// 16:9 内嵌在详情页顶部小窗口，自绘底条复用 PlayerControlBar（播放/暂停、
// 进度条、时间、画质菜单、全屏）；不用 AVPlayerViewController，不触发系统
// Now Playing（无灵动岛）；不走 AirPlay、不开画中画；每次新片/新一集从 0:00 起播，
// 不自动续播；同片切线保当前进度；失败调 viewModel.markFailed 自动切线；
// 离页停播（onDisappear/dismantle 销毁 Hls 实例 + 停 WebView，不后台继续播）。
// automaticallyWaitsToMinimizeStalling=true 只约束 AVPlayer，本播放器是 WebView，
// 不要去碰它；缓冲由 hls.js 自己管（maxBufferLength 30 秒），ABR 不如原生，
// 这是 hls.js 的固有弱点，注释里写明、不粉饰。
//
// 请求头（viewModel.currentHeaders，A 路的 interceptedHeaders 拼好：UA + Referer +
// 模块自定义头 + Cookie）：
// - Referer / User-Agent / Cookie 是浏览器的禁设头，xhrSetup 里 setRequestHeader
//   会被静默忽略，所以：Referer 靠文档 URL（baseURL=流地址本身，见 load 的注释），
//   UA 靠 WKWebView.customUserAgent，Cookie 靠 xhr.withCredentials + WebView 的 cookie jar。
// - 其余头（如 Authorization、x-cdn-auth）由 xhrSetup/fetchSetup 原样透传给
//   playlist/key/分片全部请求。
// - CORS 边界：hls.js 用 XHR 读播单，跨域时站方必须回 Access-Control-Allow-Origin；
//   所以 baseURL 必须是流地址本身（同源），不能是帖页——否则连播单都读不到。
//   需要帖页 Referer 的站仍可能拒，这是 hls.js 路的已知边界。

// MARK: - 控制器（状态机，对标 CustomPlayerController）

/// HLS.js 播放器的状态机（ObservableObject，@MainActor）。
/// 只管 WebView 里的 Hls 实例：换片、自动播、播放/暂停、快进、画质、缓冲、失败上报、
/// 全屏与控制条显隐。线路、路由、markPlaying/markFailed 仍走 PlayerViewModel，
/// 这里不重写。播放状态以页内 video 元素的事件为准（playing/paused/waiting），
/// 不用本地旗子猜——与原生播放器“状态跟真实 timeControlStatus”的做法同源。
@MainActor
final class HLSJSPlayerController: ObservableObject {
    let viewModel: PlayerViewModel

    /// 真实播放状态：页内 video 出 'playing' 事件才为 true（按钮据此显示暂停/播放）。
    @Published var isPlaying = false
    /// 当前播放秒数（timeupdate 回传；拖进度条时由 scrub 直接改，松手后 timeupdate 接管）。
    @Published var currentTime: Double = 0
    /// 总时长秒数（未知为 0）。
    @Published var duration: Double = 0
    /// 已缓冲到的秒数（video.buffered 末端，进度条浅灰段）。
    @Published var bufferedEnd: Double = 0
    /// 正在等数据/缓冲（画面中央转圈；与 PlayerControlBar 的 isBuffering 同义）。
    @Published var isLoading = false
    /// 控制条是否可见（播时 3 秒无操作自动藏，暂停时常显，点画面切换）。
    @Published var controlsVisible = true
    /// 是否在全屏（JS 的 fullscreenchange 事件回传，按钮图标据此切全屏/退出全屏）。
    @Published var isFullscreen = false
    /// 画质选项（从 hls.levels 推导）与当前档位。
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
    /// 同片切线时要恢复的进度（秒；新会话为 0）。
    private var lastResumeAt: Double = 0
    private var didMarkPlayingURL: URL?
    private var didMarkFailedURL: URL?
    /// 拖进度条前是不是在播（松手后据此恢复）。
    private var wasPlayingBeforeScrub = false
    private var hideTask: Task<Void, Never>?
    /// JS 报上来的清晰度档位（去重前）；画质菜单由它生成。
    private var levels: [WebPlayerLevel] = []
    /// 当前是不是自动档（hls.currentLevel == -1 时为 true，由 levels 消息同步）。
    private var isAutoQuality = true
    /// 拖动中（PlayerControlBar 每帧调 scrub）：拖动时只改本地 currentTime，
    /// 不向页内狂发 seek；timeupdate 回写也暂停，松手 endScrub 一次 seek。
    private var isScrubbing = false
    /// 加载超时兜底：15 秒未出帧即按失败走切线（与软解同款；hls.js 有些失败
    /// 只停住不报 ERROR，不能让界面永远卡在“正在解析播放线路…”）。
    private var loadTimeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// WKWebView 的持有者（EmbedProbeState.webView 同款写法：VC 建好后指回来，
    /// 弱引用，不成环；Swift 侧的 play/pause/seek/画质/全屏都经它 evaluateJavaScript）。
    weak var webViewController: HLSJSWebViewController?

    /// VC 刚建好时补首播用的待播地址（load() 可能比 VC 建好更早到，
    /// viewDidLoad 里用这三个值补一次，load() 到了就是同一 URL，不重复建页）。
    var pendingURL: URL? { lastURL }
    var pendingHeaders: [String: String]? { lastHeaders }
    var pendingResumeAt: Double { lastResumeAt }

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        // 引擎监听（与 CustomPlayerController.init 同款）：currentEngine 一变就跟进。
        // 同一 URL 换引擎时 .onChange(of: currentURL) 不触发，全靠这里重建；
        // 同 URL 手动重试/重播也靠它把 playGeneration 的变化送进来（load 的去重
        // 条件认代际与失败态，见 load()）。
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
    }

    deinit {
        hideTask?.cancel()
        loadTimeoutTask?.cancel()
    }

    // MARK: - 换片与自动播

    /// 新 URL 到达时调（HLSJSPlayerView 传进来的 currentURL/headers 变化）。
    /// URL/请求头没变不重建，避免 SwiftUI 刷新打断正在播的片。
    func load(url: URL?, headers: [String: String]?) {
        // run #36 R3（P1-1）：引擎门控——切离 .hlsjs 时不重建。teardown 只拆
        // 本控制器的 VC 与自有状态（VC 与 controller 一一对应），不碰新引擎资源。
        guard viewModel.currentEngine == .hlsjs else {
            teardown()
            return
        }
        guard let url else {
            lastURL = nil
            lastHeaders = nil
            lastResumeAt = 0
            webViewController?.load(url: nil, headers: nil, resumeAt: 0, forceReload: true)
            return
        }
        // run #36 P0-12：去重条件须纳入代际与失败态，否则同 URL/头的
        // 手动重试或同分集重播（playGeneration 已换）会直接早退，status
        // 永久卡在“正在解析播放线路…”。
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
        lastResumeAt = resumeAt
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        isLoading = true
        currentTime = 0
        duration = 0
        bufferedEnd = 0
        levels = []
        qualityOptions = []
        currentQualityLabel = "自动"
        isAutoQuality = true
        webViewController?.load(url: url, headers: headers, resumeAt: resumeAt, forceReload: true)
        scheduleLoadTimeout()
    }

    /// 15 秒未出帧即按失败走切线（与软解同款）。只认当前 URL（换片后旧任务不烧新片）。
    private func scheduleLoadTimeout() {
        loadTimeoutTask?.cancel()
        guard let url = lastURL else { return }
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.didMarkPlayingURL != url, self.lastURL == url {
                self.handleFatalError("HLS.js 播放器加载超时（15 秒未出帧）")
            }
        }
    }

    // MARK: - JS 消息（WKScriptMessageHandler 转交）

    /// 页内 JS 桥的消息：timeupdate/progress/playing/paused/waiting/ended/
    /// fullscreen/levels/levelswitched/error。internal：VC 的消息回调调它。
    func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "timeupdate", "progress":
            // 拖动中不回写 currentTime（页内 video 还没 seek 完，回写会把用户
            // 刚拖到的时间又 snap 回旧时间；与原生 isScrubbing 门控同源）。
            if !isScrubbing, let t = Self.doubleValue(message["t"]) { currentTime = t }
            if let d = Self.doubleValue(message["d"]), d.isFinite, d > 0 { duration = d }
            if let b = Self.doubleValue(message["buffered"]), b.isFinite, b >= 0 {
                // JS 的 bufferedEnd() 已返回含 currentTime 的那个区间之 end，
                // 直接赋值；旧的 max() 会让回拖后缓冲条卡在高点不回落。
                bufferedEnd = b
            }
        case "playing":
            isPlaying = true
            isLoading = false
            loadTimeoutTask?.cancel()
            // 真正出帧 → markPlaying（“正在解析播放线路…”由此消失）。
            if let url = lastURL, didMarkPlayingURL != url {
                didMarkPlayingURL = url
                viewModel.markPlaying()
            }
            showControlsTemporarily()
        case "play":
            // 'play' 只表示调了 play()、未出帧：不等同在播，不提前置 isPlaying；
            // 真正出帧的 'playing' 事件才置 true（按钮据此显示暂停/播放）。
            break
        case "paused":
            isPlaying = false
            controlsVisible = true
        case "waiting":
            // 等数据/缓冲：不算在播（按钮显示“播放”由 isLoading 的转圈代替），画面转圈。
            isPlaying = false
            isLoading = true
        case "ended":
            // 播到片尾：停在 0:00（不循环、不续播），控制条常显，等用户再点播放。
            isPlaying = false
            // 不清 shouldPlay 的话，片尾拖进度条松手会按旧意图自动续播。
            shouldPlay = false
            controlsVisible = true
            currentTime = 0
            evaluate("if (window.__webplayer) { window.__webplayer.seek(0); }")
        case "fullscreen":
            isFullscreen = (message["value"] as? Bool) ?? false
        case "levels":
            refreshLevels(from: message)
        case "levelswitched":
            if let index = Self.intValue(message["index"]) {
                updateCurrentQuality(index: index)
            }
        case "error":
            let detail = (message["message"] as? String) ?? "播放失败"
            handleFatalError(detail)
        default:
            break
        }
    }

    /// fatal 级失败：同一条 URL 只认一次（ERROR 事件与导航失败可能先后都到），
    /// 调 viewModel.markFailed 走正常切线。internal：VC 的导航失败回调也调它。
    func handleFatalError(_ message: String) {
        guard let url = lastURL, didMarkFailedURL != url else { return }
        didMarkFailedURL = url
        loadTimeoutTask?.cancel()
        viewModel.markFailed(message, failedURL: url)
    }

    // MARK: - 画质

    private func refreshLevels(from message: [String: Any]) {
        guard let rawLevels = message["levels"] as? [[String: Any]] else { return }
        var parsed: [WebPlayerLevel] = []
        for raw in rawLevels {
            guard let index = Self.intValue(raw["index"]),
                  let height = Self.intValue(raw["height"]),
                  let bitrate = Self.intValue(raw["bitrate"]) else { continue }
            parsed.append(WebPlayerLevel(index: index, height: height, bitrate: bitrate))
        }
        levels = parsed
        if let current = Self.intValue(message["current"]) {
            isAutoQuality = current < 0
        }
        rebuildQualityOptions()
        if let current = Self.intValue(message["current"]) {
            updateCurrentQuality(index: current)
        }
    }

    private func rebuildQualityOptions() {
        guard let base = lastURL?.absoluteString else {
            qualityOptions = []
            return
        }
        // 同一高度只留码率最高的一档（hls.js 常给同一高度多码率变体）。
        var bestByLabel: [String: WebPlayerLevel] = [:]
        for level in levels {
            guard let label = videoQualityLabel(height: level.height) else { continue }
            if let existing = bestByLabel[label] {
                if level.bitrate > existing.bitrate { bestByLabel[label] = level }
            } else {
                bestByLabel[label] = level
            }
        }
        var options: [QualityOption] = []
        // “自动”档永远在第一位（hls.currentLevel = -1）。
        let autoURL = base + "#hlsjs-level-auto"
        options.append(QualityOption(
            id: autoURL,
            label: "自动",
            line: PlayLine(name: "自动", url: autoURL, description: "自动")
        ))
        // 其余档按高度从高到低排。
        let sorted = bestByLabel.values.sorted { $0.height > $1.height }
        for level in sorted {
            guard let label = videoQualityLabel(height: level.height) else { continue }
            let url = base + "#hlsjs-level-\(level.index)"
            options.append(QualityOption(id: url, label: label, line: PlayLine(name: label, url: url, description: label)))
        }
        qualityOptions = options
    }

    private func updateCurrentQuality(index: Int) {
        if index < 0 {
            isAutoQuality = true
            currentQualityLabel = "自动"
            return
        }
        isAutoQuality = false
        if let level = levels.first(where: { $0.index == index }),
           let label = videoQualityLabel(height: level.height) {
            currentQualityLabel = label
        }
    }

    /// 画质切换：只动 hls.js 的 currentLevel，绝不调 viewModel.switchLine。
    /// QualityOption 里那条 PlayLine 的 URL 是合成的（“…#hlsjs-level-N”），
    /// 只是为了给菜单一个唯一的 id / label，拿去切线会播一个不存在的地址。
    /// 原生播放器切画质 = 切线路（option.line 是真线路），这里不是——不要照搬。
    func selectQuality(_ option: QualityOption) {
        if option.label == "自动" {
            isAutoQuality = true
            currentQualityLabel = "自动"
            evaluate("if (window.__webplayer) { window.__webplayer.setLevel(-1); }")
            showControlsTemporarily()
            return
        }
        // 按 label 找回档位：同一高度常有多码率变体，first 会撞上低码率档；
        // 取同 label 里码率最高的那档（与 rebuildQualityOptions 的去重一致）。
        guard let level = levels.filter({ videoQualityLabel(height: $0.height) == option.label }).max(by: { $0.bitrate < $1.bitrate }) else { return }
        isAutoQuality = false
        currentQualityLabel = option.label
        evaluate("if (window.__webplayer) { window.__webplayer.setLevel(\(level.index)); }")
        showControlsTemporarily()
    }

    // MARK: - 播放 / 暂停 / 快进 / 全屏

    func togglePlayPause() {
        if isPlaying {
            pauseByUser()
        } else {
            playByUser()
        }
    }

    func pauseByUser() {
        shouldPlay = false
        evaluate("if (window.__webplayer) { window.__webplayer.pause(); }")
        controlsVisible = true
    }

    func playByUser() {
        shouldPlay = true
        evaluate("if (window.__webplayer) { window.__webplayer.play(); }")
        showControlsTemporarily()
    }

    /// 开始拖进度条：记下拖之前用户是不是想播，拖动期间先停播（seek 干净不卡）。
    func beginScrub() {
        isScrubbing = true
        wasPlayingBeforeScrub = shouldPlay
        hideTask?.cancel()
        controlsVisible = true
        evaluate("if (window.__webplayer) { window.__webplayer.pause(); }")
    }

    /// 拖动中：只改本地 currentTime（进度条跟手），不向页内发 seek——
    /// 拖动是 60Hz 的连续调用，每帧都 seek 会把 hls.js 轰炸到卡死；
    /// 真正的 seek 只在松手时发一次（与原生/嵌页探针同款）。
    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
    }

    /// 松手：精确定位到拖到的位置；拖之前在播就恢复播放（不拖完停在暂停态）。
    func endScrub(to seconds: Double) {
        // 先清拖动标志再判时长：duration <= 0 早退也不能把 isScrubbing 落下，
        // 否则 timeupdate 回写永久被拦、进度条冻结。
        isScrubbing = false
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        let resume = wasPlayingBeforeScrub
        evaluate("if (window.__webplayer) { window.__webplayer.seek(\(clamped)); }")
        if resume {
            shouldPlay = true
            evaluate("if (window.__webplayer) { window.__webplayer.play(); }")
            showControlsTemporarily()
        }
    }

    /// 全屏：让页内 video 元素 requestFullscreen（WKWebView 原生接管全屏播放），
    /// 再点一次退出（document.exitFullscreen）。与 WebViewPlayer 的做法一致，
    /// 不用 SwiftUI 的 fullScreenCover（不用把 WKWebView 在层级间搬来搬去）。
    func toggleFullscreen() {
        evaluate("if (window.__webplayer) { window.__webplayer.fullscreen(); }")
    }

    // MARK: - 控制条显隐与停播

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

    /// 离页停播：销毁 Hls 实例 + 停 WebView（VC.teardown），状态复位。
    /// onDisappear 与 dismantle 都会调到这里/VC.teardown，VC 侧幂等。
    func teardown() {
        webViewController?.teardown()
        webViewController = nil
        hideTask?.cancel()
        hideTask = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        // 清掉 URL/代际/失败记忆：下次同 URL load 的去重 guard（lastURL == nil
        // 即通过）会重建，不会被拦；也不残留旧失败态误杀新线。
        lastURL = nil
        lastHeaders = nil
        lastGeneration = nil
        lastResumeAt = 0
        didMarkPlayingURL = nil
        didMarkFailedURL = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        bufferedEnd = 0
    }

    // MARK: - 小工具

    private func evaluate(_ script: String) {
        webViewController?.evaluate(script)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

// MARK: - WKWebView 宿主（只负责播，不带按钮）

/// HLS.js 播放器的 UIViewController：WKWebView 全铺，不带任何按钮。
/// 按钮/底条都在外层 SwiftUI（和直链自定义播放器同一套 PlayerControlBar）。
final class HLSJSWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIGestureRecognizerDelegate {
    let controller: HLSJSPlayerController
    private var webView: WKWebView?
    private var loadedURL: URL?
    private var loadedHeaders: [String: String]?
    /// Cookie 注入代际：每次 vc.load 递增，旧的异步注入回调对不上号就丢弃。
    private var loadToken: UInt64 = 0
    private var isTornDown = false

    init(controller: HLSJSPlayerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        // run #36 R3（P1-4）：非持久化 store——注入的 Cookie 只用于本次播放建页，
        // 不写进全局持久化库，跨片/跨站不污染其他 WebView；Cookie 每次 load 都
        // 从 headers 重新注入，不依赖跨页持久化。
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        // 画中画用户不要，关掉（与 WebViewPlayer 一致）。
        config.allowsPictureInPictureMediaPlayback = false
        // 允许自动播（详情页点封面进来即播，不用用户再点一下；与 WebViewPlayer 一致）。
        config.mediaTypesRequiringUserActionForPlayback = []
        // 第二层（代理层）拦弹窗：JS 不许自己开新窗口。
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "hlsjs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = NetConstants.iPhoneUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.webView = webView
        // 原生点按手势（系统级）：点画面切换底条显隐。
        // 绝不用 SwiftUI .onTapGesture——WKWebView 的内层手势会把它整个吃掉
        //（与 WebViewPlayer 同款做法）；两个手势同时识别，不抢播放器按钮。
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleWebViewTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        // controller.load() 可能比 VC 建好更早（$currentEngine 订阅在订阅瞬间即触发）：
        // 补一次，避免丢首播；forceReload: true——首载必须真的建页（见 vc.load 的 guard）。
        // onAppear 随后还会调一次 controller.load()，URL/代际相同、controller 侧
        // guard 会拦住，不重复建页。
        if let url = controller.pendingURL {
            load(url: url, headers: controller.pendingHeaders, resumeAt: controller.pendingResumeAt, forceReload: true)
        }
    }

    @objc private func handleWebViewTap() {
        Task { @MainActor in self.controller.toggleControls() }
    }

    // 绝不抢 WKWebView 内层手势（播放器按钮/进度条照常用）：两个手势同时识别。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// 换片/换线：URL 或请求头变了才重建页（同 URL 不重建，避免 SwiftUI 刷新打断播放）。
    /// resumeAt 只在同 generation 切线时 > 0，新片/新一集为 0，从 0:00 起播。
    func load(url: URL?, headers: [String: String]?, resumeAt: Double, forceReload: Bool = false) {
        guard !isTornDown else { return }
        // run #36 R3（P0-1）：webView 未建好时不写 loadedURL/loadedHeaders，
        // 否则 viewDidLoad 的首载补调会被去重 guard 拦住、页面永不建页。
        // （controller.load 已先把 lastURL 写好，pendingURL 不丢，viewDidLoad 会补调。）
        guard webView != nil else { return }
        // forceReload：controller.load() 校验通过后的重建（同 URL 重试/重播），
        // 跳过这层 URL/头去重——否则 controller 已把 isLoading 置 true，
        // 这里早退不调 loadHTMLString，页面永久卡死在转圈。
        guard forceReload || url != loadedURL || headers != loadedHeaders else { return }
        // 代际令牌：连续 forceReload 同 URL 时，旧的异步 Cookie 注入回调
        // 不得覆盖新加载（group.notify 内校验）。
        loadToken &+= 1
        let token = loadToken
        loadedURL = url
        loadedHeaders = headers
        guard let url else {
            // 停播：只停页内播放，不拆 WebView（下次 load 还能用）。
            evaluate("if (window.__webplayer) { window.__webplayer.teardown(); }")
            return
        }
        // UA：模块给了就用模块的，否则 iPhone UA。WKWebView 的 UA 对 XHR 同样生效，
        // 这是禁设头 User-Agent 唯一能走的路（xhrSetup 里 setRequestHeader 改不了它）。
        webView?.customUserAgent = Self.headerValue(headers, "User-Agent") ?? NetConstants.iPhoneUserAgent
        guard let library = WebPlayerLibraries.hlsSource else {
            Task { @MainActor in self.controller.handleFatalError("hls.js 库文件缺失，播不了") }
            return
        }
        let boot = Self.bootScript(url: url, headers: headers, resumeAt: resumeAt)
        let html = WebPlayerLibraries.playerHTML(librarySource: library, bootScript: boot)
        // baseURL = 流地址本身：
        // ① 播单/分片/密钥请求与文档同源，不触发 CORS 预检（hls.js 用 XHR 读播单，
        //    跨域要站方回 Access-Control-Allow-Origin，很多 CDN 不给）；
        // ② 文档 URL 就是子请求带上的 Referer（Referer 是禁设头，xhrSetup 改不了）；
        // ③ https baseURL 保证安全上下文（MSE 要求）。
        // 代价是 Referer 是流地址、不是帖页——需要帖页 Referer 的站仍可能拒，
        // 这是 hls.js 路的已知边界（见文件头）；Native HLS 兼容实现不受 CORS 影响。
        loadHTMLWithCookies(html, baseURL: url, headers: headers, token: token)
    }

    /// Cookie 注入：模块给的 Cookie 头是 XHR 禁设头，xhrSetup 里 setRequestHeader
    /// 发不出去；拆成 HTTPCookie 写进 WebView 的 cookie jar，xhr.withCredentials
    /// 才能带上（只认 Cookie 头，不管 Set-Cookie）。先把 Cookie 写完再建页，
    /// 否则首个播单请求可能赶在写 Cookie 之前发出；写完后 URL 已换就不再建旧页。
    private func loadHTMLWithCookies(_ html: String, baseURL: URL, headers: [String: String]?, token: UInt64) {
        guard let webView else { return }
        let cookies = Self.cookies(from: headers, for: baseURL)
        guard !cookies.isEmpty else {
            webView.loadHTMLString(html, baseURL: baseURL)
            return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self, weak webView] in
            guard let self, !self.isTornDown, self.loadToken == token, self.loadedURL == baseURL else { return }
            webView?.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// 请求头大小写不敏感取值（模块可能给 "cookie"/"COOKIE"、"user-agent" 等写法）。
    private static func headerValue(_ headers: [String: String]?, _ name: String) -> String? {
        headers?.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }

    private static func cookies(from headers: [String: String]?, for url: URL) -> [HTTPCookie] {
        guard let host = url.host else { return [] }
        let raw = Self.headerValue(headers, "Cookie") ?? ""
        guard !raw.isEmpty else { return [] }
        var out: [HTTPCookie] = []
        for pair in raw.split(separator: ";") {
            // omittingEmptySubsequences: false：空值 Cookie（如 flag=）不能丢，
            // 否则分段丢值；HTTPCookie 收不收空值由它自己定，这里不预判。
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let props: [HTTPCookiePropertyKey: Any] = [.domain: host, .path: "/", .name: name, .value: value]
            if let cookie = HTTPCookie(properties: props) { out.append(cookie) }
        }
        return out
    }

    func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 离页停播：销毁 Hls 实例 + 停 WebView。幂等（onDisappear 与 dismantle 都会调）。
    /// 空白页替换本身就会丢弃旧页、停掉播放；先调页内 teardown 是再保险一层。
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        evaluate("if (window.__webplayer) { window.__webplayer.teardown(); }")
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        // 断开强引用环：WKUserContentController 强持有 message handler（即 self），
        // VC → webView → configuration → userContentController → self；
        // 不摘掉这个 handler，teardown 后 VC 永远走不到 deinit（真泄漏）。
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "hlsjs")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        loadedURL = nil
        loadedHeaders = nil
    }

    deinit {
        teardown()
    }

    // MARK: - WKScriptMessageHandler（JS → Swift）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hlsjs",
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Task { @MainActor in self.controller.handleMessage(json) }
    }

    // MARK: - WKNavigationDelegate

    /// 已提交导航失败才报（快速切线时被顶掉的 provisional 导航不报——
    /// 那属于旧页，不该烧掉新线；controller 侧按 URL 只认一次失败是第二道拦）。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isTornDown else { return }
        Task { @MainActor in self.controller.handleFatalError("页面加载失败（\(error.localizedDescription)）") }
    }

    /// 内容进程崩掉（MSE/内存压力下会发生）：页已死，不静默转圈，按失败走切线。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isTornDown else { return }
        Task { @MainActor in self.controller.handleFatalError("播放页面进程异常终止") }
    }

    // MARK: - WKUIDelegate

    /// window.open / target=_blank 的新窗口：一律不建（广告弹窗就死在这里）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    // MARK: - 启动脚本

    /// 把流地址/请求头/续播点填进启动脚本模板（__PLAYER_SRC__ 等三个占位符）。
    /// 不用 Swift 字符串插值拼 JS：模板里没有 \(...)，占位符替换不会误伤 JS 语法。
    private static func bootScript(url: URL, headers: [String: String]?, resumeAt: Double) -> String {
        bootScriptTemplate
            .replacingOccurrences(of: "__PLAYER_SRC__", with: WebPlayerLibraries.jsStringLiteral(url.absoluteString))
            .replacingOccurrences(of: "__PLAYER_HEADERS__", with: WebPlayerLibraries.jsHeadersObject(headers))
            .replacingOccurrences(of: "__PLAYER_RESUME_AT__", with: "\(resumeAt)")
    }

    /// hls.js 启动脚本。只用普通字符串拼接，不用 JS 模板字面量（`${}` 会撞 Swift 插值）。
    /// 关键调用均已在 shipped 的 hls.js 1.5.20 文件里验过存在：
    /// Hls.isSupported / new Hls({xhrSetup, fetchSetup}) / hls.loadSource /
    /// hls.attachMedia / Hls.Events.MANIFEST_PARSED / LEVEL_SWITCHED / ERROR /
    /// Hls.ErrorTypes.NETWORK_ERROR / hls.currentLevel / hls.levels /
    /// hls.startLoad（本文件不用，见 ERROR 处理注释）/ hls.destroy。
    private static let bootScriptTemplate = """
    (function(){
      var video = document.getElementById('v');
      var HEADERS = __PLAYER_HEADERS__;
      var SRC = __PLAYER_SRC__;
      var RESUME_AT = __PLAYER_RESUME_AT__;
      function post(msg){ try { window.webkit.messageHandlers.hlsjs.postMessage(JSON.stringify(msg)); } catch(e){} }
      var FORBIDDEN = {'referer':1,'user-agent':1,'cookie':1,'host':1,'origin':1,'content-length':1,'connection':1};
      function applyHeaders(xhr){
        try { xhr.withCredentials = true; } catch(e){}
        for (var k in HEADERS){
          if (!HEADERS.hasOwnProperty(k)) continue;
          if (FORBIDDEN[k.toLowerCase()]) continue;
          try { xhr.setRequestHeader(k, HEADERS[k]); } catch(e){}
        }
      }
      function bufferedEnd(){
        try {
          var t = video.currentTime;
          for (var i = 0; i < video.buffered.length; i++) {
            if (video.buffered.start(i) <= t && t <= video.buffered.end(i)) return video.buffered.end(i);
          }
          // currentTime 不在任何已缓冲区间内（在空隙里或尚未缓冲）：回退到
          // 最后一个区间的 end，与旧行为一致，不把缓冲条闪回 0。
          if (video.buffered.length > 0) return video.buffered.end(video.buffered.length - 1);
        } catch(e){}
        return 0;
      }
      function sendLevels(){
        try {
          var list = [];
          if (window.__hls && window.__hls.levels){
            for (var i = 0; i < window.__hls.levels.length; i++){
              var lv = window.__hls.levels[i];
              list.push({index: i, height: lv.height || 0, bitrate: lv.bitrate || 0});
            }
          }
          var cur = -1;
          if (window.__hls){ cur = window.__hls.currentLevel; }
          post({type: 'levels', levels: list, current: cur});
        } catch(e){}
      }
      if (typeof Hls === 'undefined' || !Hls.isSupported()){
        post({type: 'error', fatal: true, message: 'HLS.js 不支持：此设备 WebView 无 ManagedMediaSource（iOS 17.4 以下、Lockdown Mode 或非安全上下文都可能如此）'});
        return;
      }
      var hls = new Hls({
        enableWorker: true,
        capLevelToPlayerSize: false,
        maxBufferLength: 30,
        maxMaxBufferLength: 60,
        xhrSetup: function(xhr, url){ applyHeaders(xhr); },
        fetchSetup: function(context, initParams){
          // credentials: 'include'：fetch 跨域取分片/密钥时也带上 Cookie jar 里的 Cookie。
          initParams.credentials = 'include';
          initParams.headers = initParams.headers || {};
          for (var k in HEADERS){
            if (!HEADERS.hasOwnProperty(k)) continue;
            if (FORBIDDEN[k.toLowerCase()]) continue;
            // initParams.headers 可能是 Headers 实例（有 .set）也可能是普通对象。
            if (typeof initParams.headers.set === 'function'){ initParams.headers.set(k, HEADERS[k]); }
            else { initParams.headers[k] = HEADERS[k]; }
          }
          return new Request(context.url, initParams);
        }
      });
      window.__hls = hls;
      hls.on(Hls.Events.MANIFEST_PARSED, function(){
        sendLevels();
        if (RESUME_AT > 0){ try { video.currentTime = RESUME_AT; } catch(e){} }
        video.play().catch(function(){});
      });
      hls.on(Hls.Events.LEVEL_SWITCHED, function(ev, data){ post({type: 'levelswitched', index: data.level}); });
      hls.on(Hls.Events.ERROR, function(ev, data){
        if (!data.fatal) return;
        // fatal 不在这里 startLoad/recoverMediaError 重试：路由的下一条线就是恢复路径
        // （与原生播放器失败切线一致）；hls.js 失败后回退到 Native HLS 兼容实现只一次、
        // 不循环（A 路的 markFailed 负责，本文件只报失败）。
        post({type: 'error', fatal: true, message: 'HLS 播放失败（' + (data.details || data.type || 'ERROR') + '）'});
      });
      video.addEventListener('playing', function(){ post({type: 'playing'}); });
      video.addEventListener('play', function(){ post({type: 'play'}); });
      video.addEventListener('pause', function(){ post({type: 'paused'}); });
      video.addEventListener('waiting', function(){ post({type: 'waiting'}); });
      video.addEventListener('ended', function(){ post({type: 'ended'}); });
      video.addEventListener('timeupdate', function(){ post({type: 'timeupdate', t: video.currentTime, d: video.duration, buffered: bufferedEnd()}); });
      video.addEventListener('progress', function(){ post({type: 'progress', t: video.currentTime, d: video.duration, buffered: bufferedEnd()}); });
      function isFullscreen(){ try { return !!(document.fullscreenElement || document.webkitFullscreenElement || (video && video.webkitDisplayingFullscreen)); } catch(e){ return false; } }
      function reportFullscreen(){ post({type: 'fullscreen', value: isFullscreen()}); }
      document.addEventListener('fullscreenchange', reportFullscreen);
      document.addEventListener('webkitfullscreenchange', reportFullscreen);
      video.addEventListener('webkitbeginfullscreen', reportFullscreen);
      video.addEventListener('webkitendfullscreen', reportFullscreen);
      window.__webplayer = {
        play: function(){ video.play().catch(function(){}); },
        pause: function(){ video.pause(); },
        seek: function(s){ try { video.currentTime = s; } catch(e){} },
        setLevel: function(i){ try { hls.currentLevel = i; } catch(e){} },
        fullscreen: function(){
          try {
            if (document.fullscreenElement){ document.exitFullscreen(); }
            else if (document.webkitFullscreenElement && document.webkitExitFullscreen){ document.webkitExitFullscreen(); }
            else if (video.webkitDisplayingFullscreen && video.webkitExitFullscreen){ video.webkitExitFullscreen(); }
            else if (video.requestFullscreen){ video.requestFullscreen(); }
            else if (video.webkitRequestFullscreen){ video.webkitRequestFullscreen(); }
            else if (video.webkitEnterFullscreen){ video.webkitEnterFullscreen(); }
          } catch(e){}
        },
        teardown: function(){
          try { hls.destroy(); } catch(e){}
          window.__hls = null;
          try { video.pause(); } catch(e){}
          video.removeAttribute('src');
          try { video.load(); } catch(e){}
        }
      };
      hls.loadSource(SRC);
      hls.attachMedia(video);
    })();
    """
}

// MARK: - WKWebView 的 SwiftUI 包装

struct HLSJSWebView: UIViewControllerRepresentable {
    let controller: HLSJSPlayerController

    func makeUIViewController(context: Context) -> HLSJSWebViewController {
        let vc = HLSJSWebViewController(controller: controller)
        // VC 指回 controller（EmbedProbeState.webView 同款写法）；换片由 controller.load()
        // 经 webViewController 驱动，不走 updateUIViewController（URL 变化时 SwiftUI
        // 刷新不重建页，正在播的片不受打扰）。
        controller.webViewController = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: HLSJSWebViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: HLSJSWebViewController, coordinator: Coordinator) {
        uiViewController.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

// MARK: - HLS.js 播放器（SwiftUI：WKWebView + 同一套底条，16:9 内嵌）

/// 真 HLS.js 播放器：WKWebView + 注入的 hls.js 播 viewModel.currentURL（.m3u8）。
/// 构造契约（D 路按这个调）：`HLSJSPlayerView(viewModel: PlayerViewModel)`。
/// 外观与原生播放器一致：16:9 内嵌在详情页顶部小窗口，不弹全屏；全屏靠底条上的
/// 全屏按钮（页内 video requestFullscreen）。离开页面 onDisappear 即停播。
struct HLSJSPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    /// 全屏状态上行到 DetailView：与 .webView 的 onFullscreenChange 同款回调模式，
    /// DetailView 接上后与 CustomPlayerView / .webView 共用同一个 @State isFullscreen，
    /// 靠它判断 onDisappear 是不是全屏引起的。
    var onFullscreenChange: ((Bool) -> Void)? = nil

    @StateObject private var controller: HLSJSPlayerController

    init(viewModel: PlayerViewModel, onFullscreenChange: ((Bool) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onFullscreenChange = onFullscreenChange
        _controller = StateObject(wrappedValue: HLSJSPlayerController(viewModel: viewModel))
    }

    var body: some View {
        ZStack {
            // 点画面切底条显隐走 VC 里的原生 UITapGestureRecognizer，
            // 不用 SwiftUI .onTapGesture（WKWebView 内层手势会把它吃掉）。
            HLSJSWebView(controller: controller)
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
                        onQualitySelected: { controller.selectQuality($0) },
                        isFullscreen: controller.isFullscreen,
                        onFullscreen: { controller.toggleFullscreen() },
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
        // 全屏状态同步给 DetailView（JS fullscreenchange 回传的 controller.isFullscreen，
        // 与 WebViewPlayerView 的 .onChange(of: probe.isFullscreen) 同款）。
        .onChange(of: controller.isFullscreen) { _, fullscreen in onFullscreenChange?(fullscreen) }
        // 全屏时不拆：页内 video 全屏期间的 onDisappear 不是真离页，拆了
        // isTornDown = true 会永久杀死 WKWebView，回来黑屏无法恢复。
        // 引擎已切走且全屏还开着：视图卸载后 .onChange(of: controller.isFullscreen)
        // 已失效，controller 随后回 false 也传不上去，DetailView 的 isFullscreen
        // 会卡 true，离页 guard !isFullscreen 阻断停播。只在引擎已切走时清；
        // 正常全屏进出时引擎仍是本播放器，条件不成立，不误清。
        .onDisappear {
            if viewModel.currentEngine != .hlsjs && controller.isFullscreen { onFullscreenChange?(false) }
            if viewModel.currentEngine != .hlsjs || !controller.isFullscreen { controller.teardown() }
        }
    }
}
