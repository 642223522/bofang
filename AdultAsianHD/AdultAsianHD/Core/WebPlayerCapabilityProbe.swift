import Foundation
import WebKit

// MARK: - hls.js / dash.js 运行时能力探测（B 路）
//
// App 启动时在隐藏 WKWebView 里跑一次，探完立即释放 WebView。
// 探什么（运行时实测，绝不用 iOS 版本号判断——Gemini 已验证的结论）：
//   1. window.ManagedMediaSource 是否存在（iOS 17.1+ 才有，17.4+ 才稳定）；
//   2. 库注入后 Hls.isSupported()（hls.js 自己判 MMS 可不可用）；
//   3. dashjs.supportsMediaSource()（dash.js 自己判 MSE 可不可用）。
// 只有探到可用，才把 PlaybackCapabilities.hasHLSJS / hasDASH 置 true；
// 探之前两个旗子都是 false，路由表不会选这两路。
// 探测异步、不阻塞启动（App 的 onAppear 里调 start() 就走，不等结果）。
//
// 边界（写清楚，不静默吞）：
// - Lockdown Mode：会禁用 JIT/MSE，Hls.isSupported() 会报 false → 旗子保持 false，
//   路由走原生/拦截器，不会在此硬闯。
// - 非 HTTPS / 非安全上下文：MSE 要求安全上下文；探测页 baseURL 用 https://localhost/，
//   isSecureContext 为 true 时的探测结果才有效。播放页 baseURL 是流地址本身（https），
//   同样是安全上下文；若某天流地址是 http，hls.js 仍可能不可用，届时以 ERROR 事件为准。
// - WebContent 进程内存配额约 300–500MB：探测的隐藏 WebView 探完就释放，不常驻；
//   播放器 WebView 也是播完即拆（onDisappear/dismantle 调 teardown），不留后台进程。
// - Hls.isSupported() 为 false 时 hls.js 不报错、要求业务主动回落到原生 HLS：
//   本探测就是这道关——false 就不置旗；播放器里若仍遇到不支持，也报 error 走
//   markFailed 切线，绝不在 HLSJSPlayerView 里偷偷 video.src = url 顶替原生。
// - 探测失败（库缺失、WebContent 进程崩了、JS 报错）一律保持 false，不重试、不报错，
//   只是这两路不可用；DEBUG 下打印一行原因。
enum WebPlayerCapabilityProbe {

    private static var probeWebView: WKWebView?
    private static var probeDelegate: ProbeDelegate?
    /// 只探一次：App 的 onAppear 可能多次触发，重复探测只是浪费一个 WebContent 进程。
    private static var didStart = false

    /// App 启动时调一次（AdultAsianHDApp.onAppear）。重复调无害（已有探测在跑就直接返回）。
    @MainActor
    static func start() {
        guard !didStart, probeWebView == nil else { return }
        didStart = true
        guard let hls = WebPlayerLibraries.hlsSource,
              let dash = WebPlayerLibraries.dashSource else {
            #if DEBUG
            print("[WebPlayerProbe] 库文件缺失（hls.min.js.txt / dash.min.js.txt 不在包里），hls.js/dash.js 不可用")
            #endif
            return
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        let delegate = ProbeDelegate()
        webView.navigationDelegate = delegate
        probeWebView = webView
        probeDelegate = delegate
        // 隐藏 WebView 不进视图层级也能跑 JS；baseURL 用 https，保证安全上下文。
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>"
            + "<script>" + hls + "</script>"
            + "<script>" + dash + "</script>"
            + "</body></html>"
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
    }

    /// 页载完后探（delegate 调）。探完无论结果都释放隐藏 WebView。
    @MainActor
    fileprivate static func finishProbing(_ webView: WKWebView) {
        webView.evaluateJavaScript(
            """
            (function(){
              var mms = (typeof window.ManagedMediaSource !== 'undefined');
              var hls = false;
              try { hls = (typeof Hls !== 'undefined') && Hls.isSupported(); } catch(e){}
              var dash = false;
              try {
                if (typeof dashjs !== 'undefined' && dashjs) {
                  if (typeof dashjs.supportsMediaSource === 'function') { dash = !!dashjs.supportsMediaSource(); }
                  else { dash = !!dashjs.supportsMediaSource; }
                }
              } catch(e){}
              return JSON.stringify({mms: mms, hls: hls, dash: dash, secure: !!window.isSecureContext});
            })();
            """
        ) { result, error in
            // 释放探测用的隐藏 WebView（WebContent 进程随之回收，不常驻占内存）。
            probeWebView = nil
            probeDelegate = nil
            guard error == nil,
                  let str = result as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                #if DEBUG
                print("[WebPlayerProbe] 探测失败：\(error?.localizedDescription ?? "结果解析失败")")
                #endif
                return
            }
            // 只置 true，不置 false：旗子初始就是 false，探不到就是不可用。
            if (json["hls"] as? Bool) == true { PlaybackCapabilities.hasHLSJS = true }
            if (json["dash"] as? Bool) == true { PlaybackCapabilities.hasDASH = true }
            #if DEBUG
            print("[WebPlayerProbe] mms=\(json["mms"] ?? "?") hls=\(json["hls"] ?? "?") dash=\(json["dash"] ?? "?") secure=\(json["secure"] ?? "?")")
            #endif
        }
    }

    /// 探测页载入失败时调：释放 WebView，旗子保持 false。
    @MainActor
    fileprivate static func probingFailed() {
        probeWebView = nil
        probeDelegate = nil
    }

    /// 只做导航回调转交；WKWebView 的 navigationDelegate 是弱引用，
    /// 实例由 WebPlayerCapabilityProbe.probeDelegate 强持有，探完释放。
    private final class ProbeDelegate: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in WebPlayerCapabilityProbe.finishProbing(webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in WebPlayerCapabilityProbe.probingFailed() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in WebPlayerCapabilityProbe.probingFailed() }
        }
    }
}
