import Foundation
import WebKit

/// 解流得到的直链：交给现有 AVPlayer 通路播（快进、跟手进度条还是原生的）。
/// referer 是嵌入页地址，AVPlayer 取流时带 Referer（dood/playmogo 的 CDN 常要这个）。
struct ExtractedStream {
    let url: URL
    let referer: URL
}

/// 混合解流（优先路径）：无界面 WKWebView 加载嵌入页（playmogo/dood 这类），
/// 等页内 video 元素出 src，或拦截到 .m3u8/.mp4 请求，把直链抽出来交给 AVPlayer。
/// WKWebView 是真浏览器，能过 Cloudflare 挑战（URLSession 直拉会被 403 拦住）。
/// dood/playmogo 要点一下播放按钮才去拉流：加载完就试着点播（只点 play 字样的按钮），
/// 点完 8 秒还没抽到直链就提前收尾，不等满 15 秒；15 秒是绝对超时。
/// 页内无 video、CF 一直拦 → 返回 nil，调用方 fallback 到页内 WebView 播放器。
/// 只在主线程用（WKWebView 只认主线程）；调用方（PlayerViewModel）本身就是 @MainActor。
@MainActor
final class EmbedStreamExtractor: NSObject {

    /// 解流超时：15 秒。CF 挑战一般几秒内自己解完，留足余量。
    private static let timeoutSeconds: UInt64 = 15
    private static let messageHandlerName = "mediaFound"

    /// document-start 注入：hook fetch / XHR.open / video.src / source.src，
    /// 直链一出现就经 mediaFound 上报；再每秒扫一次页内 video/source。
    /// 只上报，不改页面行为（原函数都原样调回）。
    private static let captureScript = """
    (function(){
      function isMedia(u){
        if(!u) return false;
        u = String(u).toLowerCase();
        if(u.indexOf('blob:') === 0) return false;
        return u.indexOf('.m3u8') >= 0 || u.indexOf('.mp4') >= 0 || u.indexOf('.mpd') >= 0;
      }
      function report(u){
        try { if(isMedia(u)) window.webkit.messageHandlers.mediaFound.postMessage(String(u)); } catch(e){}
      }
      try {
        var ofetch = window.fetch;
        window.fetch = function(){
          try { var a = arguments[0]; var u = (typeof a === 'string') ? a : (a && a.url); report(u); } catch(e){}
          return ofetch.apply(this, arguments);
        };
      } catch(e){}
      try {
        var oopen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m, u){
          try { report(u); } catch(e){}
          return oopen.apply(this, arguments);
        };
      } catch(e){}
      try {
        var vdesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
        if(vdesc && vdesc.set){
          Object.defineProperty(HTMLMediaElement.prototype, 'src', {
            set: function(v){ report(v); vdesc.set.call(this, v); },
            get: function(){ return vdesc.get ? vdesc.get.call(this) : ''; },
            configurable: true
          });
        }
      } catch(e){}
      try {
        var sdesc = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, 'src');
        if(sdesc && sdesc.set){
          Object.defineProperty(HTMLSourceElement.prototype, 'src', {
            set: function(v){ report(v); sdesc.set.call(this, v); },
            get: function(){ return sdesc.get ? sdesc.get.call(this) : ''; },
            configurable: true
          });
        }
      } catch(e){}
      function scan(){
        try {
          var vs = document.querySelectorAll('video');
          for(var i=0;i<vs.length;i++){ report(vs[i].currentSrc || vs[i].src); }
          var ss = document.querySelectorAll('source[src]');
          for(var j=0;j<ss.length;j++){ report(ss[j].src); }
        } catch(e){}
      }
      scan();
      setInterval(scan, 1000);
    })();
    """

    private let embedURL: URL
    private var webView: WKWebView?
    private var messageHandler: MediaMessageHandler?
    private var continuation: CheckedContinuation<ExtractedStream?, Never>?
    private var finished = false
    private var timeoutTask: Task<Void, Never>?
    /// 最后一次页面加载完成的时间（CF 挑战解完会重载，每次重载都刷新；
    /// 用它判断“页面是不是已经 settled、再等也没新东西”）。
    private var lastSettledAt: Date?
    /// 第一次尝试点播放的时间（见 attemptClick）。
    private var firstClickAt: Date?
    /// 点播放尝试次数（最多 3 次，播按钮可能晚出现）。
    private var clickAttempts = 0
    /// 快速失败检查：点播放后 8 秒还没抽到直链就提前收尾，不用等满 15 秒。
    private var settleTask: Task<Void, Never>?

    /// 点播放脚本：dood/playmogo 这类嵌页要用户点一下播放按钮才去拉流，
    /// 不点就永远不出 .m3u8——以前的解流就是这么空等满 15 秒的。
    /// 先调 video.play()（最安全，不点广告），没有 video 再点播放按钮
    /// （只认 play 字样的按钮/海报层，不点别的链接，防点到广告跳转）。
    /// 返回非空=点到了（或调了 play），调用方据此开始算快速失败的 8 秒。
    private static let clickPlayScript = """
    (function(){
      try {
        var v = document.querySelector('video');
        if (v) { try { v.play(); } catch(e){} return 'video-play'; }
        var sels = ['.vjs-big-play-button', '.jw-display-icon', '[class*="big-play"]',
                    '[class*="play-button"]', 'button[aria-label*="Play" i]',
                    'button[title*="Play" i]', '.play-btn', '#playBtn',
                    '[class*="poster"]', '[id*="poster"]'];
        for (var i = 0; i < sels.length; i++) {
          var el = document.querySelector(sels[i]);
          if (el && el.offsetParent !== null) { el.click(); return 'clicked:' + sels[i]; }
        }
      } catch(e){}
      return '';
    })();
    """

