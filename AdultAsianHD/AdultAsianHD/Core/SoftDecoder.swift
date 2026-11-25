import Foundation

#if canImport(KSPlayer)
import KSPlayer

/// 软解支撑代码（C 路 Wave 2）：KSPlayer（FFmpeg）选项工厂 + 后端类型配置。
///
/// 选型结论（见 SoftDecoderPlayerView.swift 文件头）：KSPlayer，SPM 接入，
/// product / module 名均为 KSPlayer，与 PlayerEngine.swift 的
/// `#if canImport(KSPlayer)` 判断一致。ijkplayer 已否决（无 SPM、FFmpeg 3.4
/// 老底子、事实上停更，还要改 codemagic.yaml 加 pod install）。
///
/// 只在 KSPlayer 接入时编译；接不进时本文件为空，hasSoftwareDecoder 保持
/// false，DetailView 的 .softDecoder 分支显示占位错误视图，构建不坏。
enum SoftDecoderSupport {

    private static var didConfigurePlayerTypes = false

    /// 后端只配一次：首选 KSMEPlayer（FFmpeg 软解），内部回退 KSAVPlayer。
    /// KSOptions.firstPlayerType / secondPlayerType 是全局静态配置（KSPlayer
    /// 官方文档的用法：`KSOptions.firstPlayerType = KSMEPlayer.self`），
    /// 本软件只在软解视图里用 KSPlayer，改动实际只影响这条路。
    /// 回退只做一次且有界：MEPlayer 打不开时 KSPlayer 内部试一次 AVPlayer
    /// （防路由误判，如实际是原生能播的封装），再失败由 finish(error:)
    /// 报给 markFailed 切线，不循环、不静默重试。
    static func configurePlayerTypes() {
        guard !didConfigurePlayerTypes else { return }
        didConfigurePlayerTypes = true
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
    }

    /// 给一条软解线路建 KSOptions。属性名均按 2.3.4 的 KSOptions.swift
    /// 逐字取用（isLoopPlay / isSeekedAutoPlay / startPlayTime /
    /// hardwareDecode / registerRemoteControll / referer / userAgent /
    /// appendHeader 都是实例成员；isAutoPlay 在 2.3.4 里只有 static，
    /// 见 makeOptions 里 KSOptions.isAutoPlay = true）。
    /// - headers：viewModel.currentHeaders（Referer + iPhone UA + 模块头 +
    ///   Cookie）。Referer / User-Agent 走 KSOptions 的专用属性（FFmpeg 的
    ///   http 层认它们）；其余头（含 Cookie）走 appendHeader 透传给 FFmpeg。
    /// - startPlayTime：同片切线时的续播点（秒）；新片/新一集为 0，从 0:00 起。
    static func makeOptions(headers: [String: String]?, startPlayTime: TimeInterval) -> KSOptions {
        configurePlayerTypes()
        let options = KSOptions()
        // 详情页点封面进来即播，不用用户再点一下（与原生 / hls.js 路一致）。
        // 2.3.4 实测：KSOptions 没有实例 isAutoPlay，只有 static
        // isAutoPlay（默认 true）；KSPlayerLayer.init 的 isAutoPlay 参数
        // 默认值就是 KSOptions.isAutoPlay，这里显式置 true 保住这道防线。
        KSOptions.isAutoPlay = true
        // 不循环：播到片尾停在 0:00，等用户再点播放（与原生一致）。
        options.isLoopPlay = false
        // seek 后不自动续播，续播由 SoftDecoderPlayerController 自己决定
        // （拖完松手、拖之前在播才续播；与原生 endScrub 语义一致）。
        options.isSeekedAutoPlay = false
        options.startPlayTime = startPlayTime
        // 硬解优先（VideoToolbox）：能硬解的编码不烧 CPU；硬解不了的
        // FFmpeg 自动落回软解。这是软解路的发热取舍：只在必须时才纯软解。
        options.hardwareDecode = true
        // 不注册系统远程控制：不进 Now Playing / 不出灵动岛（与原生播放器
        // 一致；KSOptions 默认 registerRemoteControll=true，不关会挂媒体卡）。
        // 注意拼写：官方属性名就是 registerRemoteControll（双 l）。
        options.registerRemoteControll = false
        options.userAgent = headers?["User-Agent"] ?? PlaybackEngine.iPhoneUserAgent
        if let referer = headers?["Referer"], !referer.isEmpty {
            options.referer = referer
        }
        var extraHeaders: [String: String] = [:]
        if let headers {
            for (key, value) in headers where key != "Referer" && key != "User-Agent" {
                extraHeaders[key] = value
            }
        }
        if !extraHeaders.isEmpty {
            options.appendHeader(extraHeaders)
        }
        return options
    }
}
#endif
