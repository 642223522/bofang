import SwiftUI
import WebKit

// MARK: - DASH 播放器（B 路）
//
// AVPlayer 播不了 .mpd，所以 DASH 只能走 dash.js（WKWebView + MSE）。
// 路由表把 .mpd 一律判给 .dash，不经过 AVPlayer；本文件是该引擎的唯一实现。
// 外观与行为与 HLSJSPlayerView 同款（16:9 内嵌、自绘底条复用 PlayerControlBar、
// 无灵动岛、从 0:00 起播、不自动续播、同片切线保进度、失败 markFailed 切线、
// 离页停播销毁 dash.js 实例 + 停 WebView）；画质/进度/缓冲/失败/首帧的处理
// 与 HLSJSPlayerView 一一对应，只是底层库从 hls.js 换成 dash.js。
// automaticallyWaitsToMinimizeStalling=true 只约束 AVPlayer，本播放器是 WebView，
// 不要去碰它；缓冲与 ABR 由 dash.js 自己管。
//
// 请求头（viewModel.currentHeaders，A 路的 interceptedHeaders 拼好）：
// 与 HLSJSPlayerView 同款处理——dash.js 官方扩展点是
// player.extend('RequestModifier', {modifyRequestHeader, modifyRequestURL})，
// 必须在 initialize 之前挂；Referer / User-Agent / Cookie 是禁设头，
// setRequestHeader 会被静默忽略，所以 Referer 靠文档 URL（baseURL=流地址本身）、
// UA 靠 WKWebView.customUserAgent、Cookie 靠 xhr.withCredentials + WebView 的 cookie jar；
// 其余头（如 Authorization、x-cdn-auth）由 modifyRequestHeader 原样透传给
// manifest/分片全部请求。CORS 边界与 hls.js 相同：baseURL 必须是流地址本身
// （同源），否则 manifest 都读不到。
//
// 画质：dash.js v4 的 API 以 shipped 的 dash.js 4.7.4 文件为准——
// getBitrateInfoListFor('video') 列档位、setQualityFor('video', index) 定档、
// updateSettings({streaming:{abr:{autoSwitchBitrate:{video:false/true}}}}) 开关自动。
// 注意 v5 已删 setQualityFor/getBitrateInfoListFor，升级大版本前必须先改本文件。
// （shipped 文件里 grep 验过：setQualityFor、getBitrateInfoListFor、
// updateSettings、autoSwitchBitrate、RequestModifier、modifyRequestHeader、
// PLAYBACK_STARTED、MANIFEST_LOADED、QUALITY_CHANGE_RENDERED 均存在；
// setAutoSwitchQualityFor 不存在，不要用它——自动开关走 updateSettings。）

// MARK: - 控制器（状态机，对标 HLSJSPlayerController）

/// DASH 播放器的状态机（ObservableObject，@MainActor）。
/// 只管 WebView 里的 dash.js 实例：换片、自动播、播放/暂停、快进、画质、缓冲、
/// 失败上报、全屏与控制条显隐。线路、路由、markPlaying/markFailed 仍走
/// PlayerViewModel，这里不重写。播放状态以页内 video 元素的事件为准
/// （playing/paused/waiting），不用本地旗子猜。
@MainActor
final class DASHPlayerController: ObservableObject {
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
    /// 画质选项（从 getBitrateInfoListFor 推导）与当前档位。
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
    /// 当前是不是自动档（JS 侧 __dashAuto 旗，由 levels 消息同步）。
    private var isAutoQuality = true

    /// WKWebView 的持有者（EmbedProbeState.webView 同款写法：VC 建好后指回来，
    /// 弱引用，不成环；Swift 侧的 play/pause/seek/画质/全屏都经它 evaluateJavaScript）。
    weak var webViewController: DASHWebViewController?

