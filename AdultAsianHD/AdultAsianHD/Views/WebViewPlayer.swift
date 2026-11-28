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
/// 整体 @MainActor：cached/compiling/pending 是跨多次 install 共享的可变静态状态，
/// 调用方全在主线程（EmbedWebViewController.viewDidLoad / loadIfNeeded），
/// 隔离钉死，避免后台回调与主线程同时改 pending 表。
@MainActor
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

/// 广告 DOM 清理脚本（document-start 注入，主框架 + 子框架都跑，每帧独立实例）。
/// run #23 (v13)：共享 Cloudflare 门只停挑战文档本身（同 URL 的 403/503 挑战页
/// 也能认出来）；挑战 iframe 残留在 DOM 里不再杀掉 v5——改成按元素保护（是挑战
/// 组件、包在挑战里、或包着挑战的候选卡才不碰）；v5 不再用 display:none 覆盖
/// v10 已裁切的卡（一卡只归一个清理器）；新分类器治两张新卡——假下载进度卡
/// （D1 有进度结构才藏，D2 纯文本要再加大的下半区 Continue 按钮，防误藏真人
/// 点的下载确认框）与假真人验证卡（验证词 + 验证 CTA + 关闭按钮）。
/// 几何阈值恢复到 run #22 真机确认过的 v10 原值（88px 下限）。诊断浮层只在
/// 检测 Tab 开关打开时显示（左下角小字：扫描/拦截计数，测试用）。
/// 删什么（run #21 XSPModalGuard v5 合成版，Gemini v2/v4 + ChatGPT v3/v5 四轮互撕收敛）：
/// ① 弹窗层（新增，治 onlybokep 那三个假弹窗）：文本签名 + CTA 组合评分
///    （Finish Download / Download pending / REMINDER (N) / Resume playing?，
///    单个 Download 或 Continue > 不够分）；受保护祖先集合（每轮从 video 与
///    播放器控件沿 composed 树上行，限 10 跳，绝不藏 video 祖先）；Shadow DOM
///    扫描（document-start 钩 attachShadow 抓 closed 根）；节点原地保留 +
///    私有标记 + !important 隐藏，样式被广告 SDK 改回去就由观察器恢复；
///    原生 <dialog> 先 close() 再藏；恢复播放只看归因（页面 JS 调了 pause 且
///    近 3 秒内藏过已识别弹窗，且不是用户点停、不是 Media Session 系统暂停、
///    不是视频播完）；跨域 iframe 子帧上报 + 父帧独立几何校验才藏 iframe。
/// ② 假 Download 按钮（老规则 1）；③ 全屏点击劫持层（老规则 2）；
/// ④ 文本命中的广告卡片（老规则 3）；⑤ 类名/id 广告标记（老规则 4）；
/// ⑥ src 落在广告域的 iframe（老规则 5）。
/// run #22 XSPFloatingCardGuard v10（Gemini v6/v8/v10 + ChatGPT v7/v9 五轮收敛）：
/// 第二个独立 IIFE，追加在 v5 后面，v5 一字不动。治 run #21 真机剩下的两张卡
/// （飞鸟VPN 推广卡 + View More 打码推送卡）：VPN 三路（CTA+强词+关闭 / CTA+辅词≥3+关闭 /
/// 强词+辅词≥2+宽下半区 CTA）与 View More（头像 + 模糊行≥2，或头像 + 受控稀疏视觉素材）
/// 双独立分类器；统一 hardVeto 在分类前与 hide 时双重执行（只保真播放器控件，
/// 不豁免 #player 容器内注入的广告）；样式表优先隐藏 + getComputedStyle 校验，
/// 被行内 !important 压过才定向升级行内兜底；点击壳分两档解除（紧凑壳 + 全屏/大尺寸
/// 遮罩壳，带暗色底的同步裁切）；浅层 attributes 监听抓预挂载滑入卡；几何 180×88
/// 绝对像素下限 + visualViewport 对齐；iframe 协议带 nonce 过滤与多层中继。
/// 另：所有 video 元素都打上 playsinline，让嵌页视频在页内播、
/// 走我们的外层控制条，而不是一播就跳系统全屏播放器。
enum AdStripScript {
    /// run #23 (v13): diagBadgeEnabled 在每个 frame 的 document-start 就置位，
    /// 这样嵌页 iframe 里的清理器也能装诊断浮层（didFinish 只够得到主框架）。
    static func source(diagBadgeEnabled: Bool) -> String {
        // NONCE 按实例替换：每次调 source() 生成一个新 UUID，同一块 WKWebView 的
        // 各帧共用它（子帧上报、父帧校验）；字面量 '__XSP_SESSION_NONCE__' 全网
        // 都一样，页内任意帧都能伪造上报消息让父帧去裁别的 iframe。
        // v13 的注释早写了“Swift 替换”，实现一直漏了，这次补上。
        let nonce = UUID().uuidString
        return ((diagBadgeEnabled ? "window.__xspDiagBadge = true;\n" : "") + """
    // XSP shared prologue (run #23, v13) — runs BEFORE the v5 and v10 IIFEs in the same
    // injected script, so both IIFEs call these instead of keeping their own copies.
    // Lives inside a Swift triple-quote string: NO backticks, NO dollar-brace sequences.
    // Backslashes are single here; the splice step doubles them for Swift.
    // ES5 style (var / function) so it matches the v5 file and the v12 v10 file.

    // ---------- Shared Cloudflare challenge-document gate (ChatGPT v13) ----------
    // ONE function, recomputed on every scan, shared by v5 stripOnce and v10 scanOnce.
    // Do NOT cache a hasVideo boolean: the player element may be inserted after the
    // flag was captured, and a challenge overlay over an existing player is still a
    // challenge. Strong markers win even if a <video> is present underneath.
    // "您是真人吗" is deliberately NOT a title trigger: the fake verification card
    // itself carries that text, and it must never shut down scanning.
    window.__xspShared = window.__xspShared || {};

    function xspIsCloudflareChallengeDocument(doc) {
      try {
        if (!doc || !doc.documentElement) return false;
        var href = String((doc.location && doc.location.href) || '').toLowerCase();
        var title = String(doc.title || '').toLowerCase();
        var urlSignal = href.indexOf('challenges.cloudflare.com') >= 0 ||
          href.indexOf('/cdn-cgi/challenge-platform/') >= 0;
        var titleSignal = /just a moment|checking your browser|verify you are human|正在验证|请稍候/.test(title);
        var markerSignal = false;
        try {
          markerSignal = !!doc.querySelector(
            '#challenge-form, #challenge-running, #challenge-stage, ' +
            '#cf-wrapper, #cf-spinner, #cf-browser-verification, ' +
            '[id*="cf-chl-"], [class*="cf-challenge"], ' +
            '[class*="challenge-running"], [class*="turnstile"]'
          );
        } catch (_) {}
        var globalSignal = false;
        try {
          globalSignal = !!(doc.defaultView && doc.defaultView._cf_chl_opt);
        } catch (_) {}
        var scriptSignal = false;
        try {
          scriptSignal = !!doc.querySelector('script[src*="/cdn-cgi/challenge-platform/"]');
        } catch (_) {}
        // Script alone is supporting evidence only; a generic "challenge" word proves nothing.
        return !!(urlSignal || markerSignal || globalSignal || (titleSignal && scriptSignal));
      } catch (_) {
        return false;
      }
    }

    function xspChallengeGate() {
      try {
        return xspIsCloudflareChallengeDocument(document);
      } catch (_) {
        return false;
      }
    }

    // ---------- Shared per-element challenge protection (ChatGPT v13) ----------
    // Protect a candidate iff it IS, is INSIDE, or CONTAINS a real challenge
    // component/iframe — but only the candidate itself, never "any ancestor in the
    // document that happens to contain a challenge" (that would immunize the page).
    // No depth cap: a real challenge container can nest arbitrarily. Composed-tree
    // walk crosses registered ShadowRoot hosts; closed roots we never registered
    // cannot be inspected and are not pretended to be.
    var XSP_CF_MARKER =
      '[id*="cf-"], [class*="cf-challenge"], ' +
      '[class*="challenge-running"], [class*="turnstile"], ' +
      '#challenge-form, #challenge-stage, #challenge-running';

    function xspIsCFFrame(el) {
      if (!el || el.nodeType !== 1) return false;
      if ((el.tagName || '').toLowerCase() !== 'iframe') return false;
      var src = (el.getAttribute('src') || '').toLowerCase();
      var title = (el.getAttribute('title') || '').toLowerCase();
      return src.indexOf('challenges.cloudflare.com') >= 0 ||
        src.indexOf('turnstile') >= 0 ||
        /cloudflare|turnstile|security challenge/.test(title);
    }

    function xspIsCFComponent(el) {
      if (!el || el.nodeType !== 1) return false;
      if (xspIsCFFrame(el)) return true;
      try {
        return el.matches(XSP_CF_MARKER);
      } catch (_) {
        return false;
      }
    }

    function xspComposedParent(el) {
      if (!el) return null;
      if (el.parentElement) return el.parentElement;
      var root = el.getRootNode && el.getRootNode();
      return root && root.host ? root.host : null;
    }

    function xspCandidateContainsCF(candidate, roots) {
      if (xspIsCFComponent(candidate)) return true;
      try {
        var found = candidate.querySelectorAll(XSP_CF_MARKER + ', iframe');
        for (var i = 0; i < found.length; i++) {
          if (xspIsCFComponent(found[i])) return true;
        }
      } catch (_) {}
      // Shadow descendants: only registered roots whose host is composed-descended
      // from this candidate.
      var list = roots || [];
      for (var r = 0; r < list.length; r++) {
        var root = list[r];
        if (!root || !root.host) continue;
        var host = root.host;
        var belongs = false;
        for (var depth = 0; host && depth < 32; depth++) {
          if (host === candidate) { belongs = true; break; }
          host = xspComposedParent(host);
        }
        if (!belongs) continue;
        try {
          var els = root.querySelectorAll(XSP_CF_MARKER + ', iframe');
          for (var j = 0; j < els.length; j++) {
            if (xspIsCFComponent(els[j])) return true;
          }
        } catch (_) {}
      }
      return false;
    }

    function xspIsInsideCFComponent(candidate) {
      var p = candidate;
      for (var depth = 0; p && depth < 32; depth++) {
        if (xspIsCFComponent(p)) return true;
        p = xspComposedParent(p);
      }
      return false;
    }

    function xspIsChallengeProtected(candidate, roots) {
      if (!candidate || candidate.nodeType !== 1) return true;
      if (xspIsInsideCFComponent(candidate)) return true;
      if (xspCandidateContainsCF(candidate, roots)) return true;
      return false;
    }

    // ---------- Shared v10-ownership guard ----------
    // v10 clips confirmed cards (keeps offsetHeight > 0 so the ad SDK does not
    // resurrect them). v5 must never overwrite that with display:none, and must
    // not hide a wrapper around a v10-managed card either.
    function xspIsV10Managed(el) {
      if (!el || el.nodeType !== 1) return false;
      try {
        if (el.getAttribute && el.getAttribute('data-xsp-fg-v10') === '1') return true;
        var p = el.parentElement;
        for (var i = 0; p && i < 8; i++, p = p.parentElement) {
          if (p.getAttribute && p.getAttribute('data-xsp-fg-v10') === '1') return true;
        }
      } catch (_) {}
      return false;
    }

    // ---------- Shared on-device telemetry: counters + visible phone badge ----------
    // window.__xspDiag counters (readable via evaluateJavaScript when a Mac is around).
    // The badge is the phone-only reader: it is installed ONLY when Swift sets
    // window.__xspDiagBadge = true (toggle in the 检测 tab, default off), lives in
    // its own closed ShadowRoot, and is excluded from every candidate scan.
    function xspDiagBump(key, detail) {
      try {
        var d = window.__xspDiag;
        if (!d) {
          d = {
            v5Runs: 0, v5SkipChallengeDoc: 0, v5VetoChallengeEl: 0, v5Hid: 0,
            v10Runs: 0, v10SkipChallengeDoc: 0, v10Candidates: 0,
            v10HidVpn: 0, v10HidAnon: 0, v10HidVerify: 0, v10HidDlProg: 0, lastHits: []
          };
          window.__xspDiag = d;
        }
        if (key === 'v10Candidates') {
          d[key] = Number(detail || 0);
        } else if (typeof d[key] === 'number') {
          d[key] += 1;
        }
        if (detail && typeof detail === 'string') {
          d.lastHits.push(detail);
          if (d.lastHits.length > 10) d.lastHits.shift();
        }
        if (detail && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xspDiag) {
          try { window.webkit.messageHandlers.xspDiag.postMessage({ key: key, detail: detail }); } catch (_) {}
        }
        var badgeMap = {
          v5Runs: 'scans', v10Runs: 'scans',
          v5SkipChallengeDoc: 'challengeSkips', v10SkipChallengeDoc: 'challengeSkips',
          v10Candidates: 'candidates',
          v10HidVpn: 'hiddenVPN', v10HidAnon: 'hiddenViewMore',
          v10HidVerify: 'hiddenVerification', v10HidDlProg: 'hiddenDownload',
          v5VetoChallengeEl: 'protectedVetoes'
        };
        if (badgeMap[key]) xspDiagEvent(badgeMap[key], detail);
        else if (key === 'v5Hid') xspDiagEvent('v5 hid' + (detail ? ': ' + detail : ''));
      } catch (_) {}
    }

    function xspDiagEvent(name, detail) {
      try {
        var api = window.__xspPhoneDiag;
        if (api && api.event) api.event(name, detail);
      } catch (_) {}
    }

    function xspInstallPhoneDiag() {
      try {
        if (!window.__xspDiagBadge) return null;
        if (window.__xspPhoneDiag) return window.__xspPhoneDiag;
        var state = {
          scans: 0, challengeSkips: 0, candidates: 0,
          hiddenVPN: 0, hiddenViewMore: 0, hiddenVerification: 0, hiddenDownload: 0,
          protectedVetoes: 0, last: 'started'
        };
        var host = document.createElement('div');
        host.setAttribute('data-xsp-debug-ui', '1');
        var shadow = host.attachShadow({ mode: 'closed' });
        var panel = document.createElement('div');
        panel.style.cssText =
          'position:fixed;left:5px;bottom:5px;z-index:2147483647;' +
          'background:rgba(0,0,0,.88);color:#fff;padding:7px 9px;' +
          'font:11px/1.4 monospace;border:1px solid #777;' +
          'border-radius:6px;max-width:240px;pointer-events:none;';
        shadow.appendChild(panel);
        (document.documentElement || document).appendChild(host);
        var api = {
          state: state,
          event: function (name, detail) {
            if (name === 'candidates') {
              state.candidates = Number(detail || 0);
            } else if (Object.prototype.hasOwnProperty.call(state, name)) {
              state[name] += Number(detail || 1);
            }
            state.last = String(name).slice(0, 80);
            render();
          }
        };
        function render() {
          panel.textContent =
            'XSP diag\\n' +
            'scan ' + state.scans +
            ' | gate ' + state.challengeSkips +
            ' | cand ' + state.candidates + '\\n' +
            'VPN ' + state.hiddenVPN +
            ' | More ' + state.hiddenViewMore + '\\n' +
            'Verify ' + state.hiddenVerification +
            ' | Download ' + state.hiddenDownload + '\\n' +
            'veto ' + state.protectedVetoes + '\\n' +
            'last: ' + state.last;
        }
        window.__xspPhoneDiag = api;
        render();
        return api;
      } catch (_) {
        return null;
      }
    }

    // XSPModalGuard v5 synthesis (run #21) — replaces the old AdStripScript.
    // run #23 (v13): cfRunning() global gate replaced by the shared xspChallengeGate()
    // in the prologue; hideTarget() skips v10-managed + challenge-protected nodes.
    // Lives inside a Swift triple-quote string: NO backticks, NO dollar-brace sequences in this file.
    // Backslashes are single here; the splice step doubles them for Swift.
    (function(){
      // ---------- config: signatures live here, copy changes only touch this block ----------
      var AD_DOMAINS = ['doubleclick.net','googlesyndication.com','googleadservices.com',
        'taboola.com','outbrain.com','mgid.com','adsrvr.org','adnxs.com','criteo.com',
        'popads.net','popcash.net','adcash.com','propellerads.com','adsterra.com',
        'hilltopads.com','clickadu.com','amazon-adsystem.com','moatads.com'];
      var AD_TEXTS = ['Your Next Adventure', 'Starts Here!', 'Discover amazing attractions'];
      var FAKE_DL_RE = /^(fast\\s*)?(free\\s*)?download(\\s*(now|hd|video|app|file|here|free))*\\s*$/i;
      var FAKE_DL_TEXTS = ['高速下载', '立即下载', '免费下载', '下载视频', '极速下载'];
      // Modal signatures: strong text is the primary signal, geometry only secondary.
      // Points: a lone "Download" (+1) or a lone "Continue >" (+1) never fires alone.
      var MODAL_RES = [
        { re: /finish\\s+(your\\s+)?download/i, pts: 3 },
        { re: /download\\s+pending/i, pts: 3 },
        { re: /resume\\s+playing/i, pts: 3 },
        { re: /reminder\\s*\\(\\d+\\)/i, pts: 2 },
        { re: /download/i, pts: 1 }
      ];
      var CTA_CONT_RE = /continue\\s*[>›→]/i;
      var CTA_NO_RE = /no,?\\s*thanks/i;
      var MODAL_SCORE_MIN = 3;
      var MAX_TEXT_NODES_PER_SCAN = 5000;
      var MAX_CARD_TEXT = 2000;
      var MAX_PROTECT_HOPS = 10;

      // ---------- per-frame state ----------
      var shadowRoots = [];
      var hiddenNodes = [];
      var rafPending = false;
      var lastJsPauseAt = 0;            // page JS called video.pause() (evidence, not a verdict)
      var lastMediaSessionPauseAt = 0;  // system pause routed through a page Media Session handler
      var lastTrustedAt = 0;            // trusted pointer/key interaction on this page
      var lastModalHiddenAt = 0;
      var lastPauseAt = 0;

      // ---------- 0. attachShadow hook FIRST (document-start runs before any page script) ----------
      try {
        var nativeAttachShadow = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function(init){
          var root = nativeAttachShadow.call(this, init);
          try { if (root && shadowRoots.indexOf(root) < 0) shadowRoots.push(root); } catch(e){}
          return root;
        };
      } catch(e){}

      // cfRunning() REMOVED in run #23 (v13): the global kill-switch is replaced by
      // the shared xspChallengeGate() in the prologue (only the challenge's own
      // document stops scanning; a leftover challenge iframe no longer kills v5).

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

      // ---------- 1. protected ancestors: walk up from every <video> + player controls ----------
      // Composed traversal (cross shadow boundaries via getRootNode().host), capped hops.
      // Only video/control ancestors are protected — never the whole player host, or
      // sibling modals inside the host would become untouchable.
      function buildProtectedSet(){
        var set = [];
        function addAncestors(el){
          var hops = 0, cur = el;
          while (cur && hops < MAX_PROTECT_HOPS) {
            if (set.indexOf(cur) < 0) set.push(cur);
            var parent = cur.parentElement;
            if (!parent) {
              try {
                var root = cur.getRootNode && cur.getRootNode();
                if (root && root.host) { cur = root.host; hops++; continue; }
              } catch(e){}
              break;
            }
            cur = parent; hops++;
          }
        }
        try {
          var vs = document.querySelectorAll('video');
          for (var i = 0; i < vs.length; i++) addAncestors(vs[i]);
          var ctrls = document.querySelectorAll('[class*="plyr"], [class*="vjs-"], [class*="jwplayer"]');
          for (var j = 0; j < ctrls.length; j++) addAncestors(ctrls[j]);
          for (var k = 0; k < shadowRoots.length; k++) {
            try {
              var sv = shadowRoots[k].querySelectorAll ? shadowRoots[k].querySelectorAll('video') : [];
              for (var m = 0; m < sv.length; m++) addAncestors(sv[m]);
            } catch(e){}
          }
        } catch(e){}
        return set;
      }

      function isProtected(el, set){
        return el && set.indexOf(el) >= 0;
      }

      // ---------- 2. modal detection: one bounded text-node pass, no innerText ----------
      function scanTextNodes(root, out){
        try {
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function(n){
              var p = n.parentElement;
              if (!p) return NodeFilter.FILTER_REJECT;
              var t = p.tagName;
              if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT') return NodeFilter.FILTER_REJECT;
              // run #23: never scan the phone-diag badge's own text ("Download"/"Verify"
              // counters would otherwise feed the modal scorer).
              var pp = p;
              for (var up = 0; pp && up < 8; up++, pp = pp.parentElement) {
                if (pp.getAttribute && pp.getAttribute('data-xsp-debug-ui') === '1') return NodeFilter.FILTER_REJECT;
              }
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          var node, count = 0;
          while ((node = walker.nextNode())) {
            if (++count > MAX_TEXT_NODES_PER_SCAN) break;
            var txt = node.data || '';
            if (txt.length < 3 || txt.length > 400) continue;
            for (var i = 0; i < MODAL_RES.length; i++) {
              if (MODAL_RES[i].re.test(txt)) { out.push(node); break; }
            }
          }
        } catch(e){}
      }

      // Walk up from a matching text node to the modal card: first <dialog>,
      // role=dialog / aria-modal ancestor, or fixed/absolute ancestor (the
      // backdrop counts — hiding it hides the card too). Stop at protected
      // ancestors: use the inner node instead, never cross into video territory.
      function findModalCard(textNode, prot){
        var cur = textNode.parentElement, prev = null, hops = 0;
        while (cur && hops < 6) {
          if (isProtected(cur, prot)) return prev;
          if (cur.tagName === 'DIALOG') return cur;
          try {
            if (cur.getAttribute('role') === 'dialog' || cur.getAttribute('aria-modal') === 'true') return cur;
          } catch(e){}
          var pos = '';
          try { pos = getComputedStyle(cur).position; } catch(e){}
          if (pos === 'fixed' || pos === 'absolute') return cur;
          prev = cur;
          cur = cur.parentElement;
          hops++;
        }
        return null;
      }

      function scoreCard(card){
        var txt = '';
        try { txt = (card.textContent || '').slice(0, MAX_CARD_TEXT); } catch(e){}
        if (!txt) return 0;
        var score = 0, hasDownload = false;
        for (var i = 0; i < MODAL_RES.length; i++) {
          if (MODAL_RES[i].re.test(txt)) {
            score += MODAL_RES[i].pts;
            if (MODAL_RES[i].re === MODAL_RES[4].re) hasDownload = true;
          }
        }
        if (hasDownload && CTA_CONT_RE.test(txt) && CTA_NO_RE.test(txt)) score += 2;
        // Cross-origin <a href> / target=_blank is supporting evidence ONLY
        // inside an already-identified modal (never a standalone signal:
        // subtitle downloads, share, trailers and account pages are legit).
        if (score >= 2) {
          try {
            var links = card.querySelectorAll ? card.querySelectorAll('a[href]') : [];
            for (var j = 0; j < links.length; j++) {
              var a = links[j];
              var href = a.getAttribute('href') || '';
              var isBlank = (a.getAttribute('target') || '') === '_blank';
              var cross = false;
              if (href.indexOf('http') === 0) {
                try { cross = new URL(href).origin !== location.origin; } catch(e){ cross = true; }
              }
              if (isBlank || cross) { score += 1; break; }
            }
          } catch(e){}
        }
        return score;
      }

      // ---------- 3. hiding: keep the node, mark it, !important hide, restore on reset ----------
      function hideTarget(el){
        if (!el) return false;
        // run #23 (v13): never overwrite v10's non-collapsing clip-hide with
        // display:none (SDK resurrection), and never hide a real challenge node.
        if (xspIsV10Managed(el)) return false;
        if (xspIsChallengeProtected(el, shadowRoots)) { xspDiagBump('v5VetoChallengeEl'); return false; }
        try {
          // Native <dialog>: close() first — display:none alone leaves the page
          // stuck in top-layer modal inert state + body overflow locked.
          // Only called on scored modal cards, never on every dialog.
          var dialogs = [];
          if (el.tagName === 'DIALOG') dialogs.push(el);
          else if (el.querySelectorAll) {
            var ds = el.querySelectorAll('dialog');
            for (var i = 0; i < ds.length; i++) dialogs.push(ds[i]);
          }
          for (var d = 0; d < dialogs.length; d++) {
            try { HTMLDialogElement.prototype.close.call(dialogs[d]); } catch(e){}
          }
          el.setAttribute('data-xsp-hidden', '1');
          el.style.setProperty('display', 'none', 'important');
          el.style.setProperty('pointer-events', 'none', 'important');
          el.style.setProperty('visibility', 'hidden', 'important');
          if (hiddenNodes.indexOf(el) < 0) hiddenNodes.push(el);
          xspDiagBump('v5Hid', 'v5:' + (el.tagName || 'EL'));
          return true;
        } catch(e){ return false; }
      }

      function reapplyHide(el){
        try {
          if (!el.getAttribute('data-xsp-hidden')) return;
          if (el.style.getPropertyValue('display') !== 'none') {
            el.style.setProperty('display', 'none', 'important');
          }
          if (el.style.getPropertyValue('visibility') !== 'hidden') {
            el.style.setProperty('visibility', 'hidden', 'important');
          }
          if (el.style.getPropertyValue('pointer-events') !== 'none') {
            el.style.setProperty('pointer-events', 'none', 'important');
          }
        } catch(e){}
      }

      // ---------- 4. resume attribution: pause() is EVIDENCE, four-way classification ----------
      // Native iOS pauses (Control Center / lock screen / AirPods) never call the JS
      // prototype — EXCEPT through a page-registered Media Session handler, which
      // we instrument separately. Resume ONLY when: a page-JS pause happened AND
      // an identified modal was hidden in the same window AND no user-pause signal.
      try {
        var nativePause = HTMLMediaElement.prototype.pause;
        HTMLMediaElement.prototype.pause = function(){
          lastJsPauseAt = Date.now();
          return nativePause.apply(this, arguments);
        };
      } catch(e){}

      try {
        if (navigator.mediaSession && navigator.mediaSession.setActionHandler) {
          var nativeSAH = navigator.mediaSession.setActionHandler.bind(navigator.mediaSession);
          navigator.mediaSession.setActionHandler = function(action, handler){
            if (action === 'pause' && typeof handler === 'function') {
              var wrapped = function(){
                lastMediaSessionPauseAt = Date.now();
                try { return handler.apply(this, arguments); } catch(e){}
              };
              return nativeSAH(action, wrapped);
            }
            return nativeSAH(action, handler);
          };
        }
      } catch(e){}

      function findVideo(){
        try {
          var v = document.querySelector('video');
          if (v) return v;
          for (var i = 0; i < shadowRoots.length; i++) {
            try {
              var sv = shadowRoots[i].querySelector ? shadowRoots[i].querySelector('video') : null;
              if (sv) return sv;
            } catch(e){}
          }
        } catch(e){}
        return null;
      }

      function maybeResume(){
        try {
          var v = findVideo();
          if (!v || !v.paused || v.ended) return;
          if (document.hidden) return;
          var now = Date.now();
          if (now - lastJsPauseAt > 3000) return;       // no recent page-JS pause
          if (now - lastModalHiddenAt > 3000) return;   // no recently hidden modal
          if (now - lastMediaSessionPauseAt < 3000) return; // system pause via Media Session
          if (lastTrustedAt <= lastJsPauseAt && lastJsPauseAt - lastTrustedAt < 700) return; // user tapped pause
          v.play();
        } catch(e){}
      }

      // ---------- 5. cross-origin iframe protocol (versioned, source-checked, no nonce) ----------
      // Child frame: after hiding a high-confidence modal, report to the parent ONLY
      // when this frame has no <video> (a player frame never reports). Parent: hide
      // the iframe only when event.source matches one of its iframes AND it
      // independently judges that iframe floating/covering.
      function reportToParent(){
        try {
          if (window.parent && window.parent !== window) {
            window.parent.postMessage({ type: '__xspModalHidden', v: 1 }, '*');
          }
        } catch(e){}
      }

      window.addEventListener('message', function(ev){
        try {
          var d = ev.data || {};
          if (d.type !== '__xspModalHidden' || d.v !== 1) return;
          var frames = document.querySelectorAll('iframe');
          for (var i = 0; i < frames.length; i++) {
            if (frames[i].contentWindow === ev.source) {
              var st = getComputedStyle(frames[i]);
              if (st.position !== 'fixed' && st.position !== 'absolute') return;
              var r = frames[i].getBoundingClientRect();
              var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
              if (vw > 0 && vh > 0 && r.width >= vw * 0.5 && r.height >= vh * 0.5) {
                if (hideTarget(frames[i])) lastModalHiddenAt = Date.now();
              }
              return;
            }
          }
        } catch(e){}
      });

      // ---------- 6. the scan: modal layer first, then the old rules ----------
      function stripOnce(){
        xspInstallPhoneDiag();
        if (xspChallengeGate()) { xspDiagBump('v5SkipChallengeDoc'); return; }
        xspDiagBump('v5Runs');
        try {
          var prot = buildProtectedSet();

          // --- modal layer ---
          var hits = [];
          scanTextNodes(document, hits);
          for (var s = 0; s < shadowRoots.length; s++) {
            try { scanTextNodes(shadowRoots[s], hits); } catch(e){}
          }
          var hiddenAny = false;
          var seenCards = [];
          for (var h = 0; h < hits.length; h++) {
            var card = findModalCard(hits[h], prot);
            if (!card || seenCards.indexOf(card) >= 0) continue;
            seenCards.push(card);
            if (scoreCard(card) >= MODAL_SCORE_MIN) {
              if (hideTarget(card)) {
                hiddenAny = true;
                lastModalHiddenAt = Date.now();
              }
            }
          }
          if (hiddenAny) {
            // This frame has no video of its own: let the parent judge the iframe.
            if (!document.querySelector('video')) reportToParent();
            maybeResume();
          }

          // --- rule 1: fake Download buttons (kept verbatim) ---
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
              hideTarget(box);
            }
          }
          // --- rule 2: full-screen clickjack overlays (kept verbatim) ---
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
                  hideTarget(ov);
                }
              }
            }
          }
          // --- rule 3: ad-text cards (kept verbatim) ---
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
                  if (node.querySelector && node.querySelector('[aria-label*="lose" i], [class*="close" i], [id*="close" i]')) { hideTarget(node); break; }
                  node = node.parentElement;
                }
                if (up2 >= 4) hideTarget(el);
                break;
              }
            }
          }
          // --- rule 4: ad class/id markers (kept verbatim) ---
          var ads = document.querySelectorAll('[id*="ad-"], [id*="-ad-"], [class*="ad-banner"], [class*="ad-popup"], [class*="advertisement"], [class*="ads-container"], [class*="popunder"], [class*="overlay-ad"]');
          for (var j = 0; j < ads.length; j++) {
            if (hasVideoInside(ads[j])) continue;
            var a = ads[j];
            if (a.tagName === 'VIDEO' || a.querySelector('video')) continue;
            hideTarget(a);
          }
          // --- rule 5: ad-domain iframes only (kept verbatim) ---
          var frames = document.querySelectorAll('iframe[src]');
          for (var f = 0; f < frames.length; f++) {
            if (isAdSrc(frames[f].src)) hideTarget(frames[f]);
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

      function scheduleScan(){
        if (rafPending) return;
        rafPending = true;
        try {
          requestAnimationFrame(function(){
            rafPending = false;
            stripOnce();
            forceInline();
          });
        } catch(e){
          rafPending = false;
          stripOnce();
          forceInline();
        }
      }

      // ---------- 7. wiring ----------
      // Trusted interaction: a pause within 700ms after a tap/keypress is a user pause.
      document.addEventListener('pointerdown', function(){ lastTrustedAt = Date.now(); }, true);
      document.addEventListener('keydown', function(){ lastTrustedAt = Date.now(); }, true);
      // Capture-phase pause: WebKit pause does not bubble; this catches every
      // <video> pause, including pre-mounted modals that appear on class/style flips
      // (childList-only observers never fire for those).
      document.addEventListener('pause', function(){
        lastPauseAt = Date.now();
        scheduleScan();
        maybeResume();
      }, true);

      // Main observer: childList + attributes (style/class/hidden/open/marker) +
      // characterData. Re-apply hiding when the ad SDK resets a hidden node's style.
      // characterData only schedules a scan when the changed text matches a signature.
      try {
        var obs = new MutationObserver(function(muts){
          var needScan = false;
          for (var i = 0; i < muts.length; i++) {
            var m = muts[i];
            if (m.type === 'attributes' && m.target && m.target.getAttribute) {
              if (m.target.getAttribute('data-xsp-hidden')) {
                reapplyHide(m.target);
                continue;
              }
              needScan = true;
            } else if (m.type === 'childList') {
              needScan = true;
            } else if (m.type === 'characterData' && m.target && m.target.data) {
              for (var k = 0; k < MODAL_RES.length; k++) {
                if (MODAL_RES[k].re.test(m.target.data)) { needScan = true; break; }
              }
            }
          }
          if (needScan) scheduleScan();
        });
        obs.observe(document.documentElement || document, {
          childList: true, attributes: true,
          attributeFilter: ['style', 'class', 'hidden', 'open', 'data-xsp-hidden'],
          characterData: true, subtree: true
        });
      } catch(e){}

      stripOnce();
      forceInline();
      setInterval(function(){ stripOnce(); forceInline(); }, 1000);
    })();
    // XSPFloatingCardGuard v13 (run #23) — v12 + ChatGPT v13 corrections, separate IIFE.
    // Shared CF gate + per-element CF protection (prologue), tightened D2, restored
    // v10 device-confirmed geometry, v10-owns-its-cards, phone-diag badge wiring.
    // XSPFloatingCardGuard v13 (run #23) — v12 + ChatGPT v13 corrections:
    // shared CF gate + per-element CF protection (prologue), tightened D2,
    // restored v10 device-confirmed geometry, v10-owns-its-cards, phone-diag badge.
    (function () {
      if (window.__xspFloatingCardGuardV10) return;
      window.__xspFloatingCardGuardV10 = true;

      // Swift replaces this with UUID().uuidString per WKWebView instance; works identically across frames even if unchanged
      var NONCE = '__XSP_SESSION_NONCE__';
      var CARD_ATTR = 'data-xsp-fg-v10';
      var WRAP_ATTR = 'data-xsp-fg-wrap-v10';
      var BACKDROP_ATTR = 'data-xsp-fg-bd-v10';
      var STYLE_ID = '__xsp_fg_v10_css';

      // ---------------- Real Challenge & Hard-Veto Rules ----------------
      // run #23 (v13): challenge-document + per-element CF checks moved to the
      // shared prologue (xspChallengeGate / xspIsChallengeProtected) — one live
      // decision shared by v5 and v10, never two copies that can disagree.
      var REAL_CHALLENGE_SEL =
        'iframe[src*="challenges.cloudflare.com"], iframe[src*="hcaptcha.com"], ' +
        'iframe[src*="recaptcha.net"], iframe[src*="google.com/recaptcha"], ' +
        '.cf-turnstile, #turnstile-wrapper, #challenge-form, #challenge-running, #challenge-stage, ' +
        '[data-sitekey], input[name="cf-turnstile-response"], .g-recaptcha, .h-captcha';

      var SAFE_IFRAME_RE =
        /(challenges\\.cloudflare\\.com|hcaptcha\\.com|recaptcha\\.net|google\\.com\\/recaptcha|accounts\\.|login\\.|oauth|pay\\.|stripe\\.com|paypal\\.com)/i;

      var CONTROL_BAR_SELECTOR =
        '.vjs-control-bar, .vjs-menu, .vjs-text-track-display, .vjs-title-bar, .vjs-error-display, ' +
        '.plyr__controls, .plyr__menu, .plyr__captions, ' +
        '.jw-controls, .jw-settings-menu, .jw-captions, .jw-title, ' +
        '.dplayer-controller, .dplayer-setting-box, .dplayer-subtitle, ' +
        '.art-bottom, .art-setting, .art-subtitle, ' +
        '[role="slider"], input[type="range"], .cf-turnstile';

      var PLAYER_CHROME_RE =
        /(^|[\\s_-])(vjs-(control|menu|text-track|title|error|loading|big-play|poster|time|progress|volume|fullscreen|subs|caption)|plyr__(controls?|menu|captions?|poster|progress|time|volume|tooltip)|jw-(controls?|settings|captions?|title|display|icon|slider|tooltip)|dplayer-(controller|setting|subtitle|bar|icons|notice|menu)|art-(bottom|controls?|setting|subtitle|notice|loading|layer-title)|control-?bar|seek-?bar|progress-?bar|top-?bar|header-?bar|nav-?bar|cf-turnstile)/i;

      var PLAYER_LIVE_UI_RE =
        /(vjs-(current-time|duration|remaining|time|progress|control|text-track)|plyr__(time|progress|captions?|tooltip)|jw-(text-elapsed|text-duration|slider|captions?|tooltip)|dplayer-(ptime|dtime|bar|subtitle)|art-(time|progress|subtitle)|time-?display|current-?time|duration|progress-?bar|seek-?bar|subtitle|caption|text-?track)/i;

      var MENU_EXPLICIT_RE =
        /\\b(subtitles?|captions?|playback\\s+speed|audio\\s+track|quality|picture[\\s-]in[\\s-]picture|chromecast|airplay)\\b|(清晰度|画质|倍速|字幕|音轨|切换线路|画中画|投屏)/i;
      var MENU_OPTION_TOKEN_RE = /\\b(2160p|1080p|720p|480p|360p|4k|0\\.5x|0\\.75x|1\\.0?x|1\\.25x|1\\.5x|2\\.?0?x|auto)\\b/gi;

      var NEXT_EPISODE_VETO_RE =
        /(下一集|下集|即将播放|自动播放下|选集|第\\s*\\d+\\s*[集话期部]|合集列表|\\bup\\s+next\\b|\\bnext\\s+episode\\b|\\bnext\\s+video\\b|\\bplay\\s+next\\b|\\bauto[\\s-]?play\\b|\\bep\\.?\\s*\\d+\\b|\\bs\\d+\\s*e\\d+\\b)/i;

      var AUTH_PAY_CAPTCHA_SELECTOR =
        'input[type="password"], input[type="email"], input[autocomplete*="cc-"], [data-sitekey], .cf-turnstile, .g-recaptcha, .h-captcha';

      // ---------------- Classifier A: VPN / Accelerator Promo Card ----------------
      var VPN_STRONG_RE = /(vpn|翻墙|梯子|科学上网|加速神器|看片神器|翻墙看片|看片加速|回国加速|游戏加速器|加速器)/i;

      var VPN_AUX_NET_CLUSTERS = [
        /(\\d+\\s*\\+\\s*节点|全球.{0,6}节点|高速节点|专线节点|多国节点)/i,
        /(无限流量|不限流量|不限速|零日志|不限带宽)/i,
        /(支持订阅|一键订阅|订阅链接|多端同步)/i
      ];
      var VPN_AUX_OTHER_CLUSTERS = [
        /(免费试用|免费体验|限时免费|永久免费|新人免费)/i,
        /(独立\\s*app|原生\\s*app|客户端下载|官方\\s*app)/i,
        /(支持.{0,12}(安卓|苹果|ios|android|pc|mac|windows))/i
      ];

      var VPN_DOWNLOAD_CTA_RE =
        /^(立即下载体验|立即下载|下载体验|立即安装|免费下载|高速下载|极速下载|免费试用|立即体验|点击下载|马上下载|下载\\s*app|download\\s+now|install\\s+now|free\\s+download|try\\s+free)(\\s*[!！>»→])?$/i;

      // ---------------- Classifier B: Anonymous Push / Blurred Card (View More) ----------------
      var ANON_PUSH_CTA_RE =
        /^(view\\s+more|learn\\s+more|see\\s+more|read\\s+more|show\\s+more|open\\s+now|visit\\s+site|view\\s+details|see\\s+details|more\\s+info|go\\s+now|查看更多|查看详情|了解详情|立即查看)(\\s*[!！>»→])?$/i;

      // ---------------- Classifier C: Fake Human Verification Card ----------------
      var VERIFY_PHRASE_RE =
        /(您是真人吗|需要验证身份|请验证身份|身份验证|真人验证|人机验证|\\bare\\s+you\\s+(a\\s+)?human\\b|\\bverify\\s+you\\s+are\\s+human\\b|\\bhuman\\s+verification\\b|\\brobot\\s+check\\b|\\bprove\\s+you\\s+are\\s+human\\b)/i;

      var VERIFY_CTA_RE =
        /^(点击了解更多|了解更多|立即验证|开始验证|点击验证|验证身份|learn\\s+more|verify\\s+now|continue\\s+verification|click\\s+to\\s+verify|verify\\s+human)(\\s*[!！>»→])?$/i;

      // ---------------- Classifier D: Fake Download Progress Card ----------------
      var DOWNLOAD_TEXT_RE =
        /(\\bfinish\\s+(your\\s+)?download\\b|\\bdownload\\s*:|\\bdownload\\s+pending\\b|\\breminder\\s*\\(\\s*\\d+\\s*\\)|\\byour\\s+(download|file|video)\\s+is\\s+(ready|pending)\\b|下载未完成|完成下载|继续下载|下载待完成|下载进度|下载)/i;

      var HIGH_CONF_FAKE_DL_RE =
        /(\\bfinish\\s+(your\\s+)?download\\b|\\bdownload\\s*:\\s*(finish|pending|ready)|\\bdownload\\s+pending\\b|\\breminder\\s*\\(\\s*\\d+\\s*\\)\\s*download\\b|\\byour\\s+download\\s+is\\s+(ready|pending)\\b|下载未完成|完成下载|继续下载|下载待完成)/i;

      var CONTINUE_CTA_RE =
        /^(continue|finish|finish\\s+download|proceed|resume\\s+download|download\\s+now|继续|继续下载|立即继续|完成下载)(\\s*[!！>»→])?$/i;

      var NEG_DISMISS_CTA_RE =
        /^(no,?\\s*thanks?|cancel|later|close|dismiss|skip|not\\s+now|decline|取消|不用了|稍后|关闭)(\\s*[!！])?$/i;

      var BLOCK_GLYPH_RE = /[■█▓▒░▪▬🟩🟥⬜⬛]/g;

      // ---------------- Leaf Text-Anchor Discovery (per-root TreeWalker) ----------------
      var TEXT_ANCHOR_RE =
        /(\\bfinish\\s+(your\\s+)?download\\b|\\bdownload\\s*:|\\bdownload\\s+pending\\b|\\breminder\\s*\\(\\s*\\d+\\s*\\)|下载|您是真人吗|需要验证身份|请验证身份|真人验证|\\bare\\s+you\\s+(a\\s+)?human\\b|\\bverify\\s+you\\s+are\\s+human\\b|\\bhuman\\s+verification\\b|\\brobot\\s+check\\b)/i;

      var CLOSE_TEXT_RE = /^([×✕✖╳xX]|关闭|close)$/i;
      var CLOSE_ATTR_RE = /(close|dismiss|cancel-?ad|btn-?x|icon-?close)/i;
      var ZERO_WIDTH_RE = /[\\u200B-\\u200D\\uFEFF\\u00AD]/g;

      var shadowRoots = new Set();
      var observedRoots = new WeakSet();
      var observedShallowEls = new WeakSet();
      var cardWatchers = new WeakMap();
      var cardReevalTimers = new WeakMap();
      var cardInlineFallback = new WeakSet();
      var cardToWrappers = new WeakMap();
      var wrapperToCards = new WeakMap();
      var frameThrottle = new WeakMap();

      var microQueued = false;
      var rafQueued = false;
      var lastFrameReportTs = 0;

      // ---------------------------------------------------------------------------
      // run #23 (v13): telemetry moved to the shared prologue (xspDiagBump).
      

      // ---------------------------------------------------------------------------
      // 1. Stylesheet-First Clip Hiding & ShadowRoot Capture
      // ---------------------------------------------------------------------------
      function injectStyleSheet(root) {
        try {
          if (root.getElementById && root.getElementById(STYLE_ID)) return true;
          if (root.querySelector && root.querySelector('#' + STYLE_ID)) return true;
          var s = document.createElement('style');
          s.id = STYLE_ID;
          s.textContent =
            '[' + CARD_ATTR + '="1"][' + CARD_ATTR + '="1"],' +
            '[' + BACKDROP_ATTR + '="1"][' + BACKDROP_ATTR + '="1"]{' +
            'clip-path:inset(100%)!important;' +
            '-webkit-clip-path:inset(100%)!important;' +
            'filter:opacity(0)!important;' +
            'pointer-events:none!important;' +
            'transition:none!important;' +
            'animation:none!important;' +
            'user-select:none!important;' +
            '-webkit-user-select:none!important;}' +
            '[' + WRAP_ATTR + '="1"][' + WRAP_ATTR + '="1"]{' +
            'pointer-events:none!important;' +
            'transition:none!important;}';
          var target = root === document ? (document.head || document.documentElement) : root;
          if (!target) return false;
          target.appendChild(s);
          return true;
        } catch (_) {
          return false;
        }
      }

      function registerShadowRoot(root) {
        if (!root || shadowRoots.has(root)) return;
        shadowRoots.add(root);
        injectStyleSheet(root);
        observeRoot(root);
      }

      var origAttachShadow = Element.prototype.attachShadow;
      if (origAttachShadow && !origAttachShadow.__xspFgV10Hooked) {
        try {
          var wrapped = function attachShadow(init) {
            var root = origAttachShadow.call(this, init);
            try {
              registerShadowRoot(root);
              scheduleMicroScan();
            } catch (_) {}
            return root;
          };
          wrapped.__xspFgV10Hooked = true;
          Element.prototype.attachShadow = wrapped;
        } catch (_) {}
      }

      function getAllRoots() {
        var out = [document];
        shadowRoots.forEach(function (sr) {
          if (sr.host && sr.host.isConnected) out.push(sr);
          else shadowRoots.delete(sr);
        });
        return out;
      }

      // ---------------------------------------------------------------------------
      // 2. Layout-Free Text Extraction & visualViewport Coordinates
      // ---------------------------------------------------------------------------
      function normalizeText(s) {
        return (s || '')
          .replace(ZERO_WIDTH_RE, '')
          .replace(/[！]/g, '!')
          .replace(/[：]/g, ':')
          .replace(/[＋]/g, '+')
          .replace(/[？]/g, '?')
          .replace(/\\s+/g, ' ')
          .trim();
      }

      function getCleanText(el, maxLen, skipClippedDescendants) {
        var out = '';
        var stack = [el];
        while (stack.length && out.length <= maxLen) {
          var n = stack.pop();
          if (!n) continue;
          if (n.nodeType === 3) {
            if (n.nodeValue) out += (out ? ' ' : '') + n.nodeValue;
          } else if (n.nodeType === 1) {
            var tag = n.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') continue;
            if (skipClippedDescendants && n !== el && n.getAttribute && n.getAttribute(CARD_ATTR) === '1') continue;
            var kids = n.childNodes;
            for (var i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
          }
        }
        return normalizeText(out);
      }

      function getViewportMetrics() {
        var vv = window.visualViewport;
        if (vv && vv.width > 0 && vv.height > 0) {
          return { w: vv.width, h: vv.height, ox: vv.offsetLeft || 0, oy: vv.offsetTop || 0 };
        }
        return { w: window.innerWidth || 0, h: window.innerHeight || 0, ox: 0, oy: 0 };
      }

      function toViewportRect(rect, vp) {
        return {
          left: rect.left - vp.ox,
          right: rect.right - vp.ox,
          top: rect.top - vp.oy,
          bottom: rect.bottom - vp.oy,
          width: rect.width,
          height: rect.height
        };
      }

      // ---------------------------------------------------------------------------
      // 3. Challenge-Document Stop, Per-Element Challenge Guard & hardVeto(el, txt, prot)
      // ---------------------------------------------------------------------------
      

      

      function matchesChromeToken(el) {
        if (!el || el.nodeType !== 1) return false;
        var tag = el.tagName;
        if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return true;
        if (el.getAttribute && el.getAttribute('role') === 'slider') return true;
        var cls = typeof el.className === 'string' ? el.className : '';
        var id = typeof el.id === 'string' ? el.id : '';
        return PLAYER_CHROME_RE.test(cls) || PLAYER_CHROME_RE.test(id);
      }

      function isInsidePlayerChrome(el) {
        var cur = el;
        for (var up = 0; up < 6 && cur && cur.nodeType === 1; up++, cur = cur.parentElement) {
          if (matchesChromeToken(cur)) return true;
        }
        return false;
      }

      function isInsidePlayerLiveUI(node) {
        var cur = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
        for (var up = 0; up < 6 && cur && cur.nodeType === 1; up++, cur = cur.parentElement) {
          var tag = cur.tagName;
          if (tag === 'VIDEO' || tag === 'AUDIO') return true;
          if (cur.getAttribute && cur.getAttribute('role') === 'slider') return true;
          var cls = typeof cur.className === 'string' ? cur.className : '';
          var id = typeof cur.id === 'string' ? cur.id : '';
          if (PLAYER_LIVE_UI_RE.test(cls) || PLAYER_LIVE_UI_RE.test(id)) return true;
        }
        return false;
      }

      function isPlayerMenuText(txt) {
        if (!txt) return false;
        if (MENU_EXPLICIT_RE.test(txt)) return true;
        var m = txt.match(MENU_OPTION_TOKEN_RE);
        return !!(m && m.length >= 2);
      }

      function buildProtectedContext(roots) {
        var ancestors = new Set();
        var hasVideo = false;

        function markUp(node) {
          var cur = node;
          while (cur) {
            if (ancestors.has(cur)) break;
            ancestors.add(cur);
            cur = cur.parentNode || cur.host || null;
          }
        }

        for (var r = 0; r < roots.length; r++) {
          var root = roots[r];
          if (!root.querySelectorAll) continue;

          var vids = root.querySelectorAll('video');
          if (vids.length > 0) hasVideo = true;
          for (var i = 0; i < vids.length; i++) markUp(vids[i]);

          var controls = root.querySelectorAll(CONTROL_BAR_SELECTOR);
          for (var j = 0; j < controls.length; j++) markUp(controls[j]);

          // run #23: the phone-diag badge host is protected so no classifier can hide it.
          var dbg = root.querySelectorAll('[data-xsp-debug-ui]');
          for (var g = 0; g < dbg.length; g++) markUp(dbg[g]);

          var challenges = root.querySelectorAll(REAL_CHALLENGE_SEL);
          for (var k = 0; k < challenges.length; k++) markUp(challenges[k]);

          var iframes = root.querySelectorAll('iframe[src]');
          for (var f = 0; f < iframes.length; f++) {
            if (SAFE_IFRAME_RE.test(String(iframes[f].src || ''))) markUp(iframes[f]);
          }
        }

        return { ancestors: ancestors, hasVideo: hasVideo, roots: roots };
      }

      function hardVeto(el, txt, prot) {
        if (!el || el.nodeType !== 1) return true;
        var tag = el.tagName;
        if (tag === 'HTML' || tag === 'BODY' || tag === 'HEAD' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'META') {
          return true;
        }
        if (prot && prot.ancestors.has(el)) return true;
        if (isInsidePlayerChrome(el)) return true;
        if (xspIsChallengeProtected(el, prot.roots)) return true;
        if (tag === 'IFRAME' && SAFE_IFRAME_RE.test(String(el.src || ''))) return true;
        if (el.querySelector) {
          if (el.querySelector('video, audio, [role="slider"], input[type="range"]')) return true;
          if (el.querySelector(AUTH_PAY_CAPTCHA_SELECTOR)) return true;
        }
        if (txt) {
          if (isPlayerMenuText(txt)) return true;
          if (NEXT_EPISODE_VETO_RE.test(txt)) return true;
        }
        return false;
      }

      // ---------------------------------------------------------------------------
      // 4. Geometry Pipeline (Real v10 Signatures)
      // ---------------------------------------------------------------------------
      function isInFloatingLayer(el, root, prot) {
        // run #23 (v13): climb restored to the v10 device-confirmed 5.
        if (root !== document) return true;
        var cur = el;
        for (var up = 0; up < 5 && cur && cur.nodeType === 1; up++) {
          if (cur === document.body || cur === document.documentElement || prot.ancestors.has(cur)) break;
          var st = getComputedStyle(cur);
          if (st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
          if (st.position === 'fixed' || st.position === 'absolute') return true;
          cur = cur.parentElement;
        }
        return false;
      }

      function matchesCardGeometry(vrect, vp, isAdSubframe) {
        if (vp.w <= 0 || vp.h <= 0) return false;
        // run #23 (v13): restored the v10 device-confirmed thresholds. Card A already
        // passes these; widen only the failing dimension when a real missed card proves it.
        if (vrect.width < 180 || vrect.height < 88) return false;

        if (isAdSubframe) {
          return vrect.width >= vp.w * 0.52 && vrect.height >= vp.h * 0.32;
        }

        var isLandscape = vp.w > vp.h;
        var wRatio = vrect.width / vp.w;
        var hRatio = vrect.height / vp.h;

        if (isLandscape) {
          if (wRatio < 0.28 || wRatio > 1.02) return false;
          if (hRatio < 0.20 || hRatio > 0.86) return false;
        } else {
          if (wRatio < 0.52 || wRatio > 1.02) return false;
          if (hRatio < 0.15 || hRatio > 0.66) return false;
        }

        var cx = vrect.left + vrect.width / 2;
        var centered = Math.abs(cx - vp.w / 2) <= vp.w * (isLandscape ? 0.24 : 0.22);
        var topOk = vrect.top >= -vp.h * 0.08 && vrect.top <= vp.h * 0.44;
        var notBottomBar = vrect.bottom <= vp.h * (isLandscape ? 0.95 : 0.90);
        return centered && topOk && notBottomBar;
      }

      // ---------------------------------------------------------------------------
      // 5. Shared UI Probes + Classifiers A (VPN), B (View More), C (Verify), D (Download Progress)
      // ---------------------------------------------------------------------------
      function isVisibleColor(c) {
        return !!c && c !== 'rgba(0, 0, 0, 0)' && c !== 'transparent' && c !== 'none';
      }

      

      

      function isActionLikeNode(node, rect, cardRect) {
        var tag = node.tagName;
        if (tag === 'BUTTON' || tag === 'A') return true;
        if (node.getAttribute('role') === 'button') return true;
        if (node.hasAttribute('onclick') || node.hasAttribute('aria-label') || node.hasAttribute('title')) return true;

        var st = getComputedStyle(node);
        if (st.cursor === 'pointer') return true;

        var hasButtonChrome =
          isVisibleColor(st.backgroundColor) ||
          (st.backgroundImage && st.backgroundImage !== 'none') ||
          (parseFloat(st.borderTopWidth) > 0 && isVisibleColor(st.borderTopColor));
        return hasButtonChrome &&
          rect.width >= Math.max(64, cardRect.width * 0.20) &&
          rect.height >= 22 && rect.height <= 80;
      }

      function findCtaButton(card, cardRect, regex) {
        var nodes = card.querySelectorAll('a, button, [role="button"], [onclick], div, span');
        var limit = Math.min(nodes.length, 90);
        for (var i = 0; i < limit; i++) {
          var n = nodes[i];
          if (n.children && n.children.length > 2) continue;
          var t = getCleanText(n, 32, false);
          if (!t || t.length < 2 || t.length > 28) continue;
          if (!regex.test(t)) continue;

          var r = n.getBoundingClientRect();
          if (r.width < 32 || r.height < 16) continue;
          if (!isActionLikeNode(n, r, cardRect)) continue;

          var centerYRatio = (r.top + r.height / 2 - cardRect.top) / Math.max(1, cardRect.height);
          return {
            node: n,
            text: t,
            widthRatio: r.width / Math.max(1, cardRect.width),
            centerYRatio: centerYRatio
          };
        }
        return null;
      }

      function hasTopRightClose(card, cardRect) {
        var nodes = card.querySelectorAll('button, a, [role="button"], [onclick], svg, img, span, div, i');
        var limit = Math.min(nodes.length, 80);
        for (var i = 0; i < limit; i++) {
          var n = nodes[i];
          if (n.children && n.children.length > 3) continue;
          var r = n.getBoundingClientRect();
          if (r.width < 10 || r.height < 10 || r.width > 56 || r.height > 56) continue;
          if (r.right < cardRect.right - 64 || r.top > cardRect.top + 64) continue;

          var t = getCleanText(n, 10, false);
          if (CLOSE_TEXT_RE.test(t)) return true;

          var meta =
            (n.getAttribute('aria-label') || '') + ' ' +
            (n.getAttribute('title') || '') + ' ' +
            (typeof n.className === 'string' ? n.className : '') + ' ' +
            (n.id || '');
          if (CLOSE_ATTR_RE.test(meta)) return true;

          if (n.tagName === 'SVG' || n.tagName === 'IMG' || n.hasAttribute('onclick') || n.querySelector('svg')) return true;

          var st = getComputedStyle(n);
          if (st.cursor === 'pointer' || n.tagName === 'BUTTON' || n.getAttribute('role') === 'button') return true;

          var bc = getComputedStyle(n, '::before').content;
          var ac = getComputedStyle(n, '::after').content;
          if ((bc && bc !== 'none' && bc !== 'normal') || (ac && ac !== 'none' && ac !== 'normal')) return true;
        }
        return false;
      }

      function parseRadiusPx(radiusStr, minSide) {
        if (!radiusStr) return 0;
        var first = radiusStr.split(' ')[0];
        if (first.indexOf('%') >= 0) return (parseFloat(first) / 100) * minSide;
        return parseFloat(first) || 0;
      }

      // Classifier A: VPN / Accelerator Promo Card
      function classifyVpnCard(card, cardRect, fullTxt, hasClose) {
        if (fullTxt.length < 6 || fullTxt.length > 520) return null;
        var cta = findCtaButton(card, cardRect, VPN_DOWNLOAD_CTA_RE);
        if (!cta) return null;

        var hasStrong = VPN_STRONG_RE.test(fullTxt);
        var netAux = 0;
        for (var i = 0; i < VPN_AUX_NET_CLUSTERS.length; i++) {
          if (VPN_AUX_NET_CLUSTERS[i].test(fullTxt)) netAux++;
        }
        var otherAux = 0;
        for (var j = 0; j < VPN_AUX_OTHER_CLUSTERS.length; j++) {
          if (VPN_AUX_OTHER_CLUSTERS[j].test(fullTxt)) otherAux++;
        }
        var totalAux = netAux + otherAux;

        var pathA = hasStrong && hasClose;
        var pathB = hasClose && (totalAux >= 3 || (totalAux >= 2 && netAux >= 1));
        var pathC = hasStrong && totalAux >= 2 && cta.widthRatio >= 0.44 && cta.centerYRatio >= 0.48;

        return (pathA || pathB || pathC) ? { kind: 'vpn-promo', confidence: 'high' } : null;
      }

      // Classifier B: Anonymous Push / Blurred Card (View More)
      function inspectAnonCardVisuals(card, cardRect, ctaNode) {
        var nodes = card.querySelectorAll('img, svg, canvas, div, span, p, i');
        var limit = Math.min(nodes.length, 85);

        var avatarNode = null;
        var blurredOrMaskedRows = 0;
        var distinctBodyGraphic = false;

        var cardSt = getComputedStyle(card);
        if (cardSt.backgroundImage && cardSt.backgroundImage !== 'none' && cardSt.backgroundImage.indexOf('url(') >= 0) {
          distinctBodyGraphic = true;
        }

        for (var i = 0; i < limit; i++) {
          var n = nodes[i];
          if (n === ctaNode || (ctaNode && ctaNode.contains(n))) continue;
          var r = n.getBoundingClientRect();
          if (r.width < 24 || r.width > 108 || r.height < 24 || r.height > 108) continue;
          var ratio = r.width / r.height;
          var inLeft = r.left <= cardRect.left + cardRect.width * 0.46;
          if (!inLeft || ratio < 0.78 || ratio > 1.28) continue;

          var st = getComputedStyle(n);
          var minSide = Math.min(r.width, r.height);
          var rad = parseRadiusPx(st.borderTopLeftRadius, minSide);
          if (rad < minSide * 0.40) continue;

          var hasFill =
            n.tagName === 'IMG' || n.tagName === 'SVG' || n.tagName === 'CANVAS' ||
            (st.backgroundImage && st.backgroundImage !== 'none') ||
            isVisibleColor(st.backgroundColor);
          if (hasFill) {
            avatarNode = n;
            break;
          }
        }

        if (!avatarNode) {
          return { hasAvatar: false, blurredRows: 0, hasDistinctBodyGraphic: false };
        }

        for (var j = 0; j < limit; j++) {
          var m = nodes[j];
          if (m === avatarNode || avatarNode.contains(m)) continue;
          if (m === ctaNode || (ctaNode && ctaNode.contains(m))) continue;
          var mr = m.getBoundingClientRect();
          if (mr.width < 8 || mr.height < 6) continue;

          var mst = getComputedStyle(m);
          var tag = m.tagName;

          var hasBlur =
            (mst.filter && mst.filter.indexOf('blur(') >= 0) ||
            (mst.color === 'rgba(0, 0, 0, 0)' && mst.textShadow && mst.textShadow !== 'none');
          var lowOpacityRow =
            mr.width >= 48 && mr.height >= 8 && mr.height <= 36 &&
            parseFloat(mst.opacity) > 0 && parseFloat(mst.opacity) <= 0.55;
          var skeletonBar =
            (tag === 'DIV' || tag === 'SPAN' || tag === 'P') && m.children.length === 0 &&
            mr.width >= 48 && mr.height >= 6 && mr.height <= 24 &&
            isVisibleColor(mst.backgroundColor) &&
            getCleanText(m, 4, false).length === 0;

          if (hasBlur || lowOpacityRow || skeletonBar) blurredOrMaskedRows++;

          if (!distinctBodyGraphic) {
            var isGraphic =
              tag === 'IMG' || tag === 'CANVAS' ||
              (mst.backgroundImage && mst.backgroundImage !== 'none' && mst.backgroundImage.indexOf('url(') >= 0);
            if (isGraphic && mr.width >= 60 && mr.height >= 24) {
              distinctBodyGraphic = true;
            }
          }
        }

        return {
          hasAvatar: true,
          blurredRows: blurredOrMaskedRows,
          hasDistinctBodyGraphic: distinctBodyGraphic
        };
      }

      function classifyAnonPushCard(card, cardRect, fullTxt, hasClose) {
        if (!hasClose) return null;
        var cta = findCtaButton(card, cardRect, ANON_PUSH_CTA_RE);
        if (!cta) return null;

        var vis = inspectAnonCardVisuals(card, cardRect, cta.node);
        if (!vis.hasAvatar) return null;

        var residualTextLen = Math.max(0, fullTxt.length - cta.text.length - 2);
        var hasDomBlurEvidence = vis.blurredRows >= 2;
        var hasGatedRasterEvidence =
          vis.hasDistinctBodyGraphic && residualTextLen <= 18 && cta.centerYRatio >= 0.46;

        if (!hasDomBlurEvidence && !hasGatedRasterEvidence) return null;
        return { kind: 'anon-push', confidence: 'high' };
      }

      // Classifier C: Fake Human Verification Card (4-way AND; red "!" is NOT used as evidence)
      function classifyFakeVerifyCard(card, cardRect, fullTxt, hasClose) {
        if (!hasClose) return null;
        if (fullTxt.length < 4 || fullTxt.length > 420) return null;
        if (!VERIFY_PHRASE_RE.test(fullTxt)) return null;
        var cta = findCtaButton(card, cardRect, VERIFY_CTA_RE);
        if (!cta) return null;
        return { kind: 'fake-verify', confidence: 'high' };
      }

      // Classifier D: Fake Download Progress Card (supports DOM/SVG/glyph/CSS/img bars + high-conf text fallback)
      

      

      var CONTINUE_STRICT_RE = /^continue\\s*[>›→]?$/i;

      // Classifier D: Fake Download Progress Card (ChatGPT v13, mapped to the real v10 API).
      // D1: download text + Continue + dismiss + real progress structure (DOM/SVG fill /
      // glyph color row, semantic <progress>, unicode block run, gradient / thin bar).
      // D2 (fallback for ::before/::after or opaque-PNG decoration): exact fake-ad phrase
      // family + Continue + dismiss + a large lower-half Continue CTA. Text alone never fires,
      // so a legit user-initiated download dialog (Finish Download + Download pending +
      // Continue + Cancel) is not hidden.
      function colorKind(value) {
        if (!value) return null;
        var m = String(value).match(/rgba?\\(\\s*(\\d+)[,\\s]+(\\d+)[,\\s]+(\\d+)/);
        if (!m) return null;
        var r = Number(m[1]);
        var g = Number(m[2]);
        var b = Number(m[3]);
        if (g >= 70 && g > r * 1.18 && g > b * 1.08) return 'green';
        if (r >= 90 && r > g * 1.20 && r > b * 1.15) return 'red';
        return null;
      }

      function elementPaintKind(el) {
        var cs = getComputedStyle(el);
        var bg = colorKind(cs.backgroundColor);
        if (bg) return bg;
        var color = colorKind(cs.color);
        if (color) return color;
        var vals = [
          el.getAttribute && el.getAttribute('fill'),
          el.getAttribute && el.getAttribute('stroke'),
          cs.fill,
          cs.stroke
        ];
        for (var i = 0; i < vals.length; i++) {
          var kind = colorKind(vals[i]);
          if (kind) return kind;
        }
        return null;
      }

      function getProgressEvidence(card, cardRect, fullTxt) {
        try {
          if (card.querySelector('progress, [role="progressbar"], meter')) return 'semantic-progress';
        } catch (_) {}
        var nodes = card.querySelectorAll('div, span, i, li, td, rect, img, canvas');
        var limit = Math.min(nodes.length, 200);
        var blocks = [];
        for (var i = 0; i < limit; i++) {
          var n = nodes[i];
          var tag = n.tagName;
          var r = n.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) continue;
          // Wide thin horizontal progress bar via CSS gradient or raster image/canvas
          if (r.width >= cardRect.width * 0.35 && r.height >= 4 && r.height <= 28 && (r.width / r.height) >= 4) {
            if (tag === 'IMG' || tag === 'CANVAS') return 'thin-visual-progress-bar';
            var barSt = getComputedStyle(n);
            if (barSt.backgroundImage && barSt.backgroundImage.indexOf('gradient(') >= 0) return 'thin-visual-progress-bar';
          }
          if (r.width < 3 || r.width > 24 || r.height < 3 || r.height > 24) continue;
          if (tag !== 'RECT' && n.children && n.children.length > 0) continue;
          var kind = elementPaintKind(n);
          if (!kind) continue;
          blocks.push({ y: r.top + r.height / 2, kind: kind });
        }
        var rows = [];
        for (var b = 0; b < blocks.length; b++) {
          var row = null;
          for (var k = 0; k < rows.length; k++) {
            if (Math.abs(rows[k].y - blocks[b].y) <= 5) { row = rows[k]; break; }
          }
          if (!row) { row = { y: blocks[b].y, items: [] }; rows.push(row); }
          row.items.push(blocks[b]);
        }
        for (var m = 0; m < rows.length; m++) {
          var greens = 0;
          var reds = 0;
          for (var q = 0; q < rows[m].items.length; q++) {
            if (rows[m].items[q].kind === 'green') greens++;
            else if (rows[m].items[q].kind === 'red') reds++;
          }
          if (rows[m].items.length >= 6 && greens >= 4 && reds >= 1) return 'colored-block-row';
        }
        if (/[■█▓▒░▪▬◼🟩🟥]{5,}/u.test(fullTxt)) return 'unicode-block-run';
        return null;
      }

      function hasDismissControl(card, hasClose) {
        if (hasClose) return true;
        var nodes = card.querySelectorAll('button, a, [role="button"], input[type="button"], input[type="submit"]');
        for (var i = 0; i < nodes.length; i++) {
          var t = getCleanText(nodes[i], 24, false);
          if (t && NEG_DISMISS_CTA_RE.test(t)) return true;
        }
        return false;
      }

      function hasLargeLowerCTA(card, cardRect) {
        var cta = findCtaButton(card, cardRect, CONTINUE_STRICT_RE);
        if (!cta) return false;
        var r = cta.node.getBoundingClientRect();
        return r.width >= cardRect.width * 0.55 && r.height >= 28 &&
          r.top >= cardRect.top + cardRect.height * 0.48;
      }

      function classifyFakeDownloadProgressCard(card, cardRect, fullTxt, hasClose) {
        if (fullTxt.length < 6 || fullTxt.length > 520) return null;
        if (!DOWNLOAD_TEXT_RE.test(fullTxt)) return null;
        if (!findCtaButton(card, cardRect, CONTINUE_STRICT_RE)) return null;
        if (!hasDismissControl(card, hasClose)) return null;
        if (getProgressEvidence(card, cardRect, fullTxt)) return { kind: 'fake-dl-progress', confidence: 'high' };
        if (HIGH_CONF_FAKE_DL_RE.test(fullTxt) && hasLargeLowerCTA(card, cardRect)) return { kind: 'fake-dl-progress', confidence: 'high' };
        return null;
      }

      function classifyElement(el, root, prot, vp, isAdSubframe) {
        var txt = getCleanText(el, 600, false);
        if (hardVeto(el, txt, prot)) return null;
        if (!isInFloatingLayer(el, root, prot)) return null;

        var rect = el.getBoundingClientRect();
        var vrect = toViewportRect(rect, vp);
        if (!matchesCardGeometry(vrect, vp, isAdSubframe)) return null;

        var hasClose = hasTopRightClose(el, rect);
        return (
          classifyVpnCard(el, rect, txt, hasClose) ||
          classifyAnonPushCard(el, rect, txt, hasClose) ||
          classifyFakeVerifyCard(el, rect, txt, hasClose) ||
          classifyFakeDownloadProgressCard(el, rect, txt, hasClose)
        );
      }

      // ---------------------------------------------------------------------------
      // 6. Stylesheet-First Hide, Click-Shell Disarm & Re-Eval Unhide (Real v10 API)
      // ---------------------------------------------------------------------------
      var INLINE_FALLBACK_PROPS = [
        ['clip-path', 'inset(100%)'],
        ['-webkit-clip-path', 'inset(100%)'],
        ['filter', 'opacity(0)'],
        ['pointer-events', 'none'],
        ['transition', 'none'],
        ['animation', 'none']
      ];

      function applyInlineFallback(el) {
        cardInlineFallback.add(el);
        for (var i = 0; i < INLINE_FALLBACK_PROPS.length; i++) {
          var prop = INLINE_FALLBACK_PROPS[i][0];
          var val = INLINE_FALLBACK_PROPS[i][1];
          if (el.style.getPropertyValue(prop) !== val || el.style.getPropertyPriority(prop) !== 'important') {
            el.style.setProperty(prop, val, 'important');
          }
        }
      }

      function clearInlineFallback(el) {
        if (!cardInlineFallback.has(el)) return;
        cardInlineFallback.delete(el);
        for (var i = 0; i < INLINE_FALLBACK_PROPS.length; i++) {
          el.style.removeProperty(INLINE_FALLBACK_PROPS[i][0]);
        }
      }

      function enforceHideEffect(el, attrName) {
        if (el.getAttribute(attrName) !== '1') el.setAttribute(attrName, '1');
        if (el.getAttribute('aria-hidden') !== 'true') el.setAttribute('aria-hidden', 'true');

        var st = getComputedStyle(el);
        var clip = st.clipPath || st.webkitClipPath || '';
        var clippedOk = clip.indexOf('inset(100%)') >= 0;
        var pointerOk = st.pointerEvents === 'none';
        if (!clippedOk || !pointerOk) {
          applyInlineFallback(el);
        }
      }

      function releaseWrappersForCard(card) {
        var wraps = cardToWrappers.get(card);
        if (!wraps) return;
        wraps.forEach(function (w) {
          var set = wrapperToCards.get(w);
          if (set) {
            set.delete(card);
            if (set.size === 0) {
              w.removeAttribute(WRAP_ATTR);
              w.removeAttribute(BACKDROP_ATTR);
              clearInlineFallback(w);
              wrapperToCards.delete(w);
            }
          }
        });
        cardToWrappers.delete(card);
      }

      function unhideCard(card) {
        var obs = cardWatchers.get(card);
        if (obs) {
          try { obs.disconnect(); } catch (_) {}
          cardWatchers.delete(card);
        }
        var tid = cardReevalTimers.get(card);
        if (tid) {
          clearTimeout(tid);
          cardReevalTimers.delete(card);
        }
        card.removeAttribute(CARD_ATTR);
        if (card.getAttribute('aria-hidden') === 'true') card.removeAttribute('aria-hidden');
        clearInlineFallback(card);
        releaseWrappersForCard(card);
      }

      function scheduleCardReeval(card, root) {
        if (cardReevalTimers.has(card)) return;
        var tid = setTimeout(function () {
          cardReevalTimers.delete(card);
          if (!card.isConnected) {
            unhideCard(card);
            return;
          }
          var roots = getAllRoots();
          var prot = buildProtectedContext(roots);
          var vp = getViewportMetrics();
          var isAdSubframe = window !== window.top && !prot.hasVideo;
          var stillAd = classifyElement(card, root, prot, vp, isAdSubframe);
          if (!stillAd) {
            unhideCard(card);
          } else {
            enforceHideEffect(card, CARD_ATTR);
          }
        }, 180);
        cardReevalTimers.set(card, tid);
      }

      function disarmClickShells(card, root, prot, vp) {
        var cardRect = card.getBoundingClientRect();
        var cardArea = Math.max(1, cardRect.width * cardRect.height);
        var cur = card.parentElement;

        for (var up = 0; up < 4 && cur; up++, cur = cur.parentElement) {
          if (hardVeto(cur, '', prot)) break;
          var st = getComputedStyle(cur);
          if (st.position !== 'fixed' && st.position !== 'absolute') continue;

          var leftoverText = getCleanText(cur, 12, true);
          if (leftoverText.length > 4) break;

          var others = cur.querySelectorAll('video, iframe, button, a, input, select, textarea, img, canvas');
          var hasIndependentContent = false;
          for (var i = 0; i < others.length; i++) {
            var o = others[i];
            if (!card.contains(o) && !o.closest('[' + CARD_ATTR + '="1"]')) {
              hasIndependentContent = true;
              break;
            }
          }
          if (hasIndependentContent) break;

          var r = cur.getBoundingClientRect();
          var area = Math.max(1, r.width * r.height);
          var ix = Math.max(0, Math.min(r.right, cardRect.right) - Math.max(r.left, cardRect.left));
          var iy = Math.max(0, Math.min(r.bottom, cardRect.bottom) - Math.max(r.top, cardRect.top));
          var overlap = (ix * iy) / cardArea;

          var isTightShell = overlap >= 0.78 && area <= cardArea * 1.45;
          var z = parseInt(st.zIndex, 10);
          var isFullBackdrop =
            vp.w > 0 && vp.h > 0 &&
            r.width >= vp.w * 0.60 && r.height >= vp.h * 0.60 &&
            (st.position === 'fixed' || (Number.isFinite(z) && z >= 10));

          if (!isTightShell && !isFullBackdrop) continue;

          var hasDimmingVisual =
            isVisibleColor(st.backgroundColor) ||
            (st.backdropFilter && st.backdropFilter !== 'none') ||
            (st.webkitBackdropFilter && st.webkitBackdropFilter !== 'none');

          if (hasDimmingVisual) {
            enforceHideEffect(cur, BACKDROP_ATTR);
          } else {
            if (cur.getAttribute(WRAP_ATTR) !== '1') cur.setAttribute(WRAP_ATTR, '1');
            if (getComputedStyle(cur).pointerEvents !== 'none') {
              cur.style.setProperty('pointer-events', 'none', 'important');
              cardInlineFallback.add(cur);
            }
          }

          if (!cardToWrappers.has(card)) cardToWrappers.set(card, new Set());
          cardToWrappers.get(card).add(cur);
          if (!wrapperToCards.has(cur)) wrapperToCards.set(cur, new Set());
          wrapperToCards.get(cur).add(card);
        }

        if (root !== document && root.host && !hardVeto(root.host, '', prot)) {
          if (root.host.getAttribute(WRAP_ATTR) !== '1') root.host.setAttribute(WRAP_ATTR, '1');
          if (!cardToWrappers.has(card)) cardToWrappers.set(card, new Set());
          cardToWrappers.get(card).add(root.host);
          if (!wrapperToCards.has(root.host)) wrapperToCards.set(root.host, new Set());
          wrapperToCards.get(root.host).add(card);
        }
      }

      function hideCard(card, root, prot, vp) {
        var txt = getCleanText(card, 600, false);
        if (hardVeto(card, txt, prot)) return false;

        injectStyleSheet(root);
        enforceHideEffect(card, CARD_ATTR);
        disarmClickShells(card, root, prot, vp);

        if (!cardWatchers.has(card) && typeof MutationObserver !== 'undefined') {
          try {
            var obs = new MutationObserver(function (mutations) {
              var attrChanged = false;
              var contentChanged = false;
              for (var i = 0; i < mutations.length; i++) {
                var t = mutations[i].type;
                if (t === 'attributes') attrChanged = true;
                else contentChanged = true;
              }
              if (attrChanged) enforceHideEffect(card, CARD_ATTR);
              if (contentChanged) scheduleCardReeval(card, root);
            });
            obs.observe(card, {
              attributes: true,
              attributeFilter: ['style', 'class', 'hidden', 'aria-hidden', CARD_ATTR],
              childList: true,
              characterData: true,
              subtree: true
            });
            cardWatchers.set(card, obs);
          } catch (_) {}
        }
        return true;
      }

      // ---------------------------------------------------------------------------
      // 7. Cross-Origin Subframe Report Bridge
      // ---------------------------------------------------------------------------
      function reportAdCardToParent(hasVideo, matchInfo) {
        if (window === window.top || hasVideo) return;
        var now = Date.now();
        if (now - lastFrameReportTs < 250) return;
        lastFrameReportTs = now;
        try {
          window.parent.postMessage({
            type: 'XSP_FLOATING_CARD_GUARD',
            version: 10,
            action: 'clip-ad-card-frame',
            kind: matchInfo.kind,
            confidence: matchInfo.confidence,
            nonce: NONCE
          }, '*');
        } catch (_) {}
      }

      window.addEventListener('message', function (ev) {
        var d = ev.data;
        if (!d || d.type !== 'XSP_FLOATING_CARD_GUARD' || d.version !== 10 ||
            d.action !== 'clip-ad-card-frame' || d.confidence !== 'high' || d.nonce !== NONCE) {
          return;
        }
        ev.stopImmediatePropagation();

        var roots = getAllRoots();
        var prot = buildProtectedContext(roots);
        var vp = getViewportMetrics();
        var clippedAny = false;

        for (var r = 0; r < roots.length; r++) {
          var root = roots[r];
          var iframes = root.querySelectorAll ? root.querySelectorAll('iframe') : [];
          for (var i = 0; i < iframes.length; i++) {
            var frame = iframes[i];
            try {
              if (frame.contentWindow !== ev.source) continue;
              var now = Date.now();
              if (now - (frameThrottle.get(frame) || 0) < 250) continue;
              frameThrottle.set(frame, now);

              if (hardVeto(frame, '', prot)) continue;

              var allowClip = prot.hasVideo;
              if (!allowClip) {
                var st = getComputedStyle(frame);
                var rRect = frame.getBoundingClientRect();
                var isFloating = st.position === 'fixed' || st.position === 'absolute';
                var smallerThanFullPage = vp.w > 0 && vp.h > 0 && (rRect.width < vp.w * 0.90 || rRect.height < vp.h * 0.85);
                allowClip = isFloating || smallerThanFullPage;
              }

              if (allowClip) {
                injectStyleSheet(root);
                enforceHideEffect(frame, CARD_ATTR);
                disarmClickShells(frame, root, prot, vp);
                clippedAny = true;
              }
            } catch (_) {}
          }
        }

        if (!prot.hasVideo && window !== window.top && clippedAny) {
          reportAdCardToParent(false, { kind: d.kind, confidence: 'high' });
        }
      }, true);

      // ---------------------------------------------------------------------------
      // 8. Per-Root Candidate Discovery (Top Layers + CTA Upward + Leaf Text-Anchor Climb)
      // ---------------------------------------------------------------------------
      function collectCandidates(root, prot) {
        var seen = new Set();
        var out = [];

        function push(el) {
          if (!el || el.nodeType !== 1 || seen.has(el)) return;
          try { if (el.closest && el.closest('[data-xsp-debug-ui]')) return; } catch (_) {}
          if (el.getAttribute(CARD_ATTR) === '1' || prot.ancestors.has(el)) return;
          var tag = el.tagName;
          if (tag === 'HEAD' || tag === 'BODY' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'META') return;
          if (el.shadowRoot && !shadowRoots.has(el.shadowRoot)) registerShadowRoot(el.shadowRoot);
          seen.add(el);
          out.push(el);
        }

        // Entry 1: top 1-3 layers + shallow attribute observers
        var topContainers = [];
        if (root === document) {
          if (document.documentElement) topContainers.push(document.documentElement);
          if (document.body) topContainers.push(document.body);
        } else {
          topContainers.push(root);
        }

        for (var c = 0; c < topContainers.length; c++) {
          var kids1 = topContainers[c].children;
          if (!kids1) continue;
          for (var i = 0; i < kids1.length; i++) {
            var k1 = kids1[i];
            if (!prot.ancestors.has(k1)) observeShallowElement(k1);
            push(k1);
            var kids2 = k1.children;
            if (kids2 && kids2.length <= 16) {
              for (var j = 0; j < kids2.length; j++) {
                var k2 = kids2[j];
                if (!prot.ancestors.has(k2)) observeShallowElement(k2);
                push(k2);
                var kids3 = k2.children;
                if (kids3 && kids3.length <= 10) {
                  for (var m = 0; m < kids3.length; m++) push(kids3[m]);
                }
              }
            }
          }
        }

        // Entry 2: CTA upward discovery (VPN / View More / Verify / Continue)
        if (root.querySelectorAll) {
          var nodes = root.querySelectorAll('a, button, [role="button"], [onclick], div, span');
          for (var b = 0; b < nodes.length; b++) {
            var n = nodes[b];
            if (n.children && n.children.length > 2) continue;
            if (prot.ancestors.has(n)) continue;
            var t = getCleanText(n, 30, true);
            if (!t || t.length < 2 || t.length > 26) continue;
            if (!VPN_DOWNLOAD_CTA_RE.test(t) && !ANON_PUSH_CTA_RE.test(t) &&
                !VERIFY_CTA_RE.test(t) && !CONTINUE_CTA_RE.test(t)) {
              continue;
            }

            var cur = n.parentElement;
            for (var up = 0; up < 6 && cur && cur !== document.body && cur !== document.documentElement; up++) {
              if (prot.ancestors.has(cur)) break;
              push(cur);
              cur = cur.parentElement;
            }
          }
        }

        // Entry 3: Per-root leaf text-anchor discovery (TreeWalker: O(textNodes), zero layout flush)
        try {
          var walkStart = root === document ? (document.body || document.documentElement) : root;
          if (walkStart && document.createTreeWalker && typeof NodeFilter !== 'undefined') {
            var walker = document.createTreeWalker(walkStart, NodeFilter.SHOW_TEXT, null);
            var tNode;
            var textVisits = 0;
            while ((tNode = walker.nextNode()) && textVisits < 2500) {
              textVisits++;
              var raw = tNode.nodeValue;
              if (!raw || raw.length < 2 || raw.length > 200) continue;
              var parentEl = tNode.parentElement;
              if (!parentEl) continue;
              var pTag = parentEl.tagName;
              if (pTag === 'SCRIPT' || pTag === 'STYLE' || pTag === 'NOSCRIPT' || pTag === 'TEMPLATE') continue;
              if (isInsidePlayerLiveUI(parentEl)) continue;

              var norm = normalizeText(raw);
              if (!norm || !TEXT_ANCHOR_RE.test(norm)) continue;

              var anc = parentEl;
              for (var climb = 0; climb < 8 && anc && anc !== document.body && anc !== document.documentElement; climb++) {
                if (prot.ancestors.has(anc)) break;
                push(anc);
                anc = anc.parentElement;
              }
            }
          }
        } catch (_) {}

        return out;
      }

      function recordHitDiag(kind) {
        if (kind === 'vpn-promo') xspDiagBump('v10HidVpn', 'v10:vpn');
        else if (kind === 'anon-push') xspDiagBump('v10HidAnon', 'v10:anon');
        else if (kind === 'fake-verify') xspDiagBump('v10HidVerify', 'v10:verify');
        else if (kind === 'fake-dl-progress') xspDiagBump('v10HidDlProg', 'v10:dlprog');
      }

      function scanOnce() {
        microQueued = false;
        rafQueued = false;
        if (document.hidden) return;
        try {
          injectStyleSheet(document);
          var roots = getAllRoots();
          var prot = buildProtectedContext(roots);

          xspInstallPhoneDiag();
          if (xspChallengeGate()) {
            xspDiagBump('v10SkipChallengeDoc');
            return;
          }
          xspDiagBump('v10Runs');

          var vp = getViewportMetrics();
          var isAdSubframe = window !== window.top && !prot.hasVideo;
          var matched = [];
          var totalCandidates = 0;

          for (var r = 0; r < roots.length; r++) {
            var root = roots[r];
            var raw = collectCandidates(root, prot);
            totalCandidates += raw.length;
            var geoPassed = [];

            for (var i = 0; i < raw.length; i++) {
              var el = raw[i];
              if (isInsidePlayerChrome(el)) continue;
              if (!isInFloatingLayer(el, root, prot)) continue;
              var rect = el.getBoundingClientRect();
              var vrect = toViewportRect(rect, vp);
              if (!matchesCardGeometry(vrect, vp, isAdSubframe)) continue;
              geoPassed.push({ el: el, rect: rect, area: rect.width * rect.height });
            }

            // Smallest match first so inner card is clipped before any outer container
            geoPassed.sort(function (a, b) { return a.area - b.area; });

            var confirmedInRoot = [];
            for (var g = 0; g < geoPassed.length; g++) {
              var item = geoPassed[g];
              var cand = item.el;

              var wrapsConfirmed = false;
              for (var c = 0; c < confirmedInRoot.length; c++) {
                if (cand.contains(confirmedInRoot[c])) {
                  wrapsConfirmed = true;
                  break;
                }
              }
              if (wrapsConfirmed) continue;

              var txt = getCleanText(cand, 600, false);
              if (hardVeto(cand, txt, prot)) continue;

              var hasClose = hasTopRightClose(cand, item.rect);
              var hit =
                classifyVpnCard(cand, item.rect, txt, hasClose) ||
                classifyAnonPushCard(cand, item.rect, txt, hasClose) ||
                classifyFakeVerifyCard(cand, item.rect, txt, hasClose) ||
                classifyFakeDownloadProgressCard(cand, item.rect, txt, hasClose);

              if (hit) {
                confirmedInRoot.push(cand);
                matched.push({ el: cand, root: root, hit: hit });
              }
            }
          }

          xspDiagBump('v10Candidates', totalCandidates);
          var firstHit = null;
          for (var m = 0; m < matched.length; m++) {
            var entry = matched[m];
            if (hideCard(entry.el, entry.root, prot, vp)) {
              recordHitDiag(entry.hit.kind);
              if (!firstHit) firstHit = entry.hit;
            }
          }

          if (firstHit) {
            reportAdCardToParent(prot.hasVideo, firstHit);
          }
        } catch (_) {}
      }

      function scheduleMicroScan() {
        if (!microQueued) {
          microQueued = true;
          if (typeof queueMicrotask === 'function') queueMicrotask(scanOnce);
          else Promise.resolve().then(scanOnce);
        }
        scheduleRafScan();
      }

      function scheduleRafScan() {
        if (rafQueued) return;
        rafQueued = true;
        if (typeof requestAnimationFrame === 'function') requestAnimationFrame(scanOnce);
        else setTimeout(scanOnce, 16);
      }

      // ---------------------------------------------------------------------------
      // 9. Observers: childList (microtask) + filtered characterData (rAF) + shallow attributes
      // ---------------------------------------------------------------------------
      function observeShallowElement(el) {
        if (!el || el.nodeType !== 1 || observedShallowEls.has(el)) return;
        var tag = el.tagName;
        if (tag === 'HEAD' || tag === 'BODY' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK') return;
        if (matchesChromeToken(el)) return;
        observedShallowEls.add(el);
        try {
          var obs = new MutationObserver(function () {
            if (el.getAttribute(CARD_ATTR) !== '1' &&
                el.getAttribute(WRAP_ATTR) !== '1' &&
                el.getAttribute(BACKDROP_ATTR) !== '1') {
              scheduleMicroScan();
            }
          });
          obs.observe(el, { attributes: true, attributeFilter: ['style', 'class', 'hidden'] });
        } catch (_) {}
      }

      function observeRoot(root) {
        if (!root || observedRoots.has(root) || typeof MutationObserver === 'undefined') return;
        var target = root === document ? document.documentElement : root;
        if (!target) return;
        observedRoots.add(root);
        try {
          var mo = new MutationObserver(function (mutations) {
            var needMicro = false;
            var needRaf = false;

            for (var i = 0; i < mutations.length; i++) {
              var m = mutations[i];
              if (m.type === 'childList') {
                var added = m.addedNodes;
                if (!added || added.length === 0) continue;
                for (var j = 0; j < added.length; j++) {
                  var n = added[j];
                  if (n.nodeType === 1 && !isInsidePlayerLiveUI(n)) {
                    needMicro = true;
                    break;
                  }
                }
              } else if (m.type === 'characterData') {
                if (!isInsidePlayerLiveUI(m.target)) {
                  needRaf = true;
                }
              }
              if (needMicro) break;
            }

            if (needMicro) scheduleMicroScan();
            else if (needRaf) scheduleRafScan();
          });

          mo.observe(target, { childList: true, characterData: true, subtree: true });
        } catch (_) {}
      }

      function boot() {
        injectStyleSheet(document);
        observeRoot(document);
        scanOnce();
      }

      if (document.documentElement) boot();
      else document.addEventListener('DOMContentLoaded', boot, { once: true });

      window.addEventListener('load', scheduleMicroScan);
      window.addEventListener('resize', scheduleRafScan);
      if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', scheduleRafScan);
      }
      document.addEventListener('visibilitychange', function () {
        if (!document.hidden) scheduleRafScan();
      });

      setInterval(function () {
        if (!document.hidden) scanOnce();
      }, 1200);
    })();
    """).replacingOccurrences(of: "__XSP_SESSION_NONCE__", with: nonce)
    }
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
/// 挑战标记、turnstile）统一等 12 秒，让挑战 JS 自己完成；12 秒还没出
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
    /// 页内 video 是不是在全屏（fullscreenchange 事件回传 + 探针轮询
    /// 双通道；两通道都含 webkit 全屏判定——iPhone 上 <video> 全屏走
    /// webkitEnterFullscreen，document.fullscreenElement 恒 null）：
    /// 外层据此同步 DetailView.isFullscreen，
    /// 全屏进出触发的 onDisappear 才不会误停播。stop() 故意不重置它——
    /// 全屏进出也会触发 onDisappear → probe.stop()，清掉就把 DetailView
    /// 的全屏判断也清掉了。
    @Published var isFullscreen = false
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

