import Foundation
import UIKit
import WebKit

/// Cloudflare 预热（onlybokep 系嵌页专用）：干净 WKWebView 先打开目标域，
/// 让 CF 的 JS 跑完并下发 cf_clearance cookie，再同步进播放 WebView 的
/// cookie store；之后播放 WebView 加载嵌页时带上有效 clearance，直接过，
/// 不用用户再点勾选框。
/// 关键点：
/// - 预热 WebView 用 .nonPersistent() 数据 store（干净，不污染正常浏览，
///   也不让上次的 CF 状态影响这次结果）；
/// - 不自动点勾选框（headless 点击会被 CF 标记）；只检测/同步 cookie，
///   交互式挑战暖不出来时照常加载，兜底是用户在播放页手动过验证；
/// - cookie 轮询用 Task sleep，不用 Timer.scheduledTimer（后台队列上
///   建的 Timer 没有 run loop，永远不会触发）；
/// - 最多 3 次尝试；进行中的预热会话只保留最近 3 个，超了取消最旧的。
@MainActor
final class CloudflareWarmup {
    static let shared = CloudflareWarmup()

    /// 需要预热的域名（+ 子域匹配）：dood/playmogo 嵌页家族与 onlybokep。
    static let warmupHosts: [String] = [
        "playmogo.com", "doodstream.com", "dood.to", "dood.watch",
        "doodstream.co", "doodstream.io", "onlybokep.com",
    ]

    private final class WarmupSession {
        let id = UUID()
        let webView: WKWebView
        var cancelled = false
        init(webView: WKWebView) { self.webView = webView }
    }

    private var activeSessions: [WarmupSession] = []
    private let maxAttempts = 3
    private let perAttemptWait: TimeInterval = 10
    private let pollInterval: UInt64 = 500_000_000 // 0.5s

    private init() {}

    static func needsWarmup(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return warmupHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 播放 WebView 的 cookie store 里有没有有效的 cf_clearance（未过期）。
    func hasValidClearance(for host: String, in webView: WKWebView) async -> Bool {
        let cookies = await allCookies(in: webView.configuration.websiteDataStore)
        return cookies.contains { cookie in
            cookie.name == "cf_clearance"
                && domainMatches(cookie.domain, host: host)
                && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
    }

    /// 确保播放 WebView 有 cf_clearance：已有就直接完成；没有就预热
    ///（最多 3 次），暖完或暖失败都调 completion（调用方照常加载，
    /// 兜底是用户手动过验证）。container 为空时预热 WebView 不挂视图树
    ///（尽力而为）；给了就全尺寸插到最底层（在屏、不隐藏，CF 才认）。
    func ensureClearance(for host: String, webView: WKWebView?, container: UIView?, completion: @escaping () -> Void) {
        guard let webView else { completion(); return }
        guard Self.needsWarmup(host: host) else { completion(); return }
        Task { [weak self, weak webView] in
            guard let self, let webView else { completion(); return }
            if await self.hasValidClearance(for: host, in: webView) {
                completion()
                return
            }
            await self.runWarmup(host: host, playbackWebView: webView, container: container)
            completion()
        }
    }

    private func runWarmup(host: String, playbackWebView: WKWebView, container: UIView?) async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let warmView = WKWebView(frame: container?.bounds ?? .zero, configuration: config)
        warmView.customUserAgent = NetConstants.iPhoneUserAgent
        if let container {
            warmView.translatesAutoresizingMaskIntoConstraints = false
            // 插到最底层：全尺寸在屏（不隐藏、不移出视图树），但不挡播放层。
            container.insertSubview(warmView, at: 0)
            NSLayoutConstraint.activate([
                warmView.topAnchor.constraint(equalTo: container.topAnchor),
                warmView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                warmView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                warmView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        let session = WarmupSession(webView: warmView)
        track(session)
        defer {
            untrack(session.id)
            warmView.removeFromSuperview()
        }
        guard let url = URL(string: "https://\(host)/") else { return }
        for _ in 0..<maxAttempts {
            if Task.isCancelled || session.cancelled { return }
            warmView.load(URLRequest(url: url, timeoutInterval: 15))
            // 轮询等 cf_clearance 出现（Task sleep，不用 Timer）。
            let deadline = Date().addingTimeInterval(perAttemptWait)
            while Date() < deadline {
                if Task.isCancelled || session.cancelled { return }
                try? await Task.sleep(nanoseconds: pollInterval)
                if await hasValidClearance(for: host, in: warmView) {
                    await syncClearance(from: warmView, to: playbackWebView, host: host)
                    return
                }
            }
        }
    }

    /// 把预热 WebView 里的 cf_clearance 同步进播放 WebView 的 cookie store。
    /// 只同步 cf_clearance，不动别的 cookie。
    private func syncClearance(from warmView: WKWebView, to playbackWebView: WKWebView, host: String) async {
        let source = warmView.configuration.websiteDataStore
        let target = playbackWebView.configuration.websiteDataStore
        let cookies = await allCookies(in: source)
        for cookie in cookies where cookie.name == "cf_clearance" && domainMatches(cookie.domain, host: host) {
            await setCookie(cookie, in: target)
        }
    }

    // MARK: - 会话登记（只保留最近 3 个）

    private func track(_ session: WarmupSession) {
        activeSessions.append(session)
        // 超了取消最旧的（它的轮询循环看到 cancelled 就收尾、摘掉 webview）。
        // 注意是一次只清一个最旧的，不是 removeFirst(9) 那种粗暴清空。
        while activeSessions.count > 3 {
            let oldest = activeSessions.removeFirst()
            oldest.cancelled = true
            oldest.webView.stopLoading()
            oldest.webView.removeFromSuperview()
        }
    }

    private func untrack(_ id: UUID) {
        activeSessions.removeAll { $0.id == id }
    }

    // MARK: - Cookie store（completion-handler 版，不依赖 async 桥接）

    private func allCookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    private func setCookie(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { cont.resume() }
        }
    }

    /// cookie 域名（常带前导点，如 .playmogo.com）与目标 host 匹配：
    /// 相等，或 host 是它的子域。
    private func domainMatches(_ cookieDomain: String, host: String) -> Bool {
        let cd = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let h = host.lowercased()
        return h == cd || h.hasSuffix("." + cd)
    }
}