    init(embedURL: URL) {
        self.embedURL = embedURL
        super.init()
    }

    /// 加载嵌入页并等直链。15 秒内没抽到返回 nil（不抛错，由调用方 fallback）。
    func extract() async -> ExtractedStream? {
        await withCheckedContinuation { (cont: CheckedContinuation<ExtractedStream?, Never>) in
            self.continuation = cont
            self.start()
        }
    }

    /// 取消（换线/停播时调）：停掉加载、清掉 WebView，等待中的 extract 立即返回 nil。
    func cancel() {
        finish(with: nil)
    }

    // MARK: - 启动与收尾

    private func start() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 抓流脚本（document-start，含 iframe）：hook fetch/XHR/video.src/source.src，
        // 扫到直链就上报；再每秒扫一次页内 video/source（迟加入 DOM 的也抓得到）。
        let script = WKUserScript(source: Self.captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        let handler = MediaMessageHandler()
        handler.extractor = self
        config.userContentController.add(handler, name: Self.messageHandlerName)
        messageHandler = handler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = NetConstants.iPhoneUserAgent
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: embedURL))

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            self?.finish(with: nil)
        }
        // 快速失败：页面 settled 且已点过播放，8 秒还没抽到直链就提前收尾
        // （dood 这类要点播才出流的站，点完 8 秒没出就不会出了；不等满 15 秒）。
        // CF 挑战会重载页面，每次 didFinish 都刷新 lastSettledAt，时钟重算，
        // 所以挑战慢也不会被误杀；15 秒绝对超时仍在。
        settleTask = Task { [weak self] in
            var ticks = 0
            while let self, !self.finished {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !self.finished else { return }
                ticks += 1
                // 播按钮可能晚出现：每 2 秒补点一次（attemptClick 自己限 3 次）。
                if ticks % 2 == 0 { self.attemptClick() }
                if let clicked = self.firstClickAt, let settled = self.lastSettledAt {
                    let since = Date().timeIntervalSince(max(clicked, settled))
                    if since > 8 {
                        self.finish(with: nil)
                        return
                    }
                }
            }
        }
    }

    /// 只认第一次（抽到/超时/取消谁先到算谁），continuation 恰好 resume 一次。
    private func finish(with stream: ExtractedStream?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        settleTask?.cancel()
        settleTask = nil
        teardownWebView()
        let cont = continuation
        continuation = nil
        cont?.resume(returning: stream)
    }

    /// 停加载、摘掉脚本消息 handler、释放 WebView（避免循环引用与后台继续跑）。
    private func teardownWebView() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        messageHandler = nil
    }

    // MARK: - 候选直链

    /// 收到一个候选地址：是直链（.m3u8/.mp4/.mpd，非 blob）就抽走收尾。
    /// 相对地址按嵌入页补全；第一个命中的直链即采用。
    fileprivate func considerCandidate(_ urlString: String) {
        guard !finished else { return }
        let lower = urlString.lowercased()
        guard lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".mpd") else { return }
        guard !lower.hasPrefix("blob:") else { return }
        let resolved = URL(string: urlString, relativeTo: embedURL)?.absoluteURL
        guard let url = resolved, url.scheme == "http" || url.scheme == "https" else { return }
        finish(with: ExtractedStream(url: url, referer: embedURL))
    }

    /// 导航直接跳到直链（如嵌入页 302 到 .m3u8）：抽走并取消导航。
    private func isMediaNavigationURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        return lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".mpd")
    }

    /// 页加载完再扫一次 video/source（document-start 的脚本可能漏掉迟加入的），
    /// 并试着点一下播放（dood/playmogo 要点播才出流；点到了就开始算 8 秒快速失败）。
    private func scanForVideoElements() {
        lastSettledAt = Date()
        let js = """
        (function(){
          var out=[];
          var vs=document.querySelectorAll('video');
          for(var i=0;i<vs.length;i++){ var s=vs[i].currentSrc||vs[i].src; if(s) out.push(s); }
          var ss=document.querySelectorAll('source[src]');
          for(var j=0;j<ss.length;j++){ out.push(ss[j].src); }
          return out.join('\\n');
        })();
        """
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            for line in text.split(separator: "\n") {
                self.considerCandidate(String(line))
            }
        }
        attemptClick()
    }

    /// 试着点播放（最多 3 次：播按钮可能晚出现，didFinish 和 settle 循环都会调）。
    /// 点到了记 firstClickAt（快速失败的时钟起点）；点一次没点到不记，等下次。
    private func attemptClick() {
        guard !finished, clickAttempts < 3 else { return }
        clickAttempts += 1
        webView?.evaluateJavaScript(Self.clickPlayScript) { [weak self] result, _ in
            guard let self, !self.finished else { return }
            if let text = result as? String, !text.isEmpty, self.firstClickAt == nil {
                self.firstClickAt = Date()
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension EmbedStreamExtractor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, isMediaNavigationURL(url) {
            considerCandidate(url.absoluteString)
            // 已经抽到就取消这次导航（不进播放器）；还没抽到也放行，让页面继续跑。
            decisionHandler(finished ? .cancel : .allow)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // CF 挑战页（"Just a moment..."）也会走到这里：不等它报错，
        // 挑战解完页面会重载，继续等直链或等 15 秒超时。
        scanForVideoElements()
    }
}

/// 脚本消息 handler：WKWebView 强持有它，所以这里只弱持有 extractor，防循环引用。
private final class MediaMessageHandler: NSObject, WKScriptMessageHandler {
    weak var extractor: EmbedStreamExtractor?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mediaFound",
              let urlString = message.body as? String else { return }
        extractor?.considerCandidate(urlString)
    }
}
