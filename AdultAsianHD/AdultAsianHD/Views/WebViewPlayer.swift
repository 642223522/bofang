import SwiftUI
import WebKit

// MARK: - 嵌入页探针（读页内 video 元素的进度/状态，控制它播/停/快进/全屏；兼管底条显隐）

/// JS 探针状态：每 0.5 秒读一次页内第一个 video 元素的 currentTime/duration/paused。
/// 探不到 video（跨域 iframe、还没加载出 video）时 hasVideo=false，外层只显示状态文案。
/// 嵌页自己的播放控制不动（页内播放器照常用）；外层底条只是多一套统一外观的操作入口。
/// 底条显隐也放这里管（@MainActor 类，Task 写起来安全；View struct 里写 Task 容易踩并发坑）。
@MainActor
final class EmbedProbeState: ObservableObject {
    @Published var hasVideo = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 页内 video 是不是停着（没 video 时为 true）。
    @Published var paused = true
    /// 底条是否可见（播时 3 秒无操作自动藏，暂停/没 video 时常显，点画面切换）。
    @Published var controlsVisible = true

    weak var webView: WKWebView?
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var wasPaused = true

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probe() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hideTask?.cancel()
        hideTask = nil
    }

    private func probe() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            """
            (function(){
              var v = document.querySelector('video');
              if (!v) return null;
              return JSON.stringify({t: v.currentTime, d: v.duration, p: v.paused});
            })();
            """
        ) { [weak self] result, _ in
            guard let self else { return }
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.hasVideo = false
                return
            }
            self.hasVideo = true
            self.currentTime = (json["t"] as? Double) ?? 0
            let d = (json["d"] as? Double) ?? 0
            self.duration = (d.isFinite && d > 0) ? d : 0
            let nowPaused = (json["p"] as? Bool) ?? true
            // 暂停→播放的瞬间：显示底条，3 秒后自动藏；播→暂停：底条常显。
            if nowPaused {
                self.hideTask?.cancel()
                self.controlsVisible = true
            } else if self.wasPaused {
                self.showControlsTemporarily()
            }
            self.paused = nowPaused
            self.wasPaused = nowPaused
        }
    }

    /// 外层底条的播放/暂停：直接调页内 video 的 play()/pause()。
    func togglePlayPause() {
        webView?.evaluateJavaScript(
            """
            (function(){ var v = document.querySelector('video'); if (!v) return; if (v.paused) { v.play(); } else { v.pause(); } })();
            """,
            completionHandler: nil
        )
    }

    /// 外层进度条快进：直接设页内 video 的 currentTime（播着就继续播，停着就停着）。
    func seek(to seconds: Double) {
        webView?.evaluateJavaScript(
            """
            (function(){ var v = document.querySelector('video'); if (!v) return; v.currentTime = \(seconds); })();
            """,
            completionHandler: nil
        )
    }

    /// 外层底条的全屏：让页内 video 元素 requestFullscreen（WKWebView 原生接管全屏播放），
    /// 没 video 时退回整个页面全屏；页内播放器自带的全屏按钮同样可用。
    func requestFullscreen() {
        webView?.evaluateJavaScript(
            """
            (function(){
              var v = document.querySelector('video');
              if (v) {
                if (v.requestFullscreen) v.requestFullscreen();
                else if (v.webkitRequestFullscreen) v.webkitRequestFullscreen();
              } else if (document.documentElement.requestFullscreen) {
                document.documentElement.requestFullscreen();
              }
            })();
            """,
            completionHandler: nil
        )
    }

    // MARK: - 底条显隐

    func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { showControlsTemporarily() }
    }

    /// 播时显示底条，3 秒无操作自动藏；暂停/没 video 时常显。
    func showControlsTemporarily() {
        controlsVisible = true
        hideTask?.cancel()
        guard hasVideo && !paused else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.hasVideo && !self.paused {
                self.controlsVisible = false
            }
        }
    }
}

