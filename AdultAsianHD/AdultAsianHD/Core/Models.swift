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
    /// 该模块是否需要 WebView 才能跑（Rex 格式字段，如 huangguo.js 全是 false）。
    /// true 的模块走嵌入播放：先混合解流（解出直链→AVPlayer），解不出再页内 WebView 播。
    /// 注意：声明处不给默认值（默认值在下方显式 init 的参数里）——
    /// 声明处给了 `= false` 又在 init 里赋值，Swift 会报 "immutable value may only be initialized once"（构建 #41 就是这么死的）。
    let requiresWebView: Bool
    /// 每个 param 是 {name, title, type, value}，type 是 input / constant / page
    let params: [[String: Any]]

    /// 显式 init（不依赖编译器合成的 memberwise init）：
    /// 构建 #38/#39 在 Xcode 27.2 上报 "extra argument 'requiresWebView' in call"，
    /// 而 Models.swift 明明有该字段、构建机签出与缓存都已核实无误；
    /// 显式写出 init 后调用点不再依赖合成行为。
    init(id: String, title: String, description: String, functionName: String, type: String?, cacheDuration: Int, requiresWebView: Bool = false, params: [[String: Any]]) {
        self.id = id
        self.title = title
        self.description = description
        self.functionName = functionName
        self.type = type
        self.cacheDuration = cacheDuration
        self.requiresWebView = requiresWebView
        self.params = params
    }
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

/// 一条播放线路（loadResource 返回的项）。
/// Hashable：PlayerControlBar 的 QualityOption（Identifiable, Hashable）里存了一条 PlayLine，
/// PlayLine 不实现 Hashable 时编译器无法自动合成 QualityOption 的 Hashable/Equatable
/// （构建 #46 就是这么死的）。字段全是 String / String?，可自动合成；
/// 显式 init 不动，协议一致性合成不依赖 memberwise init。
struct PlayLine: Hashable {
    let name: String
    let url: String
    let description: String
    /// 播放器提示（如 "hlsjs"，AES-128 HLS；AVPlayer 原生支持 AES-128 HLS，照常播，hint 只存不用）
    /// 注意：声明处不给默认值（默认值在下方显式 init 的参数里）——
    /// 声明处给了 `= nil` 又在 init 里赋值，Swift 会报 "immutable value may only be initialized once"（构建 #41 就是这么死的）。
    let playerHint: String?
    /// 播这条线时 AVPlayer 要带的 Referer（解流得到的直链用，如 dood/playmogo 嵌入解出的 HLS，
    /// CDN 要 Referer=嵌入页；直链模块没这个字段时为 nil，走原有 headers 逻辑）。
    let referer: String?
    /// 朋友桥的线路标记：这条线要求剥广告（onlybokep.js 的 loadDetail 会把
    /// loadResource 线路上的 adStrip 原样透传到 childItems；朋友的宿主认这个标记，
    /// 我们以前没接——解析时直接丢了）。嵌入页播放器恒开广告剥离，
    /// 这个标记记下来供以后按线精细控制。
    let adStrip: Bool
    /// 模块给的自定义请求头（拦截器给播单/密钥子请求加头用；分片是 AVPlayer 直接拉的，
    /// 拦截器管不到；朋友三模块现在不给，超集规则要求“模块给了就不能丢”）。nil = 模块没给。
    /// 注意：声明处不给默认值（默认值在下方显式 init 的参数里）——
    /// 声明处给了 `= nil` 又在 init 里赋值，Swift 会报 "immutable value may only be initialized once"（构建 #41 就是这么死的）。
    let headers: [String: String]?
    /// 模块给的 Cookie（拦截器给子请求带 Cookie 头用；朋友三模块现在不给）。
    /// 与 headers 同款原因：声明处不给默认值。
    let cookie: String?

    /// 显式 init（不依赖编译器合成的 memberwise init）：

    /// 显式 init（不依赖编译器合成的 memberwise init）：
    /// 构建 #38/#39 在 Xcode 27.2 上报 "extra argument 'playerHint' in call"，
    /// 而 Models.swift 明明有该字段、构建机签出与缓存都已核实无误；
    /// 显式写出 init 后调用点不再依赖合成行为。
    init(name: String, url: String, description: String, playerHint: String? = nil, referer: String? = nil, adStrip: Bool = false, headers: [String: String]? = nil, cookie: String? = nil) {
        self.name = name
        self.url = url
        self.description = description
        self.playerHint = playerHint
        self.referer = referer
        self.adStrip = adStrip
        self.headers = headers
        self.cookie = cookie
    }
}