    /// VC 刚建好时补首播用的待播地址（load() 可能比 VC 建好更早到，
    /// viewDidLoad 里用这三个值补一次，load() 到了就是同一 URL，不重复建页）。
    var pendingURL: URL? { lastURL }
    var pendingHeaders: [String: String]? { lastHeaders }
    var pendingResumeAt: Double { lastResumeAt }

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        hideTask?.cancel()
    }

    // MARK: - 换片与自动播

    /// 新 URL 到达时调（DASHPlayerView 传进来的 currentURL/headers 变化）。
    /// URL/请求头没变不重建，避免 SwiftUI 刷新打断正在播的片。
    func load(url: URL?, headers: [String: String]?) {
        guard let url else {
            lastURL = nil
            lastHeaders = nil
            lastResumeAt = 0
            webViewController?.load(url: nil, headers: nil, resumeAt: 0)
            return
        }
        guard lastURL != url || lastHeaders != headers else { return }
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
        webViewController?.load(url: url, headers: headers, resumeAt: resumeAt)
    }

    // MARK: - JS 消息（WKScriptMessageHandler 转交）

    /// 页内 JS 桥的消息：timeupdate/progress/playing/paused/waiting/ended/
    /// fullscreen/levels/levelswitched/error。internal：VC 的消息回调调它。
    func handleMessage(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "timeupdate", "progress":
            if let t = Self.doubleValue(message["t"]) { currentTime = t }
            if let d = Self.doubleValue(message["d"]), d.isFinite, d > 0 { duration = d }
            if let b = Self.doubleValue(message["buffered"]), b.isFinite, b >= 0 {
                bufferedEnd = max(bufferedEnd, b)
            }
        case "playing":
            isPlaying = true
            isLoading = false
            // 真正出帧 → markPlaying（“正在解析播放线路…”由此消失）。
            if let url = lastURL, didMarkPlayingURL != url {
                didMarkPlayingURL = url
                viewModel.markPlaying()
            }
            showControlsTemporarily()
        case "play":
            isPlaying = true
        case "paused":
            isPlaying = false
            controlsVisible = true
        case "waiting":
            // 等数据/缓冲：不算在播，画面转圈。
            isPlaying = false
            isLoading = true
        case "ended":
            // 播到片尾：停在 0:00（不循环、不续播），控制条常显，等用户再点播放。
            isPlaying = false
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
        viewModel.markFailed(message)
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
        // 同一高度只留码率最高的一档（同一高度多 Representation 时只留最高码率）。
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
        // “自动”档永远在第一位（updateSettings autoSwitchBitrate.video = true）。
        let autoURL = base + "#dash-level-auto"
        options.append(QualityOption(
            id: autoURL,
            label: "自动",
            line: PlayLine(name: "自动", url: autoURL, description: "自动")
        ))
        // 其余档按高度从高到低排。
        let sorted = bestByLabel.values.sorted { $0.height > $1.height }
        for level in sorted {
            guard let label = videoQualityLabel(height: level.height) else { continue }
            let url = base + "#dash-level-\(level.index)"
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

    /// 画质切换：只动 dash.js 的 setQualityFor / autoSwitchBitrate，绝不调 viewModel.switchLine。
    /// QualityOption 里那条 PlayLine 的 URL 是合成的（“…#dash-level-N”），
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
        // 按 label 找回档位（rebuild 时同一 label 只留一档，label 唯一）。
        guard let level = levels.first(where: { videoQualityLabel(height: $0.height) == option.label }) else { return }
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
        wasPlayingBeforeScrub = shouldPlay
        evaluate("if (window.__webplayer) { window.__webplayer.pause(); }")
    }

    /// 拖动中：实时 seek（dash.js 跳转到该位置），进度条跟手。
    func scrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        evaluate("if (window.__webplayer) { window.__webplayer.seek(\(clamped)); }")
    }

    /// 松手：精确定位到拖到的位置；拖之前在播就恢复播放（不拖完停在暂停态）。
    func endScrub(to seconds: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        let resume = wasPlayingBeforeScrub
        evaluate("if (window.__webplayer) { window.__webplayer.seek(\(clamped)); }")
        if resume {
            shouldPlay = true
            evaluate("if (window.__webplayer) { window.__webplayer.play(); }")
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

    /// 离页停播：销毁 dash.js 实例 + 停 WebView（VC.teardown），状态复位。
    /// onDisappear 与 dismantle 都会调到这里/VC.teardown，VC 侧幂等。
    func teardown() {
        webViewController?.teardown()
        webViewController = nil
        hideTask?.cancel()
        hideTask = nil
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

/// DASH 播放器的 UIViewController：WKWebView 全铺，不带任何按钮。
/// 按钮/底条都在外层 SwiftUI（和直链自定义播放器同一套 PlayerControlBar）。
final class DASHWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let controller: DASHPlayerController
    private var webView: WKWebView?
    private var loadedURL: URL?
    private var loadedHeaders: [String: String]?
    private var isTornDown = false

    init(controller: DASHPlayerController) {
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
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        // 画中画用户不要，关掉（与 WebViewPlayer 一致）。
        config.allowsPictureInPictureMediaPlayback = false
        // 允许自动播（详情页点封面进来即播，不用用户再点一下；与 WebViewPlayer 一致）。
        config.mediaTypesRequiringUserActionForPlayback = []
        // 第二层（代理层）拦弹窗：JS 不许自己开新窗口。
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(self, name: "dashjs")

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
        // controller.load() 可能比 VC 建好更早（onAppear 先跑）：补一次，避免丢首播；
        // onAppear 随后还会调一次 load()，URL 相同、VC 侧 guard 会拦住，不重复建页。
        if let url = controller.pendingURL {
            load(url: url, headers: controller.pendingHeaders, resumeAt: controller.pendingResumeAt)
        }
    }

    /// 换片/换线：URL 或请求头变了才重建页（同 URL 不重建，避免 SwiftUI 刷新打断播放）。
    /// resumeAt 只在同 generation 切线时 > 0，新片/新一集为 0，从 0:00 起播。
    func load(url: URL?, headers: [String: String]?, resumeAt: Double) {
        guard !isTornDown else { return }
        guard url != loadedURL || headers != loadedHeaders else { return }
        loadedURL = url
        loadedHeaders = headers
        guard let url else {
            // 停播：只停页内播放，不拆 WebView（下次 load 还能用）。
            evaluate("if (window.__webplayer) { window.__webplayer.teardown(); }")
            return
        }
        // UA：模块给了就用模块的，否则 iPhone UA。WKWebView 的 UA 对 XHR 同样生效，
        // 这是禁设头 User-Agent 唯一能走的路（RequestModifier 里 setRequestHeader 改不了它）。
        webView?.customUserAgent = headers?["User-Agent"] ?? NetConstants.iPhoneUserAgent
        guard let library = WebPlayerLibraries.dashSource else {
            Task { @MainActor in self.controller.handleFatalError("dash.js 库文件缺失，播不了") }
            return
        }
        let boot = Self.bootScript(url: url, headers: headers, resumeAt: resumeAt)
        let html = WebPlayerLibraries.playerHTML(librarySource: library, bootScript: boot)
        // baseURL = 流地址本身（同 hls.js 路，见 HLSJSPlayerViewController.load 的注释）：
        // ① manifest/分片请求与文档同源，不触发 CORS 预检；
        // ② 文档 URL 就是子请求带上的 Referer（Referer 是禁设头，改不了）；
        // ③ https baseURL 保证安全上下文（MSE 要求）。
        webView?.loadHTMLString(html, baseURL: url)
    }

    func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 离页停播：销毁 dash.js 实例 + 停 WebView。幂等（onDisappear 与 dismantle 都会调）。
    /// 空白页替换本身就会丢弃旧页、停掉播放；先调页内 teardown 是再保险一层。
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        evaluate("if (window.__webplayer) { window.__webplayer.teardown(); }")
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
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
        guard message.name == "dashjs",
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

    /// dash.js 启动脚本。只用普通字符串拼接，不用 JS 模板字面量（`${}` 会撞 Swift 插值）。
    /// 关键调用均已在 shipped 的 dash.js 4.7.4 文件里验过存在：
    /// dashjs.MediaPlayer().create() / player.extend('RequestModifier', …) /
    /// player.initialize(video, url, autoPlay) / player.getBitrateInfoListFor /
    /// player.getQualityFor / player.setQualityFor / player.updateSettings /
    /// player.seek / player.play / player.pause / player.reset /
    /// dashjs.MediaPlayer.events.MANIFEST_LOADED / STREAM_INITIALIZED /
    /// PLAYBACK_STARTED / QUALITY_CHANGE_RENDERED / ERROR。
    private static let bootScriptTemplate = """
    (function(){
      var video = document.getElementById('v');
      var HEADERS = __PLAYER_HEADERS__;
      var SRC = __PLAYER_SRC__;
      var RESUME_AT = __PLAYER_RESUME_AT__;
      function post(msg){ try { window.webkit.messageHandlers.dashjs.postMessage(JSON.stringify(msg)); } catch(e){} }
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
        try { if (video.buffered.length > 0) return video.buffered.end(video.buffered.length - 1); } catch(e){}
        return 0;
      }
      if (typeof dashjs === 'undefined' || !dashjs.MediaPlayer){
        post({type: 'error', fatal: true, message: 'dash.js 不支持：此设备 WebView 无 MSE（Lockdown Mode 或非安全上下文都可能如此）'});
        return;
      }
      var player = dashjs.MediaPlayer().create();
      window.__dash = player;
      window.__dashAuto = true;
      player.extend('RequestModifier', function(){
        return {
          modifyRequestHeader: function(xhr){ applyHeaders(xhr); return xhr; },
          modifyRequestURL: function(url){ return url; }
        };
      }, true);
      function sendLevels(){
        try {
          var list = [];
          var infos = player.getBitrateInfoListFor('video') || [];
          for (var i = 0; i < infos.length; i++){
            list.push({index: infos[i].qualityIndex, height: infos[i].height || 0, bitrate: infos[i].bitrate || 0});
          }
          var cur = -1;
          if (window.__dashAuto){ cur = -1; }
          else { try { cur = player.getQualityFor('video'); } catch(e){ cur = 0; } }
          post({type: 'levels', levels: list, current: cur});
        } catch(e){}
      }
      player.on(dashjs.MediaPlayer.events.MANIFEST_LOADED, function(){ sendLevels(); });
      player.on(dashjs.MediaPlayer.events.STREAM_INITIALIZED, function(){
        sendLevels();
        if (RESUME_AT > 0){ try { player.seek(RESUME_AT); } catch(e){ try { video.currentTime = RESUME_AT; } catch(e2){} } }
      });
      player.on(dashjs.MediaPlayer.events.PLAYBACK_STARTED, function(){ post({type: 'playing'}); });
      player.on(dashjs.MediaPlayer.events.QUALITY_CHANGE_RENDERED, function(ev){
        var q = -1;
        if (ev && ev.newQuality !== undefined && ev.newQuality !== null){ q = ev.newQuality; }
        if (window.__dashAuto){ q = -1; }
        post({type: 'levelswitched', index: q});
        sendLevels();
      });
      player.on(dashjs.MediaPlayer.events.ERROR, function(e){
        var err = (e && e.error) || {};
        // dash.js 内部会对分片失败先重试，走到 ERROR 事件的基本是 manifest/播放级失败，
        // 按 fatal 处理走 markFailed 切线（与 HLSJSPlayerView 一致）；同一 URL 只认一次在 Swift 侧拦。
        post({type: 'error', fatal: true, message: 'DASH 播放失败（' + (err.code || err.message || 'ERROR') + '）'});
      });
      video.addEventListener('playing', function(){ post({type: 'playing'}); });
      video.addEventListener('play', function(){ post({type: 'play'}); });
      video.addEventListener('pause', function(){ post({type: 'paused'}); });
      video.addEventListener('waiting', function(){ post({type: 'waiting'}); });
      video.addEventListener('ended', function(){ post({type: 'ended'}); });
      video.addEventListener('timeupdate', function(){ post({type: 'timeupdate', t: video.currentTime, d: video.duration, buffered: bufferedEnd()}); });
      video.addEventListener('progress', function(){ post({type: 'progress', t: video.currentTime, d: video.duration, buffered: bufferedEnd()}); });
      document.addEventListener('fullscreenchange', function(){ post({type: 'fullscreen', value: !!document.fullscreenElement}); });
      window.__webplayer = {
        play: function(){ try { player.play(); } catch(e){ video.play().catch(function(){}); } },
        pause: function(){ try { player.pause(); } catch(e){ video.pause(); } },
        seek: function(s){ try { player.seek(s); } catch(e){ try { video.currentTime = s; } catch(e2){} } },
        setLevel: function(i){
          try {
            if (i < 0){
              window.__dashAuto = true;
              player.updateSettings({streaming: {abr: {autoSwitchBitrate: {video: true}}}});
            } else {
              window.__dashAuto = false;
              player.updateSettings({streaming: {abr: {autoSwitchBitrate: {video: false}}}});
              player.setQualityFor('video', i);
            }
          } catch(e){}
        },
        fullscreen: function(){
          try {
            if (document.fullscreenElement){ document.exitFullscreen(); }
            else if (video.requestFullscreen){ video.requestFullscreen(); }
            else if (video.webkitRequestFullscreen){ video.webkitRequestFullscreen(); }
          } catch(e){}
        },
        teardown: function(){
          try { player.reset(); } catch(e){}
          window.__dash = null;
          try { video.pause(); } catch(e){}
          video.removeAttribute('src');
          try { video.load(); } catch(e){}
        }
      };
      player.initialize(video, SRC, true);
    })();
    """
}

// MARK: - WKWebView 的 SwiftUI 包装

struct DASHWebView: UIViewControllerRepresentable {
    let controller: DASHPlayerController

    func makeUIViewController(context: Context) -> DASHWebViewController {
        let vc = DASHWebViewController(controller: controller)
        // VC 指回 controller（EmbedProbeState.webView 同款写法）；换片由 controller.load()
        // 经 webViewController 驱动，不走 updateUIViewController（URL 变化时 SwiftUI
        // 刷新不重建页，正在播的片不受打扰）。
        controller.webViewController = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: DASHWebViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DASHWebViewController, coordinator: Coordinator) {
        uiViewController.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

// MARK: - DASH 播放器（SwiftUI：WKWebView + 同一套底条，16:9 内嵌）

/// DASH 播放器：WKWebView + 注入的 dash.js 播 viewModel.currentURL（.mpd）。
/// 构造契约（D 路按这个调）：`DASHPlayerView(viewModel: PlayerViewModel)`。
/// 外观与原生播放器一致：16:9 内嵌在详情页顶部小窗口，不弹全屏；全屏靠底条上的
/// 全屏按钮（页内 video requestFullscreen）。离开页面 onDisappear 即停播。
struct DASHPlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @StateObject private var controller: DASHPlayerController

    init(viewModel: PlayerViewModel) {
        self.viewModel = viewModel
        _controller = StateObject(wrappedValue: DASHPlayerController(viewModel: viewModel))
    }

    var body: some View {
        ZStack {
            DASHWebView(controller: controller)
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
        .onDisappear { controller.teardown() }
    }
}
