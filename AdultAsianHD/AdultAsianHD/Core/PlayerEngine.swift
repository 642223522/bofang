import Foundation
/// 播放器引擎。路由表返回它，DetailView 按它显示对应播放器。
enum PlayerEngine: Equatable {
    case native
    case nativeIntercepted
    case proxy
    case hlsjs
    case dash
    case softDecoder
    case webView

    var displayName: String {
        switch self {
        case .native: return "原生"
        case .nativeIntercepted: return "拦截器"
        case .proxy: return "回环代理"
        case .hlsjs: return "HLS.js"
        case .dash: return "dash.js"
        case .softDecoder: return "软解"
        case .webView: return "嵌页"
        }
    }
}
/// 能力注册表。各引擎模块把自己的旗置 true；路由表只读它。
/// 可变 static var 一律走同一把 NSLock（P1-1）：hasLoopbackProxy 在
/// LoopbackProxyServer.onListenerReady（listenerQueue 后台队列）写，
/// 其余在 @MainActor 读写，无锁就是真实跨线程数据竞争 + Swift 6 并发报错。
/// 调用方签名不变（仍是 PlaybackCapabilities.hasHLSJS 这类 Bool 读写）。
enum PlaybackCapabilities {
    private static let lock = NSLock()
    private static var _hasHLSJS = false
    private static var _hasDASH = false
    private static var _hasLoopbackProxy = false
    private static var _loopbackProxyBindFailed = false

    static var hasHLSJS: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasHLSJS }
        set { lock.lock(); defer { lock.unlock() }; _hasHLSJS = newValue }
    }
    static var hasDASH: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasDASH }
        set { lock.lock(); defer { lock.unlock() }; _hasDASH = newValue }
    }
    /// 回环代理：第一次成功起监听后置 true（能力已证实，见 LoopbackProxyServer）。
    static var hasLoopbackProxy: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasLoopbackProxy }
        set { lock.lock(); defer { lock.unlock() }; _hasLoopbackProxy = newValue }
    }
    /// 回环代理起监听失败过（sticky）：起不来就不再试 P，直接走 J/下一条线。
    static var loopbackProxyBindFailed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _loopbackProxyBindFailed }
        set { lock.lock(); defer { lock.unlock() }; _loopbackProxyBindFailed = newValue }
    }
    #if canImport(KSPlayer)
    static let hasSoftwareDecoder = true
    #else
    static let hasSoftwareDecoder = false
    #endif
}

/// 墙后嵌页家族域名（playmogo/dood 系）：URLSession 解流过不了 CF 挑战，
/// 这类嵌页 host 跳过解流、直接进页内 WebViewPlayer（Fix B wall-first）。
/// WebViewPlayer 的导航白名单与 Playback 的 wall-first 共用这一张表，改一处即可。
let wallEmbedHostFamilies = [
    "playmogo.com", "doodstream.com", "dood.to", "dood.watch", "doodstream.co",
    "doodstream.io", "d0o0d.com", "bysebuho.com", "lplaygo.com"
]

/// 嵌页 host 是否属于墙后家族（含子域；host 为 nil 时返回 false）。
func isWalledEmbedHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else { return false }
    return wallEmbedHostFamilies.contains { host == $0 || host.hasSuffix("." + $0) }
}

/// 失败分层（供账本做分层错误记录；失败上报不要只报“失败”）。
/// 分层铁证：VPN 不改头、不改 cookie——VPN 下可播，则缺头/缺 cookie 不可能是首要根因；
/// VPN 下仍不可播，才是头/cookie/解析问题；明文流（pornjav）在 B 上也要代理，
/// 几乎一定在网络层，与 playerHint 无关。
/// 2×2：列表正常＋媒体失败＝媒体层问题；列表失败＋媒体直链正常＝列表/API 层问题；
/// 两者都失败＝更可能是网络/出口问题；两者都正常＝播放器集成问题。
enum PlaybackFailureStage: String {
    /// 播单拉取失败（非 2xx / 非 M3U8 体）：预检第一关。
    case playlistFetch
    /// 密钥请求失败（403/401，重拉播单+重铸后仍失败）。
    case keyFetch
    /// 首分片/分片失败（含 -12881：分片需头信号，拦截器覆盖不了）。
    case segmentFetch
    /// 播单/key/分片都通，播放器本身失败。
    case playback
}

/// 回环代理（LoopbackProxy，梯子 D → P → J 里的一级）：实现在
/// LoopbackProxy.swift。能力旗在 PlaybackCapabilities 里：
/// hasLoopbackProxy（第一次成功起监听后 true）、loopbackProxyBindFailed
///（起监听失败过，sticky，失败了就不再试 P）。
/// 触发条件：D 失败且分片需头（.segmentFetch / -12881）或拦截被绕过；
/// 退出条件：AirPlay/后台播放不可接受（本机回环代理与 AirPlay/后台播放冲突）。
