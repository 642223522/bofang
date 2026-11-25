import SwiftUI
import WebKit

// MARK: - 广告剥离（三层，四家 AI 一致的方向）
//
// ① WKContentRuleList：只拦已知广告/追踪域的第三方请求（编译一次、持久化、
//    加载前装好）。不拦主文档、播放器 JS、.m3u8/.ts/.m4s、验证资源
//    （/cdn-cgi/、challenges.cloudflare.com 不在拦截名单里，且规则只对
//    third-party 生效，第一方资源根本不受影响）。
// ② 代理层拦弹窗：createWebViewWith 返回 nil（window.open 打不开）、
//    decidePolicyFor 拦主框架外链跳转（广告点一下就跳走的站外页）、
//    javaScriptCanOpenWindowsAutomatically=false。
// ③ CF 验证通过后再轻量注入 CSS/JS 删广告 DOM（分两阶段：验证阶段不碰 DOM，
//    验证过了才删）。不盲目隐藏所有 iframe——视频播放器本身就在 iframe 里，
//    只删 src 落在广告域的 iframe 和按文本/类名认出的广告卡片。
// 每站单独配：下面的域名表是通用广告域；某站有专属广告域/选择器时，
// 在 AdBlockRules.rulesJSON(forSiteHost:) 里按 host 追加，不要改全局表。

// MARK: - 第一层：WKContentRuleList（只拦已知广告域的第三方请求）

/// 广告剥离规则：通用广告/追踪域名表 + 按站追加。
/// 只拦 third-party（跨域）请求，且 resource-type 不含 document/media，
/// 所以主文档、播放器 JS、视频流（.m3u8/.ts/.m4s）都不会被拦；
/// Cloudflare 验证资源也不在名单里。
enum AdBlockRules {
    /// 通用广告/追踪域（纯广告网络，没有视频 CDN、没有 CF）。
    static let baseAdDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagmanager.com", "googletagservices.com",
        "taboola.com", "outbrain.com", "mgid.com",
        "adsrvr.org", "adnxs.com", "criteo.com", "moatads.com",
        "scorecardresearch.com", "amazon-adsystem.com", "adsafeprotected.com",
        "pubmatic.com", "rubiconproject.com", "openx.net",
        "popads.net", "popcash.net", "adcash.com", "propellerads.com",
        "adsterra.com", "hilltopads.com", "clickadu.com",
        "quantserve.com", "addthis.com", "sharethis.com",
        "bluekai.com", "mathtag.com", "exelator.com",
        "vungle.com", "applovin.com", "chartboost.com", "inmobi.com",
        "unityads.unity3d.com", "smaato.com", "mopub.com"
    ]

    /// 按站追加的广告域（目前只有 dood 家嵌页有专属广告，先留空位；
    /// 某站的广告域摸清了，在这里按 host 加一行）。
    static func extraDomains(forSiteHost host: String) -> [String] {
        // 例：if host.contains("playmogo.com") { return ["dood-ad-domain.example"] }
        return []
    }

    /// 生成 WKContentRuleList 的 JSON。url-filter 是正则，匹配完整 URL；
    /// 只拦 third-party + 脚本/图片/样式/字体/子文档这几类资源。
    static func rulesJSON(forSiteHost host: String) -> String {
        let domains = baseAdDomains + extraDomains(forSiteHost: host)
        let rules: [[String: Any]] = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": ".*\\." + escaped + ".*",
                    "load-type": ["third-party"],
                    "resource-type": ["script", "image", "style-sheet", "font", "subdocument"]
                ],
                "action": ["type": "block"]
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// 规则标识（编译一次、系统持久化，下次直接取缓存）。
    static let identifier = "com.liudehen.xiaoshipin.adblock.v1"
}

/// 规则编译与安装：编译一次后复用；编译是异步的，没编好时先加载页面，
/// 编好后装到 userContentController 上（后续导航生效；首屏由第三层 CSS/JS 兜底）。
/// 豆包的兜底：验证卡死时关掉规则重载（见 EmbedProbeState 的 challengeStuck 处理）。
enum AdBlockRuleStore {
    private static var cached: WKContentRuleList?
    private static var compiling = false
    private static var pending: [(WKContentRuleList?) -> Void] = []

