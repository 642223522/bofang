import Foundation

/// 单个视频（列表 / 搜索 / 分类返回的项）
struct VideoItem: Identifiable, Hashable {
    let id: String
    let title: String
    let link: String
    let coverURL: String?
    let description: String
    let category: String
}

/// ForwardWidget 模块描述（JS 里 JS_MODULES 的一项）
struct ModuleDescriptor: Identifiable {
    let id: String
    let title: String
    let description: String
    let functionName: String
    let type: String?
    let cacheDuration: Int
    /// 每个 param 是 {name, title, type, value}，type 是 input / constant / page
    let params: [[String: Any]]
}

/// 模块元数据（JS 里的 WidgetMetadata）
struct WidgetMeta {
    let id: String
    let title: String
    let description: String
    let version: String
    /// 搜索函数的函数名（一般是 searchVideos），不支持搜索的模块为 nil
    let searchFunctionName: String?
}

/// 一条播放线路（loadResource 返回的项）
struct PlayLine {
    let name: String
    let url: String
    let description: String
}

/// 已导入的源记录。清单存在 Documents/sources.json，
/// 源文件存在 Documents/Sources/<fileName>（一个模块一个 .js）。
struct SourceRecord: Identifiable, Codable {
    let id: String
    let title: String
    let fileName: String
    /// imported（外部导入）/ synced（码云同步）
    let origin: String
    var country: String
    let version: String
    let importedAt: Date
}

/// 全局网络常量
enum NetConstants {
    /// 发请求时默认带的 iPhone UA；模块自己传了 headers 时以模块的为准
    static let iPhoneUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
