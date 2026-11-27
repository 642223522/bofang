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

/// 广告 DOM 清理脚本（document-start 注入，主框架 + 子框架都跑，每帧独立实例）。
/// 两阶段：每轮先查有没有 Cloudflare 验证在跑（标题 "Just a moment"、
/// 挑战 iframe、cf- 标记，含中文标题“请稍候/正在验证/您是真人吗”），有就跳过这轮、什么都不碰；验证过了才删广告。
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
    static let source = """
    // XSPModalGuard v5 synthesis (run #21) — replaces the old AdStripScript.
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
        if (cfRunning()) return;
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
    // XSPFloatingCardGuard v10 (run #22) — appended after v5, separate IIFE, v5 untouched.
    // Gemini v10: v9 synthesis + 5 fixes (two-tier click shell, getComputedStyle-verified hide,
    // chrome-vs-container hardVeto split, shallow attributes, 180x88 geometry floor).
    (function () {
      if (window.__xspFloatingCardGuardV10) return;
      window.__xspFloatingCardGuardV10 = true;

      // Swift 注入时可替换为 UUID().uuidString；未替换时同页全 frame 仍保持一致可用
      const NONCE = '__XSP_SESSION_NONCE__';
      const CARD_ATTR = 'data-xsp-fg-v10';
      const WRAP_ATTR = 'data-xsp-fg-wrap-v10';
      const BACKDROP_ATTR = 'data-xsp-fg-bd-v10';
      const STYLE_ID = '__xsp_fg_v10_css';

      // ---------------- 受保护与硬否决规则 ----------------
      const SAFE_IFRAME_RE =
        /(challenges\\.cloudflare\\.com|hcaptcha\\.com|recaptcha\\.net|google\\.com\\/recaptcha|accounts\\.|login\\.|oauth|pay\\.|stripe\\.com|paypal\\.com)/i;

      // 核心控件栏（这些节点及其祖先不可藏，其内部子孙也不参与广告判定）
      const CONTROL_BAR_SELECTOR =
        '.vjs-control-bar, .vjs-menu, .vjs-text-track-display, .vjs-title-bar, .vjs-error-display, ' +
        '.plyr__controls, .plyr__menu, .plyr__captions, ' +
        '.jw-controls, .jw-settings-menu, .jw-captions, .jw-title, ' +
        '.dplayer-controller, .dplayer-setting-box, .dplayer-subtitle, ' +
        '.art-bottom, .art-setting, .art-subtitle, ' +
        '[role="slider"], input[type="range"], .cf-turnstile';

      // 严格限定到播放器 UI 部件，绝不包含宽泛的 #player / .video-js / .plyr 外壳
      const PLAYER_CHROME_RE =
        /(^|[\\s_-])(vjs-(control|menu|text-track|title|error|loading|big-play|poster|time|progress|volume|fullscreen|subs|caption)|plyr__(controls?|menu|captions?|poster|progress|time|volume|tooltip)|jw-(controls?|settings|captions?|title|display|icon|slider|tooltip)|dplayer-(controller|setting|subtitle|bar|icons|notice|menu)|art-(bottom|controls?|setting|subtitle|notice|loading|layer-title)|control-?bar|seek-?bar|progress-?bar|top-?bar|header-?bar|nav-?bar|cf-turnstile)/i;

      // 仅用于过滤 characterData 高频刷新（时间轴/缓冲/字幕跳字）
      const PLAYER_LIVE_UI_RE =
        /(vjs-(current-time|duration|remaining|time|progress|control|text-track)|plyr__(time|progress|captions?|tooltip)|jw-(text-elapsed|text-duration|slider|captions?|tooltip)|dplayer-(ptime|dtime|bar|subtitle)|art-(time|progress|subtitle)|time-?display|current-?time|duration|progress-?bar|seek-?bar|subtitle|caption|text-?track)/i;

      // 播放器菜单文案硬否决：明确设置词 OR >=2 个分辨率/倍速选项（避免单出现 "4K" 误放 VPN 广告）
      const MENU_EXPLICIT_RE =
        /\\b(subtitles?|captions?|playback\\s+speed|audio\\s+track|quality|picture[\\s-]in[\\s-]picture|chromecast|airplay)\\b|(清晰度|画质|倍速|字幕|音轨|切换线路|画中画|投屏)/i;
      const MENU_OPTION_TOKEN_RE = /\\b(2160p|1080p|720p|480p|360p|4k|0\\.5x|0\\.75x|1\\.0?x|1\\.25x|1\\.5x|2\\.?0?x|auto)\\b/gi;

      // 合法「下一集」卡片硬否决
      const NEXT_EPISODE_VETO_RE =
        /(下一集|下集|即将播放|自动播放下|选集|第\\s*\\d+\\s*[集话期部]|合集列表|\\bup\\s+next\\b|\\bnext\\s+episode\\b|\\bnext\\s+video\\b|\\bplay\\s+next\\b|\\bauto[\\s-]?play\\b|\\bep\\.?\\s*\\d+\\b|\\bs\\d+\\s*e\\d+\\b)/i;

      // 真实登录/支付/验证码 DOM 结构硬否决
      const AUTH_PAY_CAPTCHA_SELECTOR =
        'input[type="password"], input[type="email"], input[autocomplete*="cc-"], [data-sitekey], .cf-turnstile, .g-recaptcha, .h-captcha';

      // ---------------- 分类器 1：VPN / 翻墙 / 加速器推广卡 ----------------
      const VPN_STRONG_RE = /(vpn|翻墙|梯子|科学上网|加速神器|看片神器|翻墙看片|看片加速|回国加速|游戏加速器|加速器)/i;

      const VPN_AUX_NET_CLUSTERS = [
        /(\\d+\\s*\\+\\s*节点|全球.{0,6}节点|高速节点|专线节点|多国节点)/i,
        /(无限流量|不限流量|不限速|零日志|不限带宽)/i,
        /(支持订阅|一键订阅|订阅链接|多端同步)/i
      ];
      const VPN_AUX_OTHER_CLUSTERS = [
        /(免费试用|免费体验|限时免费|永久免费|新人免费)/i,
        /(独立\\s*app|原生\\s*app|客户端下载|官方\\s*app)/i,
        /(支持.{0,12}(安卓|苹果|ios|android|pc|mac|windows))/i
      ];

      const VPN_DOWNLOAD_CTA_RE =
        /^(立即下载体验|立即下载|下载体验|立即安装|免费下载|高速下载|极速下载|免费试用|立即体验|点击下载|马上下载|下载\\s*app|download\\s+now|install\\s+now|free\\s+download|try\\s+free)(\\s*[!！>»→])?$/i;

      // ---------------- 分类器 2：匿名 / 打码推送信卡片（View More 类） ----------------
      const ANON_PUSH_CTA_RE =
        /^(view\\s+more|learn\\s+more|see\\s+more|read\\s+more|show\\s+more|open\\s+now|visit\\s+site|view\\s+details|see\\s+details|more\\s+info|go\\s+now|查看更多|查看详情|了解详情|立即查看)(\\s*[!！>»→])?$/i;

      const CLOSE_TEXT_RE = /^([×✕✖╳xX]|关闭|close)$/i;
      const CLOSE_ATTR_RE = /(close|dismiss|cancel-?ad|btn-?x|icon-?close)/i;
      const ZERO_WIDTH_RE = /[\\u200B-\\u200D\\uFEFF\\u00AD]/g;

      const shadowRoots = new Set();
      const observedRoots = new WeakSet();
      const observedShallowEls = new WeakSet();
      const cardWatchers = new WeakMap();
      const cardReevalTimers = new WeakMap();
      const cardInlineFallback = new WeakSet();
      const cardToWrappers = new WeakMap();
      const wrapperToCards = new WeakMap();
      const frameThrottle = new WeakMap();

      let microQueued = false;
      let rafQueued = false;
      let lastFrameReportTs = 0;

      // ---------------------------------------------------------------------------
      // 1. 样式表优先隐藏规则（默认零 inline style 污染）
      // ---------------------------------------------------------------------------
      function injectStyleSheet(root) {
        try {
          if (root.getElementById && root.getElementById(STYLE_ID)) return true;
          if (root.querySelector && root.querySelector('#' + STYLE_ID)) return true;
          const s = document.createElement('style');
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
          const target = root === document ? (document.head || document.documentElement) : root;
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

      const origAttachShadow = Element.prototype.attachShadow;
      if (origAttachShadow && !origAttachShadow.__xspFgV10Hooked) {
        try {
          const wrapped = function attachShadow(init) {
            const root = origAttachShadow.call(this, init);
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
        const out = [document];
        shadowRoots.forEach(function (sr) {
          if (sr.host && sr.host.isConnected) out.push(sr);
          else shadowRoots.delete(sr);
        });
        return out;
      }

      // ---------------------------------------------------------------------------
      // 2. 无回流文本提取 & visualViewport 坐标系工具
      // ---------------------------------------------------------------------------
      function normalizeText(s) {
        return (s || '')
          .replace(ZERO_WIDTH_RE, '')
          .replace(/[！]/g, '!')
          .replace(/[：]/g, ':')
          .replace(/[＋]/g, '+')
          .replace(/\\s+/g, ' ')
          .trim();
      }

      function getCleanText(el, maxLen, skipClippedDescendants) {
        let out = '';
        const stack = [el];
        while (stack.length && out.length <= maxLen) {
          const n = stack.pop();
          if (!n) continue;
          if (n.nodeType === 3) {
            if (n.nodeValue) out += (out ? ' ' : '') + n.nodeValue;
          } else if (n.nodeType === 1) {
            const tag = n.tagName;
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') continue;
            if (skipClippedDescendants && n !== el && n.getAttribute && n.getAttribute(CARD_ATTR) === '1') continue;
            const kids = n.childNodes;
            for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
          }
        }
        return normalizeText(out);
      }

      function getViewportMetrics() {
        const vv = window.visualViewport;
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
      // 3. 统一前置 hardVeto（分类前 & hideCard 内双重执行，不误豁免容器内注入广告）
      // ---------------------------------------------------------------------------
      function matchesChromeToken(el) {
        if (!el || el.nodeType !== 1) return false;
        const tag = el.tagName;
        if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return true;
        if (el.getAttribute && el.getAttribute('role') === 'slider') return true;
        const cls = typeof el.className === 'string' ? el.className : '';
        const id = typeof el.id === 'string' ? el.id : '';
        return PLAYER_CHROME_RE.test(cls) || PLAYER_CHROME_RE.test(id);
      }

      function isInsidePlayerChrome(el) {
        let cur = el;
        for (let up = 0; up < 6 && cur && cur.nodeType === 1; up++, cur = cur.parentElement) {
          if (matchesChromeToken(cur)) return true;
        }
        return false;
      }

      function isInsidePlayerLiveUI(node) {
        let cur = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
        for (let up = 0; up < 6 && cur && cur.nodeType === 1; up++, cur = cur.parentElement) {
          const tag = cur.tagName;
          if (tag === 'VIDEO' || tag === 'AUDIO') return true;
          if (cur.getAttribute && cur.getAttribute('role') === 'slider') return true;
          const cls = typeof cur.className === 'string' ? cur.className : '';
          const id = typeof cur.id === 'string' ? cur.id : '';
          if (PLAYER_LIVE_UI_RE.test(cls) || PLAYER_LIVE_UI_RE.test(id)) return true;
        }
        return false;
      }

      function isPlayerMenuText(txt) {
        if (!txt) return false;
        if (MENU_EXPLICIT_RE.test(txt)) return true;
        const m = txt.match(MENU_OPTION_TOKEN_RE);
        return !!(m && m.length >= 2);
      }

      function buildProtectedContext(roots) {
        const ancestors = new Set();
        let hasVideo = false;
        function markUp(node) {
          let cur = node;
          while (cur) {
            if (ancestors.has(cur)) break;
            ancestors.add(cur);
            cur = cur.parentNode || cur.host || null;
          }
        }
        for (let r = 0; r < roots.length; r++) {
          const root = roots[r];
          if (!root.querySelectorAll) continue;
          const vids = root.querySelectorAll('video');
          if (vids.length > 0) hasVideo = true;
          for (let i = 0; i < vids.length; i++) markUp(vids[i]);
          const controls = root.querySelectorAll(CONTROL_BAR_SELECTOR);
          for (let i = 0; i < controls.length; i++) markUp(controls[i]);
          const iframes = root.querySelectorAll('iframe[src]');
          for (let i = 0; i < iframes.length; i++) {
            if (SAFE_IFRAME_RE.test(String(iframes[i].src || ''))) markUp(iframes[i]);
          }
        }
        return { ancestors: ancestors, hasVideo: hasVideo };
      }

      function hardVeto(el, txt, prot) {
        if (!el || el.nodeType !== 1) return true;
        const tag = el.tagName;
        if (tag === 'HTML' || tag === 'BODY' || tag === 'HEAD' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'META') return true;
        if (prot && prot.ancestors.has(el)) return true;
        if (isInsidePlayerChrome(el)) return true;
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
      // 4. 几何发现过滤（visualViewport 对齐 + 绝对像素下限，仅发现不作证明）
      // ---------------------------------------------------------------------------
      function isInFloatingLayer(el, root, prot) {
        if (root !== document) return true;
        let cur = el;
        for (let up = 0; up < 5 && cur && cur.nodeType === 1; up++) {
          if (cur === document.body || cur === document.documentElement || prot.ancestors.has(cur)) break;
          const st = getComputedStyle(cur);
          if (st.display === 'none' || st.visibility === 'hidden' || parseFloat(st.opacity) === 0) return false;
          if (st.position === 'fixed' || st.position === 'absolute') return true;
          cur = cur.parentElement;
        }
        return false;
      }

      function matchesCardGeometry(vrect, vp, isAdSubframe) {
        if (vp.w <= 0 || vp.h <= 0) return false;
        if (vrect.width < 180 || vrect.height < 88) return false;
        if (isAdSubframe) {
          return vrect.width >= vp.w * 0.52 && vrect.height >= vp.h * 0.32;
        }
        const isLandscape = vp.w > vp.h;
        const wRatio = vrect.width / vp.w;
        const hRatio = vrect.height / vp.h;
        if (isLandscape) {
          if (wRatio < 0.28 || wRatio > 1.02) return false;
          if (hRatio < 0.20 || hRatio > 0.86) return false;
        } else {
          if (wRatio < 0.52 || wRatio > 1.02) return false;
          if (hRatio < 0.15 || hRatio > 0.66) return false;
        }
        const cx = vrect.left + vrect.width / 2;
        const centered = Math.abs(cx - vp.w / 2) <= vp.w * (isLandscape ? 0.24 : 0.22);
        const topOk = vrect.top >= -vp.h * 0.08 && vrect.top <= vp.h * 0.44;
        const notBottomBar = vrect.bottom <= vp.h * (isLandscape ? 0.95 : 0.90);
        return centered && topOk && notBottomBar;
      }

      // ---------------------------------------------------------------------------
      // 5. 按钮动作节点 / 关闭 X / 两个独立分类器（零外链加分，覆盖栅格打码图）
      // ---------------------------------------------------------------------------
      function isVisibleColor(c) {
        return !!c && c !== 'rgba(0, 0, 0, 0)' && c !== 'transparent';
      }

      function isActionLikeNode(node, rect, cardRect) {
        const tag = node.tagName;
        if (tag === 'BUTTON' || tag === 'A') return true;
        if (node.getAttribute('role') === 'button') return true;
        if (node.hasAttribute('onclick') || node.hasAttribute('aria-label') || node.hasAttribute('title')) return true;
        const st = getComputedStyle(node);
        if (st.cursor === 'pointer') return true;
        const hasButtonChrome =
          isVisibleColor(st.backgroundColor) ||
          (st.backgroundImage && st.backgroundImage !== 'none') ||
          (parseFloat(st.borderTopWidth) > 0 && isVisibleColor(st.borderTopColor));
        return hasButtonChrome &&
          rect.width >= Math.max(80, cardRect.width * 0.24) &&
          rect.height >= 24 && rect.height <= 80;
      }

      function findCtaButton(card, cardRect, regex) {
        const nodes = card.querySelectorAll('a, button, [role="button"], [onclick], div, span');
        const limit = Math.min(nodes.length, 80);
        for (let i = 0; i < limit; i++) {
          const n = nodes[i];
          if (n.children && n.children.length > 2) continue;
          const t = getCleanText(n, 28, false);
          if (!t || t.length < 2 || t.length > 24) continue;
          if (!regex.test(t)) continue;
          const r = n.getBoundingClientRect();
          if (r.width < 36 || r.height < 18) continue;
          if (!isActionLikeNode(n, r, cardRect)) continue;
          const centerYRatio = (r.top + r.height / 2 - cardRect.top) / Math.max(1, cardRect.height);
          return { node: n, text: t, widthRatio: r.width / Math.max(1, cardRect.width), centerYRatio: centerYRatio };
        }
        return null;
      }

      function hasTopRightClose(card, cardRect) {
        const nodes = card.querySelectorAll('button, a, [role="button"], [onclick], svg, img, span, div, i');
        const limit = Math.min(nodes.length, 70);
        for (let i = 0; i < limit; i++) {
          const n = nodes[i];
          if (n.children && n.children.length > 3) continue;
          const r = n.getBoundingClientRect();
          if (r.width < 10 || r.height < 10 || r.width > 56 || r.height > 56) continue;
          if (r.right < cardRect.right - 64 || r.top > cardRect.top + 64) continue;
          const t = getCleanText(n, 10, false);
          if (CLOSE_TEXT_RE.test(t)) return true;
          const meta = (n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('title') || '') + ' ' + (typeof n.className === 'string' ? n.className : '') + ' ' + (n.id || '');
          if (CLOSE_ATTR_RE.test(meta)) return true;
          if (n.tagName === 'SVG' || n.tagName === 'IMG' || n.hasAttribute('onclick') || n.querySelector('svg')) return true;
          const st = getComputedStyle(n);
          if (st.cursor === 'pointer' || n.tagName === 'BUTTON' || n.getAttribute('role') === 'button') return true;
          const bc = getComputedStyle(n, '::before').content;
          const ac = getComputedStyle(n, '::after').content;
          if ((bc && bc !== 'none' && bc !== 'normal') || (ac && ac !== 'none' && ac !== 'normal')) return true;
        }
        return false;
      }

      function parseRadiusPx(radiusStr, minSide) {
        if (!radiusStr) return 0;
        const first = radiusStr.split(' ')[0];
        if (first.indexOf('%') >= 0) return (parseFloat(first) / 100) * minSide;
        return parseFloat(first) || 0;
      }

      function classifyVpnCard(card, cardRect, fullTxt, hasClose) {
        if (fullTxt.length < 6 || fullTxt.length > 520) return null;
        const cta = findCtaButton(card, cardRect, VPN_DOWNLOAD_CTA_RE);
        if (!cta) return null;
        const hasStrong = VPN_STRONG_RE.test(fullTxt);
        let netAux = 0;
        for (let i = 0; i < VPN_AUX_NET_CLUSTERS.length; i++) { if (VPN_AUX_NET_CLUSTERS[i].test(fullTxt)) netAux++; }
        let otherAux = 0;
        for (let i = 0; i < VPN_AUX_OTHER_CLUSTERS.length; i++) { if (VPN_AUX_OTHER_CLUSTERS[i].test(fullTxt)) otherAux++; }
        const totalAux = netAux + otherAux;
        const pathA = hasStrong && hasClose;
        const pathB = hasClose && (totalAux >= 3 || (totalAux >= 2 && netAux >= 1));
        const pathC = hasStrong && totalAux >= 2 && cta.widthRatio >= 0.44 && cta.centerYRatio >= 0.48;
        return (pathA || pathB || pathC) ? { kind: 'vpn-promo', confidence: 'high' } : null;
      }

      function inspectAnonCardVisuals(card, cardRect, ctaNode) {
        const nodes = card.querySelectorAll('img, svg, canvas, div, span, p, i');
        const limit = Math.min(nodes.length, 85);
        let avatarNode = null;
        let blurredOrMaskedRows = 0;
        let distinctBodyGraphic = false;
        const cardSt = getComputedStyle(card);
        if (cardSt.backgroundImage && cardSt.backgroundImage !== 'none' && cardSt.backgroundImage.indexOf('url(') >= 0) distinctBodyGraphic = true;
        for (let i = 0; i < limit; i++) {
          const n = nodes[i];
          if (n === ctaNode || (ctaNode && ctaNode.contains(n))) continue;
          const r = n.getBoundingClientRect();
          if (r.width < 24 || r.width > 108 || r.height < 24 || r.height > 108) continue;
          const ratio = r.width / r.height;
          const inLeft = r.left <= cardRect.left + cardRect.width * 0.46;
          if (!inLeft || ratio < 0.78 || ratio > 1.28) continue;
          const st = getComputedStyle(n);
          const minSide = Math.min(r.width, r.height);
          const rad = parseRadiusPx(st.borderTopLeftRadius, minSide);
          if (rad < minSide * 0.40) continue;
          const hasFill = n.tagName === 'IMG' || n.tagName === 'SVG' || n.tagName === 'CANVAS' || (st.backgroundImage && st.backgroundImage !== 'none') || isVisibleColor(st.backgroundColor);
          if (hasFill) { avatarNode = n; break; }
        }
        if (!avatarNode) return { hasAvatar: false, blurredRows: 0, hasDistinctBodyGraphic: false };
        for (let i = 0; i < limit; i++) {
          const n = nodes[i];
          if (n === avatarNode || avatarNode.contains(n)) continue;
          if (n === ctaNode || (ctaNode && ctaNode.contains(n))) continue;
          const r = n.getBoundingClientRect();
          if (r.width < 8 || r.height < 6) continue;
          const st = getComputedStyle(n);
          const tag = n.tagName;
          const hasBlur = (st.filter && st.filter.indexOf('blur(') >= 0) || (st.color === 'rgba(0, 0, 0, 0)' && st.textShadow && st.textShadow !== 'none');
          const lowOpacityRow = r.width >= 48 && r.height >= 8 && r.height <= 36 && parseFloat(st.opacity) > 0 && parseFloat(st.opacity) <= 0.55;
          const skeletonBar = (tag === 'DIV' || tag === 'SPAN' || tag === 'P') && n.children.length === 0 && r.width >= 48 && r.height >= 6 && r.height <= 24 && isVisibleColor(st.backgroundColor) && getCleanText(n, 4, false).length === 0;
          if (hasBlur || lowOpacityRow || skeletonBar) blurredOrMaskedRows++;
          if (!distinctBodyGraphic) {
            const isGraphic = tag === 'IMG' || tag === 'CANVAS' || (st.backgroundImage && st.backgroundImage !== 'none' && st.backgroundImage.indexOf('url(') >= 0);
            if (isGraphic && r.width >= 60 && r.height >= 24) distinctBodyGraphic = true;
          }
        }
        return { hasAvatar: true, blurredRows: blurredOrMaskedRows, hasDistinctBodyGraphic: distinctBodyGraphic };
      }

      function classifyAnonPushCard(card, cardRect, fullTxt, hasClose) {
        if (!hasClose) return null;
        const cta = findCtaButton(card, cardRect, ANON_PUSH_CTA_RE);
        if (!cta) return null;
        const vis = inspectAnonCardVisuals(card, cardRect, cta.node);
        if (!vis.hasAvatar) return null;
        const residualTextLen = Math.max(0, fullTxt.length - cta.text.length - 2);
        const hasDomBlurEvidence = vis.blurredRows >= 2;
        const hasGatedRasterEvidence = vis.hasDistinctBodyGraphic && residualTextLen <= 18 && cta.centerYRatio >= 0.46;
        if (!hasDomBlurEvidence && !hasGatedRasterEvidence) return null;
        return { kind: 'anon-push', confidence: 'high' };
      }

      function classifyElement(el, root, prot, vp, isAdSubframe) {
        const txt = getCleanText(el, 600, false);
        if (hardVeto(el, txt, prot)) return null;
        if (!isInFloatingLayer(el, root, prot)) return null;
        const rect = el.getBoundingClientRect();
        const vrect = toViewportRect(rect, vp);
        if (!matchesCardGeometry(vrect, vp, isAdSubframe)) return null;
        const hasClose = hasTopRightClose(el, rect);
        return classifyVpnCard(el, rect, txt, hasClose) || classifyAnonPushCard(el, rect, txt, hasClose);
      }

      // 6. 样式表优先隐藏 + 内联 !important / CSP 自动升级 + 内容变更复检解藏
      const INLINE_FALLBACK_PROPS = [
        ['clip-path', 'inset(100%)'],
        ['-webkit-clip-path', 'inset(100%)'],
        ['filter', 'opacity(0)'],
        ['pointer-events', 'none'],
        ['transition', 'none'],
        ['animation', 'none']
      ];
      function applyInlineFallback(el) {
        cardInlineFallback.add(el);
        for (let i = 0; i < INLINE_FALLBACK_PROPS.length; i++) {
          const prop = INLINE_FALLBACK_PROPS[i][0];
          const val = INLINE_FALLBACK_PROPS[i][1];
          if (el.style.getPropertyValue(prop) !== val || el.style.getPropertyPriority(prop) !== 'important') el.style.setProperty(prop, val, 'important');
        }
      }
      function clearInlineFallback(el) {
        if (!cardInlineFallback.has(el)) return;
        cardInlineFallback.delete(el);
        for (let i = 0; i < INLINE_FALLBACK_PROPS.length; i++) el.style.removeProperty(INLINE_FALLBACK_PROPS[i][0]);
      }
      function enforceHideEffect(el, attrName) {
        if (el.getAttribute(attrName) !== '1') el.setAttribute(attrName, '1');
        if (el.getAttribute('aria-hidden') !== 'true') el.setAttribute('aria-hidden', 'true');
        const st = getComputedStyle(el);
        const clip = st.clipPath || st.webkitClipPath || '';
        const clippedOk = clip.indexOf('inset(100%)') >= 0;
        const pointerOk = st.pointerEvents === 'none';
        if (!clippedOk || !pointerOk) applyInlineFallback(el);
      }
      function releaseWrappersForCard(card) {
        const wraps = cardToWrappers.get(card);
        if (!wraps) return;
        wraps.forEach(function (w) {
          const set = wrapperToCards.get(w);
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
        const obs = cardWatchers.get(card);
        if (obs) { try { obs.disconnect(); } catch (_) {} cardWatchers.delete(card); }
        const tid = cardReevalTimers.get(card);
        if (tid) { clearTimeout(tid); cardReevalTimers.delete(card); }
        card.removeAttribute(CARD_ATTR);
        if (card.getAttribute('aria-hidden') === 'true') card.removeAttribute('aria-hidden');
        clearInlineFallback(card);
        releaseWrappersForCard(card);
      }
      function scheduleCardReeval(card, root) {
        if (cardReevalTimers.has(card)) return;
        const tid = setTimeout(function () {
          cardReevalTimers.delete(card);
          if (!card.isConnected) { unhideCard(card); return; }
          const roots = getAllRoots();
          const prot = buildProtectedContext(roots);
          const vp = getViewportMetrics();
          const isAdSubframe = window !== window.top && !prot.hasVideo;
          const stillAd = classifyElement(card, root, prot, vp, isAdSubframe);
          if (!stillAd) unhideCard(card);
          else enforceHideEffect(card, CARD_ATTR);
        }, 180);
        cardReevalTimers.set(card, tid);
      }
      function disarmClickShells(card, root, prot, vp) {
        const cardRect = card.getBoundingClientRect();
        const cardArea = Math.max(1, cardRect.width * cardRect.height);
        let cur = card.parentElement;
        for (let up = 0; up < 4 && cur; up++, cur = cur.parentElement) {
          if (hardVeto(cur, '', prot)) break;
          const st = getComputedStyle(cur);
          if (st.position !== 'fixed' && st.position !== 'absolute') continue;
          const leftoverText = getCleanText(cur, 12, true);
          if (leftoverText.length > 4) break;
          const others = cur.querySelectorAll('video, iframe, button, a, input, select, textarea, img, canvas');
          let hasIndependentContent = false;
          for (let i = 0; i < others.length; i++) {
            const o = others[i];
            if (!card.contains(o) && !o.closest('[' + CARD_ATTR + '="1"]')) { hasIndependentContent = true; break; }
          }
          if (hasIndependentContent) break;
          const r = cur.getBoundingClientRect();
          const area = Math.max(1, r.width * r.height);
          const ix = Math.max(0, Math.min(r.right, cardRect.right) - Math.max(r.left, cardRect.left));
          const iy = Math.max(0, Math.min(r.bottom, cardRect.bottom) - Math.max(r.top, cardRect.top));
          const overlap = (ix * iy) / cardArea;
          const isTightShell = overlap >= 0.78 && area <= cardArea * 1.45;
          const z = parseInt(st.zIndex, 10);
          const isFullBackdrop = vp.w > 0 && vp.h > 0 && r.width >= vp.w * 0.60 && r.height >= vp.h * 0.60 && (st.position === 'fixed' || (Number.isFinite(z) && z >= 10));
          if (!isTightShell && !isFullBackdrop) continue;
          const hasDimmingVisual = isVisibleColor(st.backgroundColor) || (st.backdropFilter && st.backdropFilter !== 'none') || (st.webkitBackdropFilter && st.webkitBackdropFilter !== 'none');
          if (hasDimmingVisual) enforceHideEffect(cur, BACKDROP_ATTR);
          else {
            if (cur.getAttribute(WRAP_ATTR) !== '1') cur.setAttribute(WRAP_ATTR, '1');
            if (getComputedStyle(cur).pointerEvents !== 'none') { cur.style.setProperty('pointer-events', 'none', 'important'); cardInlineFallback.add(cur); }
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
        const txt = getCleanText(card, 600, false);
        if (hardVeto(card, txt, prot)) return false;
        injectStyleSheet(root);
        enforceHideEffect(card, CARD_ATTR);
        disarmClickShells(card, root, prot, vp);
        if (!cardWatchers.has(card) && typeof MutationObserver !== 'undefined') {
          try {
            const obs = new MutationObserver(function (mutations) {
              let attrChanged = false;
              let contentChanged = false;
              for (let i = 0; i < mutations.length; i++) { const t = mutations[i].type; if (t === 'attributes') attrChanged = true; else contentChanged = true; }
              if (attrChanged) enforceHideEffect(card, CARD_ATTR);
              if (contentChanged) scheduleCardReeval(card, root);
            });
            obs.observe(card, { attributes: true, attributeFilter: ['style', 'class', 'hidden', 'aria-hidden', CARD_ATTR], childList: true, characterData: true, subtree: true });
            cardWatchers.set(card, obs);
          } catch (_) {}
        }
        return true;
      }

      // 7. 跨域 iframe 安全汇报与父级裁切（支持多层嵌套中继 + 保护主播放器 iframe）
      function reportAdCardToParent(hasVideo, matchInfo) {
        if (window === window.top || hasVideo) return;
        const now = Date.now();
        if (now - lastFrameReportTs < 250) return;
        lastFrameReportTs = now;
        try {
          window.parent.postMessage({ type: 'XSP_FLOATING_CARD_GUARD', version: 10, action: 'clip-ad-card-frame', kind: matchInfo.kind, confidence: matchInfo.confidence, nonce: NONCE }, '*');
        } catch (_) {}
      }
      window.addEventListener('message', function (ev) {
        const d = ev.data;
        if (!d || d.type !== 'XSP_FLOATING_CARD_GUARD' || d.version !== 10 || d.action !== 'clip-ad-card-frame' || d.confidence !== 'high' || d.nonce !== NONCE) return;
        ev.stopImmediatePropagation();
        const roots = getAllRoots();
        const prot = buildProtectedContext(roots);
        const vp = getViewportMetrics();
        let clippedAny = false;
        for (let r = 0; r < roots.length; r++) {
          const root = roots[r];
          const iframes = root.querySelectorAll ? root.querySelectorAll('iframe') : [];
          for (let i = 0; i < iframes.length; i++) {
            const frame = iframes[i];
            try {
              if (frame.contentWindow !== ev.source) continue;
              const now = Date.now();
              if (now - (frameThrottle.get(frame) || 0) < 250) continue;
              frameThrottle.set(frame, now);
              if (hardVeto(frame, '', prot)) continue;
              let allowClip = prot.hasVideo;
              if (!allowClip) {
                const st = getComputedStyle(frame);
                const rRect = frame.getBoundingClientRect();
                const isFloating = st.position === 'fixed' || st.position === 'absolute';
                const smallerThanFullPage = vp.w > 0 && vp.h > 0 && (rRect.width < vp.w * 0.90 || rRect.height < vp.h * 0.85);
                allowClip = isFloating || smallerThanFullPage;
              }
              if (allowClip) { injectStyleSheet(root); enforceHideEffect(frame, CARD_ATTR); disarmClickShells(frame, root, prot, vp); clippedAny = true; }
            } catch (_) {}
          }
        }
        if (!prot.hasVideo && window !== window.top && clippedAny) reportAdCardToParent(false, { kind: d.kind, confidence: 'high' });
      }, true);

      // 8. 候选收集 -> 面积从小到大分类 -> 批量写入
      function collectCandidates(root, prot) {
        const seen = new Set();
        const out = [];
        function push(el) {
          if (!el || el.nodeType !== 1 || seen.has(el)) return;
          if (el.getAttribute(CARD_ATTR) === '1' || prot.ancestors.has(el)) return;
          const tag = el.tagName;
          if (tag === 'HEAD' || tag === 'BODY' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'META') return;
          if (el.shadowRoot && !shadowRoots.has(el.shadowRoot)) registerShadowRoot(el.shadowRoot);
          seen.add(el);
          out.push(el);
        }
        const topContainers = [];
        if (root === document) {
          if (document.documentElement) topContainers.push(document.documentElement);
          if (document.body) topContainers.push(document.body);
        } else topContainers.push(root);
        for (let c = 0; c < topContainers.length; c++) {
          const kids1 = topContainers[c].children;
          if (!kids1) continue;
          for (let i = 0; i < kids1.length; i++) {
            const k1 = kids1[i];
            if (!prot.ancestors.has(k1)) observeShallowElement(k1);
            push(k1);
            const kids2 = k1.children;
            if (kids2 && kids2.length <= 16) {
              for (let j = 0; j < kids2.length; j++) {
                const k2 = kids2[j];
                if (!prot.ancestors.has(k2)) observeShallowElement(k2);
                push(k2);
                const kids3 = k2.children;
                if (kids3 && kids3.length <= 10) { for (let m = 0; m < kids3.length; m++) push(kids3[m]); }
              }
            }
          }
        }
        if (root.querySelectorAll) {
          const nodes = root.querySelectorAll('a, button, [role="button"], [onclick], div, span');
          for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i];
            if (n.children && n.children.length > 2) continue;
            if (prot.ancestors.has(n)) continue;
            const t = getCleanText(n, 26, true);
            if (!t || t.length < 2 || t.length > 24) continue;
            if (!VPN_DOWNLOAD_CTA_RE.test(t) && !ANON_PUSH_CTA_RE.test(t)) continue;
            let cur = n.parentElement;
            for (let up = 0; up < 5 && cur && cur !== document.body && cur !== document.documentElement; up++) {
              if (prot.ancestors.has(cur)) break;
              push(cur);
              cur = cur.parentElement;
            }
          }
        }
        return out;
      }
      function scanOnce() {
        microQueued = false;
        rafQueued = false;
        if (document.hidden) return;
        try {
          injectStyleSheet(document);
          const roots = getAllRoots();
          const prot = buildProtectedContext(roots);
          const vp = getViewportMetrics();
          const isAdSubframe = window !== window.top && !prot.hasVideo;
          const matched = [];
          for (let r = 0; r < roots.length; r++) {
            const root = roots[r];
            const raw = collectCandidates(root, prot);
            const geoPassed = [];
            for (let i = 0; i < raw.length; i++) {
              const el = raw[i];
              if (isInsidePlayerChrome(el)) continue;
              if (!isInFloatingLayer(el, root, prot)) continue;
              const rect = el.getBoundingClientRect();
              const vrect = toViewportRect(rect, vp);
              if (!matchesCardGeometry(vrect, vp, isAdSubframe)) continue;
              geoPassed.push({ el: el, rect: rect, area: rect.width * rect.height });
            }
            geoPassed.sort(function (a, b) { return a.area - b.area; });
            const confirmedInRoot = [];
            for (let i = 0; i < geoPassed.length; i++) {
              const item = geoPassed[i];
              const el = item.el;
              let wrapsConfirmed = false;
              for (let c = 0; c < confirmedInRoot.length; c++) { if (el.contains(confirmedInRoot[c])) { wrapsConfirmed = true; break; } }
              if (wrapsConfirmed) continue;
              const txt = getCleanText(el, 600, false);
              if (hardVeto(el, txt, prot)) continue;
              const hasClose = hasTopRightClose(el, item.rect);
              const hit = classifyVpnCard(el, item.rect, txt, hasClose) || classifyAnonPushCard(el, item.rect, txt, hasClose);
              if (hit) { confirmedInRoot.push(el); matched.push({ el: el, root: root, hit: hit }); }
            }
          }
          let firstHit = null;
          for (let m = 0; m < matched.length; m++) {
            const entry = matched[m];
            if (hideCard(entry.el, entry.root, prot, vp) && !firstHit) firstHit = entry.hit;
          }
          if (firstHit) reportAdCardToParent(prot.hasVideo, firstHit);
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

      // 9. 三层低开销监听：childList(微任务) + 过滤控件的 characterData(rAF) + 浅层 attributes(微任务)
      function observeShallowElement(el) {
        if (!el || el.nodeType !== 1 || observedShallowEls.has(el)) return;
        const tag = el.tagName;
        if (tag === 'HEAD' || tag === 'BODY' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK') return;
        if (matchesChromeToken(el)) return;
        observedShallowEls.add(el);
        try {
          const obs = new MutationObserver(function () {
            if (el.getAttribute(CARD_ATTR) !== '1' && el.getAttribute(WRAP_ATTR) !== '1' && el.getAttribute(BACKDROP_ATTR) !== '1') scheduleMicroScan();
          });
          obs.observe(el, { attributes: true, attributeFilter: ['style', 'class', 'hidden'] });
        } catch (_) {}
      }
      function observeRoot(root) {
        if (!root || observedRoots.has(root) || typeof MutationObserver === 'undefined') return;
        const target = root === document ? document.documentElement : root;
        if (!target) return;
        observedRoots.add(root);
        try {
          const mo = new MutationObserver(function (mutations) {
            let needMicro = false;
            let needRaf = false;
            for (let i = 0; i < mutations.length; i++) {
              const m = mutations[i];
              if (m.type === 'childList') {
                const added = m.addedNodes;
                if (!added || added.length === 0) continue;
                for (let j = 0; j < added.length; j++) { const n = added[j]; if (n.nodeType === 1 && !isInsidePlayerLiveUI(n)) { needMicro = true; break; } }
              } else if (m.type === 'characterData') {
                if (!isInsidePlayerLiveUI(m.target)) needRaf = true;
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
      if (window.visualViewport) window.visualViewport.addEventListener('resize', scheduleRafScan);
      document.addEventListener('visibilitychange', function () { if (!document.hidden) scheduleRafScan(); });
      setInterval(function () { if (!document.hidden) scanOnce(); }, 1200);
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