    static func install(into controller: WKUserContentController, siteHost: String) {
        if let list = cached {
            controller.add(list)
            return
        }
        pending.append { list in
            if let list { controller.add(list) }
        }
        guard !compiling else { return }
        compiling = true
        let json = AdBlockRules.rulesJSON(forSiteHost: siteHost)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: AdBlockRules.identifier,
            encodedContentRuleList: json
        ) { list, error in
            compiling = false
            if let list { cached = list }
            #if DEBUG
            if let error { print("[AdBlock] 规则编译失败：\(error.localizedDescription)") }
            #endif
            let waiters = pending
            pending = []
            for waiter in waiters { waiter(list) }
        }
    }
}

// MARK: - 第三层：CF 通过后删广告 DOM + playsinline（分两阶段）

/// 广告 DOM 清理脚本（document-start 注入，主框架 + 子框架都跑）。
/// 两阶段：每轮先查有没有 Cloudflare 验证在跑（标题 "Just a moment"、
/// 挑战 iframe、cf- 标记），有就跳过这轮、什么都不碰；验证过了才删广告。
/// 删什么：① 文本命中的广告卡片（录屏里那种 "Your Next Adventure Starts Here!"
/// 旅行卡）；② 类名/id 带广告标记的元素；③ src 落在广告域的 iframe
/// （视频播放器本身在 iframe 里，只按域名删，不碰别的 iframe）。
/// 另：所有 video 元素都打上 playsinline，让嵌页视频在页内播、
/// 走我们的外层控制条，而不是一播就跳系统全屏播放器。
enum AdStripScript {
    static let source = """
    (function(){
      var AD_DOMAINS = ['doubleclick.net','googlesyndication.com','googleadservices.com',
        'taboola.com','outbrain.com','mgid.com','adsrvr.org','adnxs.com','criteo.com',
        'popads.net','popcash.net','adcash.com','propellerads.com','adsterra.com',
        'hilltopads.com','clickadu.com','amazon-adsystem.com','moatads.com'];
      var AD_TEXTS = ['Your Next Adventure', 'Starts Here!', 'Discover amazing attractions'];
      function cfRunning(){
        try {
          var t = (document.title || '').toLowerCase();
          if (t.indexOf('just a moment') >= 0) return true;
          if (t.indexOf('checking your browser') >= 0) return true;
          if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) return true;
          if (document.querySelector('[id*="cf-"], [class*="cf-challenge"], [class*="challenge-running"], [class*="turnstile"]')) return true;
        } catch(e){}
        return false;
      }
      function isAdSrc(u){
        if (!u) return false;
        u = String(u).toLowerCase();
        for (var i = 0; i < AD_DOMAINS.length; i++) {
          if (u.indexOf(AD_DOMAINS[i]) >= 0) return true;
        }
        return false;
      }
      function hideEl(el){
        try { el.style.setProperty('display', 'none', 'important'); } catch(e){}
      }
      function stripOnce(){
        if (cfRunning()) return;
        try {
          // 文本命中的广告卡片：往上找带关闭按钮/卡片样的容器一起藏（最多 4 层）。
          var all = document.querySelectorAll('div, section, aside, article');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var txt = el.textContent || '';
            for (var k = 0; k < AD_TEXTS.length; k++) {
              if (txt.indexOf(AD_TEXTS[k]) >= 0 && txt.length < 500) {
                var node = el;
                for (var up = 0; up < 4 && node; up++) {
                  if (node.querySelector && node.querySelector('[aria-label*="lose" i], [class*="close" i], [id*="close" i]')) { hideEl(node); break; }
                  node = node.parentElement;
                }
                if (up >= 4) hideEl(el);
                break;
              }
            }
          }
          // 类名/id 带广告标记的元素（不碰 video、播放器、CF）。
          var ads = document.querySelectorAll('[id*="ad-"], [id*="-ad-"], [class*="ad-banner"], [class*="ad-popup"], [class*="advertisement"], [class*="ads-container"], [class*="popunder"], [class*="overlay-ad"]');
          for (var j = 0; j < ads.length; j++) {
            var a = ads[j];
            if (a.tagName === 'VIDEO' || a.querySelector('video')) continue;
            hideEl(a);
          }
          // src 落在广告域的 iframe 才藏（播放器 iframe 不动）。
          var frames = document.querySelectorAll('iframe[src]');
          for (var f = 0; f < frames.length; f++) {
            if (isAdSrc(frames[f].src)) hideEl(frames[f]);
          }
        } catch(e){}
      }
      function forceInline(){
        try {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) {
            vs[i].setAttribute('playsinline', '');
            vs[i].setAttribute('webkit-playsinline', '');
            vs[i].playsInline = true;
          }
        } catch(e){}
      }
      stripOnce();
      forceInline();
      setInterval(function(){ stripOnce(); forceInline(); }, 1000);
    })();
    """
}

