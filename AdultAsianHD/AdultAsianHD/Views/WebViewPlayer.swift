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
    /// 正则同时匹配 apex 域（如 https://popads.net/...）与子域
    ///（旧版 ".*\\." + escaped 要求前面必须有个点，apex 域漏拦）。
    static func rulesJSON(forSiteHost host: String) -> String {
        let domains = baseAdDomains + extraDomains(forSiteHost: host)
        let rules: [[String: Any]] = domains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/]+\\.)?" + escaped + "([:/]|$)",
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

    /// shouldInstall：编译完成时再判断一次（CF 兜底关规则后编译才完成时不装回去，
    /// 堵 reloadWithoutRules 与异步编译的竞态；不传则默认装）。
    static func install(into controller: WKUserContentController, siteHost: String, shouldInstall: (() -> Bool)? = nil) {
        if let list = cached {
            // 缓存命中也要尊重 shouldInstall：CF 兜底关规则后才编完的规则不能再装回去。
            if let shouldInstall, !shouldInstall() { return }
            controller.add(list)
            return
        }
        pending.append { list in
            guard let list else { return }
            if let shouldInstall, !shouldInstall() { return }
            controller.add(list)
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
/// 挑战 iframe、cf- 标记，含中文标题“请稍候/正在验证/您是真人吗”），有就跳过这轮、什么都不碰；验证过了才删广告。
/// 删什么：① 假 Download 按钮/弹窗（playmogo 常见悬浮下载框）；
/// ② 覆盖在 <video> 上方的高 z-index 透明点击劫持层（绝不碰 <video> 及其祖先容器与播放器控制条）；
/// ③ 文本命中的广告卡片（录屏里那种 "Your Next Adventure Starts Here!" 旅行卡）；
/// ④ 类名/id 带广告标记的元素；⑤ src 落在广告域的 iframe
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
      var FAKE_DL_RE = /^(fast\\s*)?(free\\s*)?download(\\s*(now|hd|video|app|file|here|free))*\\s*$/i;
      var FAKE_DL_TEXTS = ['高速下载', '立即下载', '免费下载', '下载视频', '极速下载'];
      function cfRunning(){
        try {
          var t = (document.title || '').toLowerCase();
          if (t.indexOf('just a moment') >= 0) return true;
          if (t.indexOf('checking your browser') >= 0) return true;
          if (t.indexOf('请稍候') >= 0) return true;
          if (t.indexOf('正在验证') >= 0) return true;
          if (t.indexOf('您是真人吗') >= 0) return true;
          if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) return true;
          if (document.querySelector('iframe[src*="turnstile"]')) return true;
          if (document.querySelector('[id*="cf-"], [class*="cf-challenge"], [class*="challenge-running"], [class*="turnstile"]')) return true;
        } catch(e){}
        return false;
      }
      function hasVideoInside(el){
        return el && (el.tagName === 'VIDEO' || (el.querySelector && el.querySelector('video')));
      }
      function isAdSrc(u){
        if (!u) return false;
        u = String(u).toLowerCase();
        for (var i = 0; i < AD_DOMAINS.length; i++) {
          if (u.indexOf(AD_DOMAINS[i]) >= 0) return true;
        }
        return false;
      }
      function isFakeDownloadLabel(label){
        var s = (label || '').trim();
        if (s.length === 0 || s.length > 28) return false;
        if (FAKE_DL_RE.test(s)) return true;
        for (var i = 0; i < FAKE_DL_TEXTS.length; i++) {
          if (s === FAKE_DL_TEXTS[i]) return true;
        }
        return false;
      }
      function hideEl(el){
        try {
          el.style.setProperty('display', 'none', 'important');
          el.style.setProperty('pointer-events', 'none', 'important');
        } catch(e){}
      }
      function stripOnce(){
        if (cfRunning()) return;
        try {
          // 1. 假 Download 按钮/弹窗（playmogo 常见悬浮下载框）：往上找
          // fixed/absolute 定位的弹窗容器一起藏（最多 3 层），绝不碰含 video 的祖先。
          var clickables = document.querySelectorAll('a, button, div[role="button"]');
          for (var d = 0; d < clickables.length; d++) {
            var c = clickables[d];
            if (hasVideoInside(c)) continue;
            var label = (c.innerText || c.textContent || '').trim();
            if (isFakeDownloadLabel(label)) {
              var box = c;
              for (var up = 0; up < 3 && box.parentElement; up++) {
                var p = box.parentElement;
                if (hasVideoInside(p)) break;
                var ps = getComputedStyle(p);
                if (ps.position === 'fixed' || ps.position === 'absolute') { box = p; }
              }
              hideEl(box);
            }
          }
          // 2. 覆盖在视频上的透明点击劫持层（不碰 video 及常见播放器控制条）。
          var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
          if (vw > 0 && vh > 0 && document.querySelector('video')) {
            var overlays = document.querySelectorAll('div, a');
            for (var o = 0; o < overlays.length; o++) {
              var ov = overlays[o];
              if (hasVideoInside(ov)) continue;
              var cls = String(ov.className || '').toLowerCase();
              if (cls.indexOf('plyr') >= 0 || cls.indexOf('vjs') >= 0 || cls.indexOf('player') >= 0 || cls.indexOf('control') >= 0) continue;
              var st = getComputedStyle(ov);
              if (st.position !== 'fixed' && st.position !== 'absolute') continue;
              var z = parseInt(st.zIndex, 10);
              if (!isFinite(z) || z < 100) continue;
              var rect = ov.getBoundingClientRect();
              if (rect.width >= vw * 0.5 && rect.height >= vh * 0.5) {
                var txtLen = (ov.innerText || '').trim().length;
                if (ov.tagName === 'A' || txtLen === 0 || isFakeDownloadLabel(ov.innerText || '')) {
                  hideEl(ov);
                }
              }
            }
          }
          // 3. 文本命中的广告卡片：往上找带关闭按钮/卡片样的容器一起藏（最多 4 层）。
          var all = document.querySelectorAll('div, section, aside, article');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            if (hasVideoInside(el)) continue;
            var txt = el.textContent || '';
            for (var k = 0; k < AD_TEXTS.length; k++) {
              if (txt.indexOf(AD_TEXTS[k]) >= 0 && txt.length < 500) {
                var node = el;
                for (var up2 = 0; up2 < 4 && node; up2++) {
                  if (hasVideoInside(node)) break;
                  if (node.querySelector && node.querySelector('[aria-label*="lose" i], [class*="close" i], [id*="close" i]')) { hideEl(node); break; }
                  node = node.parentElement;
                }
                if (up2 >= 4) hideEl(el);
                break;
              }
            }
          }
          // 4. 类名/id 带广告标记的元素（不碰 video、播放器、CF）。
          var ads = document.querySelectorAll('[id*="ad-"], [id*="-ad-"], [class*="ad-banner"], [class*="ad-popup"], [class*="advertisement"], [class*="ads-container"], [class*="popunder"], [class*="overlay-ad"]');
          for (var j = 0; j < ads.length; j++) {
            if (hasVideoInside(ads[j])) continue;
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

/// 找页内 video 的 JS 片段（run #20 F5）：先查顶层 document，再查每个同源 iframe
/// 的 contentDocument（跨域 iframe 读不到，try/catch 跳过）；播放器常把 video
/// 藏在同源 iframe 里，只查顶层会漏。探针、播放/暂停、快进、全屏、零播踢一下共用。
/// 注意：里面不能出现反引号或 ${}（会被 Swift 多行字符串插值误认）。
private let findVideoJS = """
(function(){
  var v = document.querySelector('video');
  if (v) return v;
  var frames = document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    try {
      var doc = frames[i].contentDocument;
      if (!doc) continue;
      var inner = doc.querySelector('video');
      if (inner) return inner;
    } catch (e) {}
  }
  return null;
})()
"""

/// JS 探针状态：每 0.5 秒读一次页内第一个 video 元素的 currentTime/duration/paused。
/// 探不到 video（跨域 iframe、还没加载出 video）时 hasVideo=false，外层只显示状态文案。
/// 嵌页自己的播放控制不动（页内播放器照常用）；外层底条只是多一套统一外观的操作入口。
/// 底条显隐也放这里管（@MainActor 类，Task 写起来安全；View struct 里写 Task 容易踩并发坑）。
/// 另管 CF 卡死兜底：所有质询信号（标题 "Just a moment"、挑战 iframe、
/// cf- 标记、turnstile）统一等 12 秒，让挑战 JS 自己完成；12 秒还没出
/// video 才关规则重载一次。只重载一次。
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
    /// 回调通知容器禁用广告规则（防止异步编译完成后把刚移除的规则又装回去）。
    var onDisableAdRules: (() -> Void)?
    /// 页内 video 真在播时调一次（有 video、没暂停、时间在走）：外层据此调
    /// ViewModel.markPlaying()，账本才有“播放中”的终局。注意：只报“真在播”，
    /// 不报“WebView 接手了”——接手不等于播出（挑战页也会接手）。
    var onPlaying: (() -> Void)?
    /// 嵌页终局失败时调一次（run #20 F3 看门狗）：外层据此调
    /// ViewModel.markEmbedFailed(reason)，状态变 .failed + 给重试按钮。
    /// 只报一次（同一 URL）；切 URL 时 stop() 清掉，下个 URL 重新计时。
    var onEmbedFailed: ((String) -> Void)?
    /// 底条显示的真实阶段（run #20 F2）：再也不写死“嵌入播放中”。
    /// hasVideo → 在播；challengeRunning → 正在验证；warmingUp → 正在预热；
    /// pageLoaded（页已载完仍没 video）→ 已加载未出画面；failed → 失败；
    /// 其余 → 正在加载。
    var statusText: String {
        if failedReported { return "嵌入播放失败" }
        if hasVideo { return "嵌入播放中" }
        if challengeRunning { return "正在验证…" }
        if warmingUp { return "正在预热验证…" }
        if pageLoaded { return "已加载，未出画面" }
        return "正在加载…"
    }
    /// 预热是不是正在跑（控制器在 ensureClearance 期间置 true，完事置 false）。
    @Published var warmingUp = false
    /// 主框架是不是已载完（控制器 didFinish 置 true，失败置 false）。
    @Published var pageLoaded = false
    /// 本 URL 是否已报过一次 onPlaying（切 URL 时 stop() 清掉，下个 URL 重新报）。
    private var playingReported = false
    /// 上次探到的 currentTime：时间往前走了才算“在播”。
    private var lastPlayingTime: Double = 0
    private var timer: Timer?
    private var hideTask: Task<Void, Never>?
    private var wasPaused = true
    private var isScrubbing = false
    /// 拖进度条松手后 1.2 秒内探针不回写 currentTime（页内 video 还没 seek 完，
    /// 回写会把用户刚拖到的时间又 snap 回旧时间）。
    private var scrubLockUntil = Date.distantPast
    /// video 卡在 0:00 且暂停的首见时间；2 秒后只踢一次 play()。
    private var zeroVideoSeenAt: Date?
    private var didNudgeZeroPlay = false
    /// CF 挑战第一次被看到的时间；challengeReloaded=true 表示兜底已用过一次。
    private var challengeSince: Date?
    private var challengeReloaded = false
    /// 看门狗（run #20 F3）：loadStartedAt 是本页开始探的时间；
    /// lastVideoSeenAt 是上次探到 video 的时间（video 一度出现又消失时，
    /// 从消失算起）；reloadAt 是 12 秒兜底重载的时间；failedReported 保证
    /// 终局失败只报一次。
    private var loadStartedAt: Date?
    private var lastVideoSeenAt: Date?
    private var reloadAt: Date?
    private var failedReported = false

    func start() {
        stop()
        loadStartedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probe() }
        }
    }

    /// 停探针：切线路/切视频时必须把整套状态清干净再重新开始，
    /// 不然 Line B 会沿用 Line A 的 challengeReloaded/challengeSince/hasVideo，
    /// CF 兜底逻辑直接跳过（Line B 的挑战永远不触发）。
    /// start() 开头会调 stop()，所以每次开始都是干净状态。
    func stop() {
        timer?.invalidate()
        timer = nil
        hideTask?.cancel()
        hideTask = nil
        isScrubbing = false
        scrubLockUntil = .distantPast
        didNudgeZeroPlay = false
        zeroVideoSeenAt = nil
        challengeRunning = false
        challengeReloaded = false
        challengeSince = nil
        loadStartedAt = nil
        lastVideoSeenAt = nil
        reloadAt = nil
        failedReported = false
        warmingUp = false
        pageLoaded = false
        hasVideo = false
        currentTime = 0
        duration = 0
        wasPaused = true
        paused = true
        playingReported = false
        lastPlayingTime = 0
    }

    private func probe() {
        guard let webView else { return }
        webView.evaluateJavaScript(
            """
            (function(){
              var v = \(findVideoJS);
              var cf = false;
              var cfTitle = false;
              try {
                var t = (document.title || '').toLowerCase();
                if (t.indexOf('just a moment') >= 0 || t.indexOf('checking your browser') >= 0
                    || t.indexOf('请稍候') >= 0 || t.indexOf('正在验证') >= 0 || t.indexOf('您是真人吗') >= 0) { cf = true; cfTitle = true; }
                if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) cf = true;
                if (document.querySelector('iframe[src*="turnstile"]')) cf = true;
                if (document.querySelector('[id*="cf-"], [class*="cf-challenge"], [class*="challenge-running"], [class*="turnstile"]')) cf = true;
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
            // CF 质询处理：所有质询信号统一等 12 秒，让挑战 JS 自己完成
            //（iframe 里的勾选框我们点不到，立即 reload 会破坏挑战会话）；
            // 12 秒还没出 video 才关规则重载一次。只重载一次。
            let cfRunning = (json["cf"] as? Bool) ?? false
            if cfRunning && !self.hasVideo {
                if self.challengeSince == nil { self.challengeSince = Date() }
                if let since = self.challengeSince,
                   !self.challengeReloaded,
                   Date().timeIntervalSince(since) >= 12 {
                    self.challengeReloaded = true
                    self.reloadWithoutRules()
                }
            } else {
                self.challengeSince = nil
            }
            // 看门狗（run #20 F3）：没 video 一直拖着就终局失败，不让白屏无限转。
            self.checkWatchdog(challengeRunning: cfRunning)
            guard json["t"] != nil else {
                self.hasVideo = false
                self.challengeRunning = cfRunning
                return
            }
            self.hasVideo = true
            self.lastVideoSeenAt = Date()
            self.challengeRunning = false
            // 拖进度条锁：松手后 1.2 秒内不回写，避免探针把用户刚拖到的时间
            // 又 snap 回页内 video 还没 seek 完的旧时间。
            if !self.isScrubbing && Date() > self.scrubLockUntil {
                self.currentTime = (json["t"] as? Double) ?? 0
            }
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
            // video 一直在 0:00 且已暂停：2 秒后只踢一次 play()。
            // 嵌页播放器常有"点了播放却停在 0:00"的假死，踢一次即可。
            let t = (json["t"] as? Double) ?? 0
            if t < 0.5 && nowPaused {
                if self.zeroVideoSeenAt == nil { self.zeroVideoSeenAt = Date() }
                let seenFor = Date().timeIntervalSince(self.zeroVideoSeenAt ?? Date())
                if !self.didNudgeZeroPlay && seenFor >= 2 {
                    self.didNudgeZeroPlay = true
                    webView.evaluateJavaScript(
                        "var v=\(findVideoJS); if(v){ var p=v.play(); if(p && p.catch) p.catch(function(){}); }",
                        completionHandler: nil
                    )
                }
            } else {
                self.zeroVideoSeenAt = nil
            }
            // 页内 video 真在播（有 video、没暂停、时间在往前走）：报一次 onPlaying，
            // 外层调 markPlaying()，账本终局为“播放中”。只报一次（同一 URL）；
            // 挑战页/停着的 video 不报；拖动时 currentTime 冻结，不会误报。
            if !nowPaused, !self.playingReported {
                let t = self.currentTime
                if t > self.lastPlayingTime {
                    self.playingReported = true
                    self.onPlaying?()
                }
                self.lastPlayingTime = t
            }
        }
    }

    /// 看门狗（run #20 F3）：没 video 一直拖着就终局失败，不让白屏无限转。
    /// - 挑战在跑：重载后 15 秒仍没 video，或挑战从头到尾跑满 45 秒没 video → 失败；
    /// - 没挑战也没 video：重载后 15 秒仍没 video → 失败；从没重载过 → 45 秒没 video → 失败
    ///   （video 一度出现过：从上次见到它算起 45 秒）。
    /// 终局失败只报一次（failedReported），外层经 onEmbedFailed → markEmbedFailed，
    /// 状态变 .failed + 给重试按钮；探针计时器本身不停（重试后同一探针继续探）。
    private func checkWatchdog(challengeRunning cfRunning: Bool) {
        guard !hasVideo, !failedReported, loadStartedAt != nil else { return }
        if cfRunning {
            if let since = challengeSince,
               Date().timeIntervalSince(since) >= 45 {
                failEmbed("Cloudflare 验证一直没通过（45 秒），请开节点或点重试")
            }
            return
        }
        if let reloadedAt = reloadAt {
            if Date().timeIntervalSince(reloadedAt) >= 15 {
                failEmbed("嵌页加载超时，重载后一直没出画面，请点重试")
            }
        } else if let lastSeen = lastVideoSeenAt {
            if Date().timeIntervalSince(lastSeen) >= 45 {
                failEmbed("嵌页加载超时，一直没出画面，请点重试")
            }
        } else if let started = loadStartedAt,
                  Date().timeIntervalSince(started) >= 45 {
            failEmbed("嵌页加载超时，一直没出画面，请点重试")
        }
    }

    private func failEmbed(_ reason: String) {
        guard !failedReported else { return }
        failedReported = true
        onEmbedFailed?(reason)
    }

    /// CF 卡死兜底：关掉内容屏蔽规则、重载页面（只做一次），并记一条 WAF 诊断。
    private func reloadWithoutRules() {
        guard let webView else { return }
        onDisableAdRules?()
        reloadAt = Date()
        webView.configuration.userContentController.removeAllContentRuleLists()
        if let currentURL = webView.url {
            let event = NetworkDiagEvent(
                id: UUID(),
                at: Date(),
                source: "webview",
                method: "GET",
                host: currentURL.host ?? "",
                sanitizedPath: NetworkDiagEvent.sanitizePath(from: currentURL),
                networkClass: PlaybackLedger.networkClass,
                phase: .waf,
                statusCode: 403,
                errorDomain: nil,
                errorCode: nil,
                errorSummary: "嵌页触发 Cloudflare 质询，已关规则重载",
                remoteAddress: nil,
                protocolName: nil,
                reusedConnection: false,
                proxyConnection: false,
                dnsMs: nil,
                tcpMs: nil,
                tlsMs: nil,
                ttfbMs: nil,
                totalMs: 0
            )
            NetworkDiagnostics.record(event)
        }
        webView.reload()
    }

    /// 外层底条的播放/暂停：直接调页内 video 的 play()/pause()。
    func togglePlayPause() {
        webView?.evaluateJavaScript(
            """
            (function(){ var v = \(findVideoJS); if (!v) return; if (v.paused) { v.play(); } else { v.pause(); } })();
            """,
            completionHandler: nil
        )
    }

    /// 拖动开始：冻结探针对 currentTime 的回写，保持底条常显。
    func beginScrub() {
        isScrubbing = true
        hideTask?.cancel()
        controlsVisible = true
    }

    /// 拖动中：只更新本地时间显示，不向 WKWebView 狂发 JS seek。
    func scrub(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        currentTime = min(max(seconds, 0), duration)
    }

    /// 松手：只发一次 JS seek；松手后 1.2 秒内探针不回写 currentTime
    ///（页内 video 还没 seek 完，回写会把刚拖到的时间 snap 回旧时间）。
    func endScrub(to seconds: Double) {
        isScrubbing = false
        scrubLockUntil = Date().addingTimeInterval(1.2)
        guard seconds.isFinite else { return }
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        currentTime = clamped
        seek(to: clamped)
        showControlsTemporarily()
    }

    /// 外层进度条快进：直接设页内 video 的 currentTime（播着就继续播，停着就停着）。
    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        webView?.evaluateJavaScript(
            """
            (function(){ var v = \(findVideoJS); if (!v) return; v.currentTime = \(seconds); })();
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
              var v = \(findVideoJS);
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
final class EmbedWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    private let url: URL
    private let probe: EmbedProbeState
    private let adStrip: Bool
    private var webView: WKWebView?
    private var loadedURL: URL?
    private var navigationStartAt: Date?
    /// CF 兜底已关过广告规则：为 true 后不再装规则（堵异步编译完成又把规则装回去的竞态）。
    private var adRulesDisabled = false

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
            AdBlockRuleStore.install(into: config.userContentController, siteHost: url.host ?? "") { [weak self] in
                !(self?.adRulesDisabled ?? true)
            }
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
        probe.onDisableAdRules = { [weak self] in
            self?.adRulesDisabled = true
        }

        // 原生点按手势（系统级，穿透覆盖层）：点画面切换底条显隐。
        // 绝不用 SwiftUI .onTapGesture——WKWebView 的内层手势会把它整个吃掉。
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleWebViewTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)

        loadIfNeeded(url: url)
    }

    @objc private func handleWebViewTap() {
        probe.toggleControls()
    }

    // 绝不抢 WKWebView 内层手势（播放器按钮/进度条照常用）：两个手势同时识别。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// URL 不变不重载，避免 SwiftUI 刷新时打断正在播的嵌入页。
    /// 只做 URL 加载：探针 reset 不在这里做（SwiftUI 更新期调它会改
    /// @Published，撞上视图更新）；切 URL 时 WebViewPlayerView 的
    /// .onChange(of: url) 会调 probe.stop()/start()。
    /// run #20 F2：/e/ URL 立即在播放 WebView 里加载，不再等 30 秒预热门；
    /// 预热只在后台并行跑（给播放 WebView 预种 cf_clearance cookie，
    /// 完事不改已在加载的页面）。以前：没 clearance 就先暖 3×10 秒，
    /// 暖完才加载——白屏 10–30 秒就是这么来的。
    func loadIfNeeded(url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        navigationStartAt = Date()
        // 上一页关掉广告规则后换了新 URL：规则重新开，新的一页重新评估。
        adRulesDisabled = false
        probe.pageLoaded = false
        // 立即加载（不等预热）。
        load(request: url)
        // 预热并行跑：只做 cookie 预种，不挡加载、不改页面。
        if let host = url.host, CloudflareWarmup.needsWarmup(host: host) {
            probe.warmingUp = true
            CloudflareWarmup.shared.ensureClearance(for: host, webView: webView, container: view) { [weak self] in
                self?.probe.warmingUp = false
            }
        }
    }

    private func load(request url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.assumesHTTP3Capable = false
        webView?.load(request)
    }

    /// 停掉 WebView、释放资源（关闭 / 离开详情页时调）：先摘代理，再停加载、清页面、移出视图。
    func teardown() {
        // 先摘代理（再有回调也不进来），再停加载、清页面、移出视图。
        // 顺序反了会崩：stopLoading 期间的回调走到已释放的 delegate。
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        probe.webView = nil
        probe.onDisableAdRules = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
        loadedURL = nil
    }

    deinit {
        teardown()
    }

    // MARK: - 第二层：代理层拦弹窗、站外跳转与网络诊断记录

    /// window.open / target=_blank 的新窗口：一律不建（广告弹窗就死在这里）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 主框架载完：探针的状态文案可以从“正在加载…”变成“已加载，未出画面”。
        probe.pageLoaded = true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStartAt = Date()
        if adRulesDisabled {
            webView.configuration.userContentController.removeAllContentRuleLists()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavigationError(error, url: webView.url ?? loadedURL ?? url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationError(error, url: webView.url ?? loadedURL ?? url)
    }

    private func recordNavigationError(_ error: Error, url: URL) {
        probe.pageLoaded = false
        let nsErr = error as NSError
        // WKErrorCodeFrameLoadInterruptedByPolicyChange (102) 或 NSURLErrorCancelled (-999) 是正常切页/拦截，不刷屏
        if nsErr.code == NSURLErrorCancelled || (nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102) {
            return
        }
        let elapsedMs = navigationStartAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let event = NetworkDiagnostics.makeEvent(
            source: "webview",
            request: URLRequest(url: url),
            response: nil,
            bodyData: nil,
            error: error,
            metrics: nil,
            fallbackDurationMs: elapsedMs
        )
        NetworkDiagnostics.record(event)
    }

    /// 主框架导航：只放行嵌页自己（当前播的嵌页 host 及其子域）或 dood 家各门面；
    /// 广告点一下想把主框架跳去别的站时拦住。子框架导航一律放行（播放器 iframe 要加载）。
    /// window.open / target=_blank 的新窗口（targetFrame == nil）一律拦；
    /// 非 http(s)（tel:、mailto:、intent: …）一律拦，about:/blob:/data: 放行
    ///（播放器内部偶尔用它们，拦了会断播）。
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let requestURL = navigationAction.request.url,
              let scheme = requestURL.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        guard scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme == "data" else {
            decisionHandler(.cancel)
            return
        }
        guard let targetFrame = navigationAction.targetFrame else {
            // targetFrame == nil：window.open / target=_blank 弹窗，一律拦。
            decisionHandler(.cancel)
            return
        }
        guard targetFrame.isMainFrame, let host = requestURL.host?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        let embedHost = (loadedURL ?? url).host?.lowercased() ?? ""
        if host == embedHost
            || (!embedHost.isEmpty && host.hasSuffix("." + embedHost))
            || host == "challenges.cloudflare.com"
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
/// 广告剥离三层全开（规则 + 代理拦弹窗 + CF 通过后删 DOM）；质询信号出现后统一等
/// 12 秒才关规则重载（只一次），质询进行中顶部只飘一枚小胶囊提示
/// （WebView 本身保持全尺寸在屏、不隐藏、不拦手势）。关闭/离开时停掉 WebView、释放资源。
struct WebViewPlayerView: View {
    let url: URL
    let onClose: () -> Void
    /// 是否开广告剥离（默认 true；DetailView 可把当前线路的 adStrip 传进来）。
    var adStrip: Bool = true
    /// 页内 video 真在播时调一次（有 video、没暂停、时间在走）：外层据此
    /// 调 ViewModel.markPlaying()。只报真在播，不报“WebView 接手了”。
    var onPlaying: (() -> Void)? = nil
    /// 嵌页终局失败时调一次（探针看门狗）：外层据此调 ViewModel.markEmbedFailed(reason)。
    var onEmbedFailed: ((String) -> Void)? = nil
    /// 嵌入重试计数（DetailView 从 ViewModel 传）：变了就把探针整套状态清掉重开，
    /// 同一 URL 重试也有新鲜的看门狗窗口。
    var retryNonce: Int = 0

    @StateObject private var probe = EmbedProbeState()

    var body: some View {
        ZStack {
            EmbedWebView(url: url, probe: probe, adStrip: adStrip)
            // 质询进行中：顶部小胶囊提示，不盖全屏、不拦手势
            //（Cloudflare 复选框在下面，用户要能点到“我是人类”；
            // 点画面切底条显隐走 WKWebView 上的原生手势，不走 SwiftUI
            // .onTapGesture——内层手势会把它整个吃掉）。
            if probe.challengeRunning {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("正在验证，如出现勾选框请点击完成")
                            .font(.subheadline)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
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
                        statusText: probe.statusText,
                        onPlayPause: { probe.togglePlayPause() },
                        onScrubStart: { probe.beginScrub() },
                        onScrub: { probe.scrub(to: $0) },
                        onScrubEnd: { probe.endScrub(to: $0) }
                    )
                }
            }
        }
        .background(Color.black)
        .onAppear {
            probe.onPlaying = onPlaying
            probe.onEmbedFailed = onEmbedFailed
            probe.start()
            probe.showControlsTemporarily()
        }
        .onChange(of: url) { _, _ in
            // 切 URL = 新的一页：探针整套状态清掉重开（challengeReloaded、
            // hasVideo、playingReported 都归零），不然 Line B 沿用 Line A
            // 的状态，CF 兜底跳过、markPlaying 也不再报。
            // 放这里不放 loadIfNeeded：SwiftUI 更新期改 @Published 会撞上视图更新。
            probe.stop()
            probe.start()
        }
        .onChange(of: retryNonce) { _, _ in
            // 同一 URL 点“重试嵌入播放”：探针也清掉重开（看门狗的
            // failedReported/loadStartedAt/challengeReloaded 归零），
            // 不然重试后 45 秒窗口早已过期、挑战兜底也用过了。
            probe.stop()
            probe.start()
        }
        .onDisappear {
            probe.stop()
        }
    }
}