// MARK: - 嵌入页 WKWebView（只负责播嵌页，不带按钮）

/// 嵌入页播放器的 UIViewController：WKWebView 全铺，不带任何按钮。
/// 按钮/底条都在外层 SwiftUI（和直链自定义播放器同一套 PlayerControlBar）。
final class EmbedWebViewController: UIViewController {
    private let url: URL
    private let probe: EmbedProbeState
    private var webView: WKWebView?
    private var loadedURL: URL?

    init(url: URL, probe: EmbedProbeState) {
        self.url = url
        self.probe = probe
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
        // 画中画用户不要，关掉。
        config.allowsPictureInPictureMediaPlayback = false
        // 允许自动播（嵌入页过完 CF 挑战后自己起播，不用用户再点一下）。
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = NetConstants.iPhoneUserAgent
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.webView = webView
        probe.webView = webView

        loadIfNeeded(url: url)
    }

    /// URL 不变不重载，避免 SwiftUI 刷新时打断正在播的嵌入页。
    func loadIfNeeded(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        webView?.load(URLRequest(url: url))
    }

    /// 停掉 WebView、释放资源（关闭 / 离开详情页时调）：停加载、清页面、摘代理、移出视图。
    func teardown() {
        probe.webView = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        loadedURL = nil
    }

    deinit {
        teardown()
    }
}

struct EmbedWebView: UIViewControllerRepresentable {
    let url: URL
    let probe: EmbedProbeState

    func makeUIViewController(context: Context) -> EmbedWebViewController {
        EmbedWebViewController(url: url, probe: probe)
    }

    func updateUIViewController(_ uiViewController: EmbedWebViewController, context: Context) {
        uiViewController.loadIfNeeded(url: url)
    }

    static func dismantleUIViewController(_ uiViewController: EmbedWebViewController, coordinator: Coordinator) {
        uiViewController.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

// MARK: - 嵌入页播放器（SwiftUI：WKWebView + 同一套底条）

/// 嵌入页播放器（fallback）：把 playmogo/dood 这类嵌入页直接在 WKWebView 里播。
/// WKWebView 是真浏览器，能过 Cloudflare 挑战（"Just a moment..." 会自己解），
/// 页内自带的播放器播片。底层还是 WKWebView（嵌页本身的播放不动），
/// 外层 chrome 换成和直链自定义播放器同一套样式：
/// 深色半透明底条（播放/暂停、进度条、当前时间/总时间、全屏、关闭），点画面显示/隐藏。
/// 探不到页内 video 时只显示“嵌入播放中”状态文案 + 全屏/关闭。
/// 只在混合解流抽不出直链时用（解出直链优先走 AVPlayer）。
/// 关闭/离开时停掉 WebView、释放资源。
struct WebViewPlayerView: View {
    let url: URL
    let onClose: () -> Void

    @StateObject private var probe = EmbedProbeState()

    var body: some View {
        ZStack {
            EmbedWebView(url: url, probe: probe)
                .onTapGesture { probe.toggleControls() }
            VStack {
                Spacer()
                if probe.controlsVisible {
                    PlayerControlBar(
                        isPlaying: !probe.paused,
                        currentTime: probe.currentTime,
                        duration: probe.duration,
                        bufferedEnd: 0,
                        showsProgress: probe.hasVideo,
                        qualityLabel: nil,
                        qualityOptions: [],
                        onQualitySelected: nil,
                        isFullscreen: false,
                        onFullscreen: { probe.requestFullscreen() },
                        onClose: onClose,
                        statusText: "嵌入播放中",
                        onPlayPause: { probe.togglePlayPause() },
                        onScrubStart: {},
                        onScrub: { probe.seek(to: $0) },
                        onScrubEnd: { probe.seek(to: $0) }
                    )
                }
            }
        }
        .background(Color.black)
        .onAppear {
            probe.start()
            probe.showControlsTemporarily()
        }
        .onDisappear {
            probe.stop()
        }
    }
}