// MARK: - 嵌入页探针（读页内 video 元素的进度/状态，控制它播/停/快进/全屏；兼管底条显隐）

/// JS 探针状态：每 0.5 秒读一次页内第一个 video 元素的 currentTime/duration/paused。
/// 探不到 video（跨域 iframe、还没加载出 video）时 hasVideo=false，外层只显示状态文案。
/// 嵌页自己的播放控制不动（页内播放器照常用）；外层底条只是多一套统一外观的操作入口。
/// 底条显隐也放这里管（@MainActor 类，Task 写起来安全；View struct 里写 Task 容易踩并发坑）。
/// 另管 CF 卡死兜底：标题已明确是质询页（"Just a moment" / "Checking your browser"）
/// 就立即关掉内容规则、重载一次，不等 25 秒探针超时；标题之外的质询信号
/// （挑战 iframe / cf- 标记）仍走 25 秒兜底。只重载一次。
/// challengeRunning：质询在跑且还没出 video 时为 true，WebViewPlayerView 用它
/// 盖一层原生 Loading 遮罩（WebView 本身保持全尺寸在屏，只盖住不隐藏，
/// 否则质询会判 headless 无限刷新）。
@MainActor
final class EmbedProbeState: ObservableObject {
    @Published var hasVideo = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 页内 video 是不是停着（没 video 时为 true）。
    @Published var paused = true
    /// CF 质询是不是正在跑（还没出 video）：外层用它显示原生 Loading 遮罩。
    @Published var challengeRunning = false
    /// 底条是否可见（播时 3 秒无操作自动藏，暂停/没 video 时常显，点画面切换）。
    @Published var controlsVisible = true

