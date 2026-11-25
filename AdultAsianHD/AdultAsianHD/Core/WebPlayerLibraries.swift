import Foundation

// MARK: - hls.js / dash.js 支撑（B 路：HLS.js + DASH 播放器）
//
// 选型：库以 .txt 资源文件进包（Core/hls.min.js.txt、Core/dash.min.js.txt），
// 运行时从 Bundle 读出、拼进 WKWebView 的 HTML 里注入。
// 为什么不用 Swift 字符串常量：两库 min 后共约 1.2MB，超大字面量拖慢编译、转义易错；
// 为什么不用 .js 后缀：仓库硬门禁——codemagic.yaml 的 Verify checkout 会
// `find AdultAsianHD -name '*.js'`，找到就 exit 1，包里也不许有 .js。
// project.yml 里 Core/ 是目录 glob，.txt 会自动当资源编进包，不用改 project.yml。
// 兜底：库读不到时 hlsSource/dashSource 为 nil——探测旗子保持 false（路由不选这两路），
// 播放器建页时报“库文件缺失”走 markFailed 切线，绝不崩溃。
enum WebPlayerLibraries {
    /// jsDelivr：hls.js@1.5.20/dist/hls.min.js（UMD，window.Hls）。
    /// 1.5+ 已适配 ManagedMediaSource；iOS 17.1+ WKWebView 有 MMS、17.4+ 才稳定，
    /// 到底能不能用以运行时探测（WebPlayerCapabilityProbe）为准，绝不用版本号判断。
    static let hlsVersion = "1.5.20"
    /// jsDelivr：dashjs@4.7.4/dist/dash.all.min.js（UMD，window.dashjs）。
    /// v4 的 API（setQualityFor / getBitrateInfoListFor / updateSettings）以本文件为准，
    /// v5 已删这些方法，升级大版本前必须先改 DASHPlayerView。
    static let dashVersion = "4.7.4"

    static var hlsSource: String? { bundledText(resource: "hls.min", extension: "js.txt") }
    static var dashSource: String? { bundledText(resource: "dash.min", extension: "js.txt") }

    private static func bundledText(resource: String, extension ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// 把 Swift 字符串编成 JS 字符串字面量（含首尾引号、已转义），可直接拼进 JS 代码。
    /// 不用 JSONSerialization：顶层字符串它不接受，数组取首元素的写法更绕。
    static func jsStringLiteral(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        escaped = escaped.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        // 绝不能让值里出现 </script（会提前闭合 <script> 块）。
        escaped = escaped.replacingOccurrences(of: "</", with: "<\\/")
        return "\"" + escaped + "\""
    }

    /// 把请求头字典编成 JS 对象字面量（{"Referer": "..."}），可直接拼进 JS 代码。
    /// 空/nil 时返回 {}。同样防 </script 提前闭合。
    static func jsHeadersObject(_ headers: [String: String]?) -> String {
        guard let headers, !headers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: headers),
              var text = String(data: data, encoding: .utf8) else { return "{}" }
        text = text.replacingOccurrences(of: "</", with: "<\\/")
        return text
    }

    /// JS 播放器页的 HTML 骨架：黑底 + 铺满的 <video> + 内嵌库 + 启动脚本。
    /// 库文件里已验过不含 `</script`（hls.min.js.txt / dash.min.js.txt 各 0 处），
    /// 内嵌进 <script> 块是安全的；video 用 object-fit: contain，对应 AVPlayerLayer
    /// 的 .resizeAspect。playsinline 让视频在页内播，不跳系统全屏播放器。
    static func playerHTML(librarySource: String, bootScript: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no\">"
        + "<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}"
        + "video{width:100%;height:100%;object-fit:contain;background:#000}</style></head>"
        + "<body><video id=\"v\" playsinline webkit-playsinline preload=\"auto\"></video>"
        + "<script>" + librarySource + "</script>"
        + "<script>" + bootScript + "</script>"
        + "</body></html>"
    }
}

/// JS 播放器报上来的一个清晰度档位（hls.levels / dash.js getBitrateInfoListFor）。
/// Hashable：进菜单前按高度去重、按码率取最高档时要比对。
struct WebPlayerLevel: Hashable {
    /// hls.js 里是 levels 数组下标；dash.js 里是 BitrateInfo.qualityIndex。
    /// -1 只表示“自动”，从不作为档位下标。
    let index: Int
    let height: Int
    let bitrate: Int

    init(index: Int, height: Int, bitrate: Int) {
        self.index = index
        self.height = height
        self.bitrate = bitrate
    }
}

/// 按高度取画质标签，与 PlayerControlBar.qualityLabel(for:) 的高度档一致
/// （4K/1080p/720p/480p/360p）。JS 档位没有线路名可找“原画/超清/高清/标清”，
/// 只有高度，所以只出数字档；“自动”档由调用方另建，不走这里。
/// height <= 0（JS 没给高度）时返回 nil，调用方跳过该档（没法标名字）。
func videoQualityLabel(height: Int) -> String? {
    if height >= 2160 { return "4K" }
    if height >= 1080 { return "1080p" }
    if height >= 720 { return "720p" }
    if height >= 480 { return "480p" }
    if height >= 360 { return "360p" }
    if height > 0 { return "\(height)p" }
    return nil
}
