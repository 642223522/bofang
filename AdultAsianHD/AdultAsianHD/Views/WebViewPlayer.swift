import SwiftUI
import WebKit

/// 嵌入页播放器（fallback）：把 playmogo/dood 这类嵌入页直接在 WKWebView 里播。
/// WKWebView 是真浏览器，能过 Cloudflare 挑战（"Just a moment..." 会自己解），
/// 页内自带的播放器播片。带关闭、全屏按钮；关闭/离开时停掉 WebView、释放资源。
/// 只在混合解流抽不出直链时用（解出直链优先走 AVPlayer，快进、跟手进度条还是原生的）。
struct WebViewPlayerView: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> WebViewPlayerController {
        WebViewPlayerController(url: url, onClose: onClose)
    }

    func updateUIViewController(_ uiViewController: WebViewPlayerController, context: Context) {
        // URL 不变不重载；换 URL 时重载（DetailView 换线时一般会重建整个 View）。
        uiViewController.loadIfNeeded(url: url)
    }

    static func dismantleUIViewController(_ uiViewController: WebViewPlayerController, coordinator: Coordinator) {
        uiViewController.teardown()
    }

    final class Coordinator {}
}

/// 嵌入页播放器的 UIViewController：WKWebView 全铺 + 右上角关闭/全屏按钮。
/// 全屏：先让页内 video 元素 requestFullscreen（WKWebView 原生接管全屏播放），
/// 没 video 时退回整个页面全屏；页内播放器自带的全屏按钮同样可用。
final class WebViewPlayerController: UIViewController {
    private let url: URL
    private let onClose: () -> Void
    private var webView: WKWebView?
    private var loadedURL: URL?

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
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
        config.allowsPictureInPictureMediaPlayback = true
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

        // 右上角工具条：关闭 + 全屏（半透明黑底圆角，盖在视频上也看得见）。
        let closeButton = makeToolButton(systemName: "xmark", action: #selector(didTapClose))
        let fullscreenButton = makeToolButton(systemName: "arrow.up.left.and.arrow.down.right", action: #selector(didTapFullscreen))
        let stack = UIStackView(arrangedSubviews: [fullscreenButton, closeButton])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            fullscreenButton.widthAnchor.constraint(equalToConstant: 32),
            fullscreenButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        loadIfNeeded(url: url)
    }

    /// URL 不变不重载，避免 SwiftUI 刷新时打断正在播的嵌入页。
    func loadIfNeeded(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        webView?.load(URLRequest(url: url))
    }

    @objc private func didTapClose() {
        onClose()
    }

    @objc private func didTapFullscreen() {
        webView?.evaluateJavaScript("""
        (function(){
          var v = document.querySelector('video');
          if (v) {
            if (v.requestFullscreen) v.requestFullscreen();
            else if (v.webkitRequestFullscreen) v.webkitRequestFullscreen();
          } else if (document.documentElement.requestFullscreen) {
            document.documentElement.requestFullscreen();
          }
        })();
        """, completionHandler: nil)
    }

    /// 停掉 WebView、释放资源（关闭 / 离开详情页时调）：停加载、清页面、摘代理、移出视图。
    func teardown() {
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

    private func makeToolButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 16
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}