    weak var webView: WKWebView?
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var wasPaused = true
    /// CF 挑战第一次被看到的时间；challengeReloaded=true 表示兜底已用过一次。
    private var challengeSince: Date?
    private var challengeReloaded = false

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
        challengeRunning = false
    }

    private func probe() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            """
            (function(){
              var v = document.querySelector('video');
              var cf = false;
              var cfTitle = false;
              try {
                var t = (document.title || '').toLowerCase();
                if (t.indexOf('just a moment') >= 0 || t.indexOf('checking your browser') >= 0) { cf = true; cfTitle = true; }
                if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) cf = true;
                if (document.querySelector('[id*="cf-"], [class*="cf-challenge"], [class*="challenge-running"]')) cf = true;
              } catch(e){}
              if (!v) return JSON.stringify({cf: cf, cfTitle: cfTitle});
              return JSON.stringify({t: v.currentTime, d: v.duration, p: v.paused, cf: cf, cfTitle: cfTitle});
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
            // CF 质询处理：标题已明确是质询页就立即关规则重载一次，不等 25 秒；
            // 标题之外的质询信号（挑战 iframe / cf- 标记）仍走 25 秒兜底。只重载一次。
            let cfRunning = (json["cf"] as? Bool) ?? false
            let cfTitle = (json["cfTitle"] as? Bool) ?? false
            if cfRunning && !self.hasVideo {
                if cfTitle && !self.challengeReloaded {
                    self.challengeReloaded = true
                    self.challengeSince = nil
                    self.reloadWithoutRules()
                } else if !self.challengeReloaded {
                    if self.challengeSince == nil { self.challengeSince = Date() }
                    if let since = self.challengeSince,
                       Date().timeIntervalSince(since) > 25 {
                        self.challengeReloaded = true
                        self.reloadWithoutRules()
                    }
                }
            } else {
                self.challengeSince = nil
            }
            guard json["t"] != nil else {
                self.hasVideo = false
                self.challengeRunning = cfRunning
                return
            }
            self.hasVideo = true
            self.challengeRunning = false
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

    /// CF 卡死兜底：关掉内容屏蔽规则、重载页面（只做一次）。
    private func reloadWithoutRules() {
        guard let webView else { return }
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.reload()
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

/// dood/playmogo 系嵌页家族域名见 PlayerEngine.swift 的 wallEmbedHostFamilies
/// （共用一张表）：主框架导航放行“当前播的嵌页自己的 host（含子域）+ 这些家族
/// host”，广告点一下跳去别的站时拦住；子框架导航一律放行（播放器 iframe 要加载）。
/// 旧版是写死的 7 个 host 全名单：名单外的新嵌页主框架会被拦；现在以模块返回的
/// 嵌页 host（传进来的 url.host，即当前播的 line.url 的 host）为准，家族表只作补充。

/// 嵌入页播放器的 UIViewController：WKWebView 全铺，不带任何按钮。
/// 按钮/底条都在外层 SwiftUI（和直链自定义播放器同一套 PlayerControlBar）。
final class EmbedWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let url: URL
    private let probe: EmbedProbeState
    private let adStrip: Bool
    private var webView: WKWebView?
    private var loadedURL: URL?

    init(url: URL, probe: EmbedProbeState, adStrip: Bool = true) {
        self.url = url
        self.probe = probe
        self.adStrip = adStrip
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
        // 第二层（代理层）拦弹窗：JS 不许自己开新窗口。
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // 第一层：内容屏蔽规则（只拦已知广告域的第三方请求，加载前装好）。
        if adStrip {
            AdBlockRuleStore.install(into: config.userContentController, siteHost: url.host ?? "")
        }
        // 第三层：CF 通过后删广告 DOM + video 打 playsinline（document-start，每秒再扫）。
        if adStrip {
            let script = WKUserScript(source: AdStripScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)
        }

        // 在屏铁律：解流/过墙用的 WebView 必须全尺寸在屏——四边约束铺满父视图，
        // 绝不宽高 0、绝不移出视图树、绝不 alpha=0（隐藏会被质询判 headless 而
        // 无限刷新）。frame 用 .zero 只是建视图时的占位，约束会把它撑满；
        // 要遮住质询页用上层原生 Loading 遮罩（WebViewPlayerView 的 challengeRunning
        // 层）盖住它，而不是隐藏它。只在 teardown 时才移出视图（停播/离开页）。
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

    // MARK: - 第二层：代理层拦弹窗与站外跳转

    /// window.open / target=_blank 的新窗口：一律不建（广告弹窗就死在这里）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    /// 主框架导航：只放行嵌页自己（当前播的嵌页 host 及其子域）或 dood 家各门面；
    /// 广告点一下想把主框架跳去别的站时拦住。子框架导航一律放行（播放器 iframe 要加载）。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let targetFrame = navigationAction.targetFrame, targetFrame.isMainFrame,
              let host = navigationAction.request.url?.host?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let embedHost = url.host?.lowercased() ?? ""
        if host == embedHost
            || (!embedHost.isEmpty && host.hasSuffix("." + embedHost))
            || isWalledEmbedHost(host) {
            decisionHandler(.allow)
            return
        }
        // CF 挑战页也在同 host 上，不会走到这里；走到这里的就是站外跳转，拦掉。
        decisionHandler(.cancel)
    }
}

struct EmbedWebView: UIViewControllerRepresentable {
    let url: URL
    let probe: EmbedProbeState
    /// 是否开广告剥离（默认 true；模块的 adStrip 标记透传到这里，false 就不开）。
    var adStrip: Bool = true

    func makeUIViewController(context: Context) -> EmbedWebViewController {
        EmbedWebViewController(url: url, probe: probe, adStrip: adStrip)
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
/// 广告剥离三层全开（规则 + 代理拦弹窗 + CF 通过后删 DOM）；标题一读到是 CF 质询页
/// 就立即关规则重载一次（25 秒兜底仍在），质询进行中盖一层原生 Loading 遮罩
/// （WebView 本身保持全尺寸在屏、不隐藏）。关闭/离开时停掉 WebView、释放资源。
struct WebViewPlayerView: View {
    let url: URL
    let onClose: () -> Void
    /// 是否开广告剥离（默认 true；DetailView 可把当前线路的 adStrip 传进来）。
    var adStrip: Bool = true

    @StateObject private var probe = EmbedProbeState()

    var body: some View {
        ZStack {
            EmbedWebView(url: url, probe: probe, adStrip: adStrip)
                .onTapGesture { probe.toggleControls() }
            // 质询进行中：原生 Loading 遮罩盖住 WebView（只盖住、不隐藏它——
            // WebView 保持全尺寸在屏，质询才能正常跑完；出 video 后自动撤掉）。
            // 遮罩在控制条之下，关闭/全屏按钮始终可点。
            if probe.challengeRunning {
                ZStack {
                    Color.black.opacity(0.85)
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("正在验证，请稍候…")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                }
            }
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
