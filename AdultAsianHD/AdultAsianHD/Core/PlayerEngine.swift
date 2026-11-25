import Foundation
/// 播放器引擎。路由表返回它，DetailView 按它显示对应播放器。
enum PlayerEngine: Equatable {
    case native
    case nativeIntercepted
    case hlsjs
    case dash
    case softDecoder
    case webView
}
/// 能力注册表。各引擎模块把自己的旗置 true；路由表只读它。
enum PlaybackCapabilities {
    static var hasHLSJS = false
    static var hasDASH = false
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
    "playmogo.com", "doodstream.com", "dood.watch", "doodstream.co",
    "d0o0d.com", "bysebuho.com", "lplaygo.com"
]

/// 嵌页 host 是否属于墙后家族（含子域；host 为 nil 时返回 false）。
func isWalledEmbedHost(_ host: String?) -> Bool {
    guard let host = host?.lowercased(), !host.isEmpty else { return false }
    return wallEmbedHostFamilies.contains { host == $0 || host.hasSuffix("." + $0) }
}

/// 失败分层（供自检做分层错误记录，Fix C 用；失败上报不要只报“失败”）。
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

/// 回环代理扩展点（stub，本轮不实现，不要把拦截器写成唯一手段）。
/// 决策顺序：拦截器（只拦 playlist+key）→ 回环代理 → hls.js。
/// - 拦截器触发条件：key 需头、分片不需头（探针已证实三站的分片不要头，黄果 .ts 无头也 206）。
/// - 拦截器退出条件：分片也需头（分片 403 或 AVPlayerItem 报 -12881）。
/// - 回环代理触发条件：分片也需头。
/// - 回环代理退出条件：AirPlay/后台播放不可接受（本机回环代理与 AirPlay/后台播放冲突）。
/// 实现形态（以后）：本机 HTTP 代理（127.0.0.1 随机端口），AVPlayer 经代理拉流，
/// 代理给每个子请求（播单/密钥/分片）补头；须处理代理生命周期与端口冲突。
/// TODO(回环代理)：分片需头被证实且 hls.js 回退也失败时，再实现本扩展点。
enum LoopbackProxy {
    /// 是否已实现回环代理（实现它的那路把旗置 true；路由表/回退逻辑只读它）。
    static var isAvailable = false
    /// 分片需头的信号已出现（分片 403 或 -12881，由 CustomPlayerController 的检测置位）。
    static var segmentNeedsHeaders = false
}