    deinit {
        // 兜底：stop() 没调到就释放时，把跑着的 Timer 停掉（Timer 被 RunLoop 强持有，
        // 不停会一直空转；闭包是 [weak self] 不成环，但 Timer 本身会泄漏）。
        timer?.invalidate()
        hideTask?.cancel()
    }

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
                // 挑战判定与 AdStripScript v13 的 xspIsCloudflareChallengeDocument 对齐
                //（同一文件里的共享门）：标题信号必须配挑战脚本才算数，裸 [id*="cf-"]
                // 与“您是真人吗”一律不算——假真人验证卡自己就带“您是真人吗”，
                // v13 明确说了它绝不能当触发词；裸 cf- 会误伤带 cf 前缀的普通元素。
                // 标题 alone 不够：要 titleSignal && scriptSignal（或 url/marker/global 强信号）。
                var href = (document.location && document.location.href || '').toLowerCase();
                var t = (document.title || '').toLowerCase();
                var titleSignal = /just a moment|checking your browser|verify you are human|正在验证|请稍候/.test(t);
                var scriptSignal = !!document.querySelector('script[src*="/cdn-cgi/challenge-platform/"]');
                var urlSignal = href.indexOf('challenges.cloudflare.com') >= 0 ||
                  href.indexOf('/cdn-cgi/challenge-platform/') >= 0;
                var globalSignal = !!(window._cf_chl_opt);
                if (titleSignal) { cfTitle = true; }
                if ((titleSignal && scriptSignal) || urlSignal || globalSignal) { cf = true; }
                if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) cf = true;
                if (document.querySelector('iframe[src*="turnstile"]')) cf = true;
                if (document.querySelector('#challenge-form, #challenge-running, #challenge-stage, #cf-wrapper, #cf-spinner, #cf-browser-verification, [id*="cf-chl-"], [class*="cf-challenge"], [class*="challenge-running"], [class*="turnstile"]')) cf = true;
              } catch(e){}
              // iPhone 上 <video> 全屏走 webkitEnterFullscreen，document.fullscreenElement
              // 恒 null：再并上 webkitFullscreenElement 与 video 元素的
              // webkitDisplayingFullscreen，否则页内自带全屏按钮进全屏也探不到。
              var fs = !!(document.fullscreenElement || document.webkitFullscreenElement || (v && v.webkitDisplayingFullscreen));
              if (!v) return JSON.stringify({cf: cf, cfTitle: cfTitle, fs: fs});
              return JSON.stringify({t: v.currentTime, d: v.duration, p: v.paused, cf: cf, cfTitle: cfTitle, fs: fs});
            })();
            """
        ) { [weak self] result, _ in
            guard let self else { return }
            guard let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.hasVideo = false
                // JS 求值失败/返回非 JSON 也要跑看门狗：WebContent 进程崩溃或
                // 页面死锁时 evaluateJavaScript 永远拿不到结果，不调这里就永远
                // 卡在“正在加载…”不报失败。
                self.checkWatchdog(challengeRunning: false)
                return
            }
            // 全屏状态轮询纠正（与 fullscreenchange 消息双通道）：底条全屏按钮
            // 是乐观先置 true，页内自带全屏按钮走消息；万一消息漏了，0.5 秒
            // 一次的轮询也能把状态扳回来（轮询的 fs 已含 webkit 全屏通道，
            // 见 probe() 内 fs 的算法）。
            // 但跨域 iframe 全屏时主框架探不到 video（findVideoJS 只查同源
            // iframe，跨域返回 null，本轮 JSON 里没有 "t"，fs 恒 false）：
            // 无条件覆写会在 0.5 秒内把 fullscreenScript 多帧消息通道上报的
            // true 扳回 false。所以只在主框架/同源确实拿到 <video>（"t" 存在）
            // 或 fs == true 时才用轮询覆写；v == nil 时保留消息通道的值。
            let fs = (json["fs"] as? Bool) ?? false
            if json["t"] != nil || fs {
                self.isFullscreen = fs
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
            // 挑战在跑：重载后 15 秒仍没 video 也算失败（以前这里直接 return，
            // reloadAt 的 15 秒窗口在挑战期永远跑不到，注释写的行为没实现）。
            if let reloadedAt = reloadAt,
               Date().timeIntervalSince(reloadedAt) >= 15 {
                failEmbed("嵌页重载后 15 秒仍没出画面（验证还在跑），请开节点或点重试")
            } else if let since = challengeSince,
               Date().timeIntervalSince(since) >= 45 {
                failEmbed("Cloudflare 验证一直没通过（45 秒），请开节点或点重试")
            } else if let started = loadStartedAt,
                      Date().timeIntervalSince(started) >= 45 {
                // 总超时兜底：CF 挑战页每 8–10 秒自动刷新一次，刷新瞬间
                // cfRunning == false 会把 challengeSince 清零（probe 的
                // else 分支），12 秒重载与 45 秒 challengeSince 永远到不了；
                // 用 loadStartedAt 算总账，挑战从头跑满 45 秒就终局，不无限循环。
                failEmbed("Cloudflare 验证超时（45 秒），请开节点或点重试")
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
    /// 没 video 时仍尝试整个页面全屏，但不乐观置位；页内播放器自带的全屏按钮同样可用。
    /// iPhone 上 <video> 全屏走 webkitEnterFullscreen（requestFullscreen /
    /// webkitRequestFullscreen 在 iPhone 上可能只是空壳），末尾补上它。
    func requestFullscreen() {
        // 仅 JS 真找到 video 并已发起全屏请求时才乐观置 true：没 video
        // 时不置位——跨域 iframe 下探针 v == nil 时不再覆写，无条件的乐观
        // true 会永远卡住、等不到任何通道扳回来。documentElement 兜底分支
        // 只发起请求、返回 false：真成功时 fullscreenchange 消息与探针的
        // fs == true 会自动置位；若因缺 JS 用户手势被静默拒绝（iPad / Duo
        // 内屏），不触发 fullscreenchange、探针又因 "t" 缺失且 fs 为 false
        // 而跳过覆写，乐观 true 会永久卡住并阻断离页停播。
        // 有 video 但请求失败时，下一轮探针（"t" 存在）会按 fs 把它扳回 false。
        webView?.evaluateJavaScript(
            """
            (function(){
              var v = \(findVideoJS);
              if (v) {
                if (v.requestFullscreen) v.requestFullscreen();
                else if (v.webkitRequestFullscreen) v.webkitRequestFullscreen();
                else if (v.webkitEnterFullscreen) v.webkitEnterFullscreen();
                return true;
              } else if (document.documentElement.requestFullscreen) {
                document.documentElement.requestFullscreen();
                return false;
              }
              return false;
            })();
            """,
            completionHandler: { [weak self] result, _ in
                guard let self, self.webView != nil else { return }
                if (result as? Bool) == true { self.isFullscreen = true }
            }
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
final class EmbedWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
    private let url: URL
    private let probe: EmbedProbeState
    private let adStrip: Bool
    private var webView: WKWebView?
    private var loadedURL: URL?
    /// 上次见到的重试计数（run #36 P0-11）：retryNonce 变了=用户点了
    /// “重试嵌入播放”，即使 URL 相同也要强制重载（以前 guard loadedURL != url
    /// 直接早退，重试按钮是摆设）。
    private var lastRetryNonce: Int?
    /// 建 VC 时的重试计数（run #36 R2）：viewDidLoad 的首载就用它，
    /// 不能写死 0——retryNonce > 0 时重建 VC，首载用 0、updateUIViewController
    /// 再传 >0 会触发二次重载 + 二次 CloudflareWarmup。
    private let initialRetryNonce: Int
    private var navigationStartAt: Date?
    /// CF 兜底已关过广告规则：为 true 后不再装规则（堵异步编译完成又把规则装回去的竞态）。
    private var adRulesDisabled = false

    init(url: URL, probe: EmbedProbeState, adStrip: Bool = true, initialRetryNonce: Int = 0) {
        self.url = url
        self.probe = probe
        self.adStrip = adStrip
        self.initialRetryNonce = initialRetryNonce
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
            let script = WKUserScript(source: AdStripScript.source(diagBadgeEnabled: UserDefaults.standard.bool(forKey: "xspDiagBadgeEnabled")), injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)
        }

        // 全屏状态回传（run #36 R3）：页内 video 进/退全屏时立即通知探针，
        // 不靠 0.5 秒轮询——轮询可能在 DetailView.onDisappear 之后才跑到，
        // 全屏一进就被 playerVM.stop() 打断。只报状态，不碰播放；
        // 与 adStrip 无关，剥离关掉也要报。
        // iPhone 上 <video> 全屏走 webkitEnterFullscreen：document.fullscreenElement
        // 恒 null，须并上 webkitFullscreenElement 与 video 元素的
        // webkitDisplayingFullscreen；webkitbeginfullscreen/webkitendfullscreen
        // 在 video 元素上触发，用 document 捕获阶段监听（冒泡与否都兜住），
        // video 可能藏在同源 iframe 里，沿用 findVideoJS 去找。
        let fullscreenScript = WKUserScript(source: """
            (function(){
              function report(){ try { var v = \(findVideoJS); window.webkit.messageHandlers.xspFullscreen.postMessage(!!(document.fullscreenElement || document.webkitFullscreenElement || (v && v.webkitDisplayingFullscreen))); } catch(e){} }
              document.addEventListener('fullscreenchange', report);
              document.addEventListener('webkitfullscreenchange', report);
              document.addEventListener('webkitbeginfullscreen', report, true);
              document.addEventListener('webkitendfullscreen', report, true);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(fullscreenScript)
        config.userContentController.add(self, name: "xspFullscreen")

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

        loadIfNeeded(url: url, retryNonce: initialRetryNonce)
    }

    @objc private func handleWebViewTap() {
        probe.toggleControls()
    }

    /// 全屏状态回传：fullscreenchange/webkitfullscreenchange 事件到即报，
    /// 主线程回调，直接写探针状态。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "xspFullscreen", let fullscreen = message.body as? Bool else { return }
        probe.isFullscreen = fullscreen
    }

    // 绝不抢 WKWebView 内层手势（播放器按钮/进度条照常用）：两个手势同时识别。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// URL 不变不重载，避免 SwiftUI 刷新时打断正在播的嵌入页；但 retryNonce
    /// 变了（用户点了“重试嵌入播放”）必须强制重载，即使 URL 相同。
    /// 只做 URL 加载：探针 reset 不在这里做（SwiftUI 更新期调它会改
    /// @Published，撞上视图更新）；切 URL 时 WebViewPlayerView 的
    /// .onChange(of: url) 会调 probe.stop()/start()。
    /// run #20 F2：/e/ URL 立即在播放 WebView 里加载，不再等 30 秒预热门；
    /// 预热只在后台并行跑（给播放 WebView 预种 cf_clearance cookie，
    /// 完事不改已在加载的页面）。以前：没 clearance 就先暖 3×10 秒，
    /// 暖完才加载——白屏 10–30 秒就是这么来的。
    func loadIfNeeded(url: URL, retryNonce: Int = 0) {
        // teardown 后 webView 已是 nil：直接早退，绝不把 loadedURL 重新写回非空、
        // 也不碰探针状态（updateUIViewController 的异步闭包可能在 teardown
        // 之后才跑到这里）。
        guard let webView else { return }
        let nonceChanged = lastRetryNonce != nil && lastRetryNonce != retryNonce
        // 本次调用前已载过一页（hadLoadedBefore）：上一页可能走 reloadWithoutRules()
        // 清空了规则，切到新 URL 时也要把规则重装回去——只认 nonceChanged 的话，
        // 换 URL（nonce 不变）就永远不重装，第一层广告拦截永久失效。
        let hadLoadedBefore = loadedURL != nil
        guard loadedURL != url || nonceChanged else { return }
        lastRetryNonce = retryNonce
        loadedURL = url
        navigationStartAt = Date()
        // 上一页关掉广告规则后换了新 URL：规则重新开，新的一页重新评估。
        adRulesDisabled = false
        // 强制重试 / 换页时：上一页可能走 reloadWithoutRules() 清空了规则，
        // 只把 adRulesDisabled 置回 false 不够（规则已从 userContentController
        // 里摘掉），要把缓存的规则重新装回去，否则后续嵌页第一层广告拦截永久失效。
        if (nonceChanged || hadLoadedBefore), adStrip {
            webView.configuration.userContentController.removeAllContentRuleLists()
            AdBlockRuleStore.install(into: webView.configuration.userContentController, siteHost: url.host ?? "") { [weak self] in
                !(self?.adRulesDisabled ?? true)
            }
        }
        // probe 的 @Published 赋值挪到下一个 runloop：makeUIViewController
        // 触发的 viewDidLoad 会在 SwiftUI 视图更新期内同步调到这里，直接写
        // 会撞“Publishing changes from within view updates”。
        DispatchQueue.main.async { [weak self] in guard let self, self.webView != nil else { return }; self.probe.pageLoaded = false }
        // 立即加载（不等预热）。
        load(request: url)
        // 预热并行跑：只做 cookie 预种，不挡加载、不改页面。
        if let host = url.host, CloudflareWarmup.needsWarmup(host: host) {
            DispatchQueue.main.async { [weak self] in guard let self, self.webView != nil else { return }; self.probe.warmingUp = true }
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
        // 摘全屏消息 handler：userContentController 强持有 handler（即 self），
        // 不摘掉 VC → webView → configuration → userContentController → self
        // 的环不断，teardown 后 VC 永远走不到 deinit（真泄漏，见 hlsjs 同款注释）。
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "xspFullscreen")
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
    /// 嵌入重试计数（WebViewPlayerView 从 retryNonce 透传）：变了就强制重载同一 URL。
    var retryNonce: Int = 0

    func makeUIViewController(context: Context) -> EmbedWebViewController {
        EmbedWebViewController(url: url, probe: probe, adStrip: adStrip, initialRetryNonce: retryNonce)
    }

    func updateUIViewController(_ uiViewController: EmbedWebViewController, context: Context) {
        // loadIfNeeded 会同步写 probe 的 @Published（pageLoaded / warmingUp），
        // 不能在 SwiftUI 视图更新期内调（会撞“Publishing changes from within
        // view updates”）；挪到下一个 runloop 再跑。重复调也没事，
        // loadIfNeeded 的 loadedURL/nonce 去重会拦住。
        // [weak uiViewController]：用户刚进页就退出时 teardown 已跑，
        // 随后执行的闭包不能强留住已拆的 VC（loadIfNeeded 顶部的
        // guard let webView 也是第二道防线）。
        DispatchQueue.main.async { [weak uiViewController] in
            guard let uiViewController else { return }
            uiViewController.loadIfNeeded(url: url, retryNonce: retryNonce)
        }
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
    /// 页内 video 进/退全屏时调（探针的 fullscreenchange 回传 + 轮询）：
    /// 外层据此同步 DetailView.isFullscreen，全屏进出触发的 onDisappear
    /// 才不会误停播。与 onPlaying/onEmbedFailed 同款回调模式。
    var onFullscreenChange: ((Bool) -> Void)? = nil
    /// 嵌入重试计数（DetailView 从 ViewModel 传）：变了就把探针整套状态清掉重开，
    /// 同一 URL 重试也有新鲜的看门狗窗口。
    var retryNonce: Int = 0

    @StateObject private var probe = EmbedProbeState()

    var body: some View {
        ZStack {
            EmbedWebView(url: url, probe: probe, adStrip: adStrip, retryNonce: retryNonce)
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
                        isFullscreen: probe.isFullscreen,
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
        .onChange(of: probe.isFullscreen) { _, fullscreen in
            onFullscreenChange?(fullscreen)
        }
        .onDisappear {
            probe.stop()
        }
    }
}