/// 详情（loadDetail 返回）：含分集 childItems（短剧站，如 huangguo.js）。
/// relatedItems：朋友桥的 loadDetail 给分类返回的相关视频（onlybokep.js 的
/// loadDetail 对分类链接返回 relatedItems）；我们以前解析时直接丢了，
/// 现在接住，详情页下方显示“相关”区。
struct DetailItem {
    let id: String
    let title: String
    let link: String
    let coverURL: String?
    let description: String
    /// 详情自带的直链（首集预铸的 URL，没有为空）
    let videoURL: String?
    let episodes: [DetailEpisode]
    /// 相关视频（loadDetail 的 relatedItems，没有为空数组）
    let relatedItems: [VideoItem]

    /// 显式 init（PlayLine/ModuleDescriptor 同款原因：不依赖编译器合成的
    /// memberwise init，Xcode 27.2 上合成行为不可靠）。
    init(id: String, title: String, link: String, coverURL: String?, description: String, videoURL: String?, episodes: [DetailEpisode], relatedItems: [VideoItem] = []) {
        self.id = id
        self.title = title
        self.link = link
        self.coverURL = coverURL
        self.description = description
        self.videoURL = videoURL
        self.episodes = episodes
        self.relatedItems = relatedItems
    }
}

/// 一集（loadDetail 的 childItems 一项）：type "url"。
struct DetailEpisode: Identifiable, Hashable {
    let id: String
    let title: String
    /// 该集的播放链接（huangguo://video/<id>/ep/<n> 这类自定义 scheme；点开时交给 loadResource 现铸）
    let link: String
    /// 预铸的直链（首集有，其余集为空，点开时现铸）
    let videoURL: String?
    let description: String
    /// 播放器提示（如 "hlsjs"，只存不用）
    let playerHint: String?
    /// 该集播出时要带的 Referer（分集透传用；D 路 playEpisode 重建 PlayLine 时传上）。
    let referer: String?
    /// 朋友桥标记：这集要求剥广告（同 PlayLine.adStrip，透传用）。
    let adStrip: Bool
    /// 模块给的自定义请求头（同 PlayLine.headers，拦截器用；分集透传用）。
    let headers: [String: String]?
    /// 模块给的 Cookie（同 PlayLine.cookie，拦截器用；分集透传用）。
    let cookie: String?

    /// 显式 init（PlayLine 同款原因）。
    /// 参数顺序必须与 WidgetHost.parseDetailItem 的调用点一致：
    /// id, title, link, videoURL, description, playerHint, referer, adStrip, headers, cookie。
    init(id: String, title: String, link: String, videoURL: String?, description: String, playerHint: String? = nil, referer: String? = nil, adStrip: Bool = false, headers: [String: String]? = nil, cookie: String? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.videoURL = videoURL
        self.description = description
        self.playerHint = playerHint
        self.referer = referer
        self.adStrip = adStrip
        self.headers = headers
        self.cookie = cookie
    }
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

    /// 默认浏览器请求头（大小写不敏感合并，模块显式传的字段永远优先）
    static let defaultBrowserHeaders: [String: String] = [
        "User-Agent": iPhoneUserAgent,
        "Accept": "application/json, text/plain, text/html, */*;q=0.8",
        "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8"
    ]

    /// 大小写不敏感合并请求头：overrides 中若含 "user-agent" 会替换 base 中的 "User-Agent"，
    /// 不会出现两个大小写不同的同名键导致字典遍历顺序随机覆盖。
    static func mergeHeaders(base: [String: String], overrides: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        var canonicalKeyByLower: [String: String] = [:]
        for (key, value) in base {
            let lower = key.lowercased()
            canonicalKeyByLower[lower] = key
            result[key] = value
        }
        for (key, value) in overrides {
            let lower = key.lowercased()
            if let existing = canonicalKeyByLower[lower], existing != key {
                result.removeValue(forKey: existing)
            }
            canonicalKeyByLower[lower] = key
            result[key] = value
        }
        return result
    }

    /// 同源判定（scheme + host + 端口）：重定向时只有同源才保留凭据头。
    /// 端口：显式端口为准，缺省按 scheme 的默认端口（https 443 / http 80）算。
    static func isSameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b,
              let aHost = a.host?.lowercased(), let bHost = b.host?.lowercased(),
              aHost == bHost,
              (a.scheme?.lowercased() ?? "") == (b.scheme?.lowercased() ?? "") else { return false }
        return effectivePort(of: a) == effectivePort(of: b)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// 跨域重定向时必须丢掉的凭据类请求头（大小写不敏感）：
    /// Authorization / Cookie / API key 之类绝不能跟去别的域名，
    /// HTTPS→HTTP 降级时同样不能带（明文泄漏）。
    static func isSensitiveHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "authorization", "cookie", "proxy-authorization",
             "x-api-key", "api-key", "apikey", "x-auth-token", "x-access-token",
             "cf-access-client-id", "cf-access-jwt-assertion":
            return true
        default:
            return false
        }
    }
}
