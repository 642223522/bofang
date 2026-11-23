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

/// 分类识别规则：模块输出里分类项和视频项的 type 都是 "detail"，
/// 宿主侧用下面四条信号打分识别分类项（Gemini / Claude / 豆包三家共识）。
/// 每模块可配：按模块 id（WidgetMeta.id）在 CategoryDetectionRules 里登记，
/// 没登记的用默认规则；pornjav 用默认。
struct CategoryDetectionRule {
    /// id 里的分类标记，如 "cat-"（命中 "pornjav-cat-33" 这类 id）
    let idMarker: String
    /// _cat / category 字段里的分类标记，如 "分类"
    let categoryMarker: String
    /// 链接里的路径标记，如 "/category/"
    let linkPathMarker: String
    /// 无封面图是否算一条信号
    let countsMissingCover: Bool
    /// 达到几分算分类项
    let threshold: Int

    static let `default` = CategoryDetectionRule(
        idMarker: "cat-",
        categoryMarker: "分类",
        linkPathMarker: "/category/",
        countsMissingCover: true,
        threshold: 3
    )
}

/// 每模块的分类识别规则登记表（key 是 WidgetMeta.id）。
/// 没登记的模块走默认规则；pornjav 目前用默认，不用登记。
/// 以后有模块的分类信号不一样，在这里加一行即可，不用改识别逻辑。
enum CategoryDetectionRules {
    static let perModule: [String: CategoryDetectionRule] = [:]

    static func rule(forModuleId moduleId: String) -> CategoryDetectionRule {
        perModule[moduleId] ?? .default
    }
}

extension VideoItem {
    /// 分类识别打分（0–4）：id 含 cat- 标记、_cat 是"分类"、链接含 /category/、无封面。
    func categoryScore(under rule: CategoryDetectionRule) -> Int {
        var score = 0
        if id.hasPrefix(rule.idMarker) || id.contains("-" + rule.idMarker) { score += 1 }
        if category == rule.categoryMarker { score += 1 }
        if link.contains(rule.linkPathMarker) { score += 1 }
        let hasCover = !(coverURL ?? "").isEmpty
        if rule.countsMissingCover && !hasCover { score += 1 }
        return score
    }

    /// 打分达到阈值即分类项（跳转桩），否则是视频。
    func isCategory(under rule: CategoryDetectionRule) -> Bool {
        categoryScore(under: rule) >= rule.threshold
    }

    /// 从 id 里取分类数字编号，如 "pornjav-cat-33" → "33"；纯数字 id 直接返回。
    var categoryNumericId: String? { Self.numericId(from: id) }

    /// 同上，作用于任意原始 id 字符串。
    static func numericId(from rawId: String) -> String? {
        if !rawId.isEmpty && rawId.allSatisfy({ $0.isNumber }) { return rawId }
        guard let range = rawId.range(of: "cat-") else { return nil }
        let digits = rawId[range.upperBound...].prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : String(digits)
    }

    /// 链接的 host（分类取列表时用来做同源校验与 WP REST 域名）。
    var siteHost: String? {
        URL(string: link)?.host
    }

    /// 分类链接的最后一个路径段，如 ".../category/amateur/" → "amateur"；
    /// 直调 WP REST 拿不到数字编号时用它查 slug。
    var categorySlug: String? {
        guard let url = URL(string: link) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.last
    }

    /// 分类标题常带 "（123）" 这样的帖子数后缀，取列表时用去掉后缀的名字。
    var categoryNameWithoutCount: String {
        guard title.hasSuffix("）"),
              let open = title.lastIndex(of: "（") else { return title }
        let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
        guard !inner.isEmpty, inner.allSatisfy({ $0.isNumber }) else { return title }
        return String(title[..<open])
    }
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
    /// 作者（WidgetMetadata.author），没有为 nil
    let author: String?
    /// 站点地址（WidgetMetadata.site / siteUrl / homepage，哪个有取哪个），没有为 nil
    let site: String?
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
