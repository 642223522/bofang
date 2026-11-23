import Foundation
import JavaScriptCore

/// ForwardWidget 宿主：用 JavaScriptCore 跑朋友格式的模块（pornjav.js 那套）。
/// 每个 WidgetHost 一个独立 JSContext，模块之间互不干扰。
///
/// 线程规矩（JSContext 只认一个线程）：
/// - 建 context、调 JS 函数、调 Promise.then 都在主线程上做；
/// - init 若不在主线程，会同步切到主线程建 context；
/// - async 方法里用 MainActor.run 包住同步的 JS 调用，
///   Promise 的回调（JS 在主线程调）再经 continuation 回到 Swift。
final class WidgetHost: @unchecked Sendable {

    let meta: WidgetMeta
    let modules: [ModuleDescriptor]

    private let context: JSContext
    private let exceptionBox: ExceptionBox
    /// 分类请求拦截器（一个 host 一个，跟着它自己的 JSContext 走）。
    private let requestInterceptor: CategoryRequestInterceptor
    /// 线路竞速（进模块时跑一次）：本次该模块的首选线。
    /// 内存里，进模块时重算；离开不保留（host 释放即丢弃）。
    /// nil = 没竞速 / 没分出胜负 / 两条都死 / 无固定验线 → 按现有逻辑。
    /// 锁保护：竞速在后台 Task 写，播放器在主线程读。
    private let raceLock = NSLock()
    private var _preferredLine: PreferredLine?
    var preferredLine: PreferredLine? {
        raceLock.lock()
        defer { raceLock.unlock() }
        return _preferredLine
    }
    /// 是否已跑过竞速（一个 host 只跑一次，进模块时触发）。
    private var didRaceLines = false

    enum WidgetHostError: Error, LocalizedError {
        case invalidFormat(String)
        case jsException(String)
        case functionMissing(String)
        case callFailed(String)
        case unexpectedResult(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let message): return message
            case .jsException(let message): return "脚本运行出错：\(message)"
            case .functionMissing(let message): return message
            case .callFailed(let message): return "调用模块失败：\(message)"
            case .unexpectedResult(let message): return message
            }
        }
    }

    // MARK: - 初始化

    /// 建 context、注入 Widget 桥接、evaluate 模块源码、取出元数据与模块清单。
    /// 取不到或格式不对就 throw（中文人话）。本方法只 evaluate，不发任何请求。
    init(jsSource: String) throws {
        let built = try Self.buildOnMainThread(jsSource: jsSource)
        self.context = built.context
        self.meta = built.meta
        self.modules = built.modules
        self.exceptionBox = built.exceptionBox
        self.requestInterceptor = built.requestInterceptor
    }

    private struct BuiltHost {
        let context: JSContext
        let meta: WidgetMeta
        let modules: [ModuleDescriptor]
        let exceptionBox: ExceptionBox
        let requestInterceptor: CategoryRequestInterceptor
    }

    private static func buildOnMainThread(jsSource: String) throws -> BuiltHost {
        if Thread.isMainThread {
            return try build(jsSource: jsSource)
        }
        // 不在主线程时同步切过去建（init 是同步的，没法 await；
        // 主线程调进来时走上面那条，不会死锁）。
        var result: Result<BuiltHost, Error>?
        DispatchQueue.main.sync {
            result = Result { try build(jsSource: jsSource) }
        }
        return try result!.get()
    }

    private static func build(jsSource: String) throws -> BuiltHost {
        guard let context = JSContext() else {
            throw WidgetHostError.invalidFormat("创建 JS 环境失败")
        }
        let box = ExceptionBox()
        context.exceptionHandler = { _, exception in
            box.message = exception?.toString()
        }

        let interceptor = CategoryRequestInterceptor()
        installWidgetBridge(in: context, interceptor: interceptor)

        context.evaluateScript(jsSource)
        if let message = box.message, !message.isEmpty {
            throw WidgetHostError.jsException(message)
        }

        // 取 WidgetMetadata
        guard let metaValue = context.objectForKeyedSubscript("WidgetMetadata"),
              !metaValue.isUndefined, !metaValue.isNull,
              let metaDict = metaValue.toDictionary() else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（缺 WidgetMetadata）")
        }
        let metaId = metaDict["id"] as? String ?? ""
        let metaTitle = metaDict["title"] as? String ?? ""
        guard !metaId.isEmpty, !metaTitle.isEmpty else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（模块信息不完整，缺 id 或标题）")
        }
        let searchDict = metaDict["search"] as? [String: Any]
        let meta = WidgetMeta(
            id: metaId,
            title: metaTitle,
            description: metaDict["description"] as? String ?? "",
            version: metaDict["version"] as? String ?? "1.0.0",
            searchFunctionName: searchDict?["functionName"] as? String,
            author: (metaDict["author"] as? String)?.nilIfEmpty,
            site: siteString(from: metaDict)
        )

        // 取 JS_MODULES
        guard let modulesValue = context.objectForKeyedSubscript("JS_MODULES"),
              !modulesValue.isUndefined, !modulesValue.isNull,
              let rawModules = modulesValue.toArray() else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（缺模块清单 JS_MODULES）")
        }
        var modules: [ModuleDescriptor] = []
        for raw in rawModules {
            guard let dict = raw as? [String: Any],
                  let moduleId = dict["id"] as? String, !moduleId.isEmpty,
                  let functionName = dict["functionName"] as? String, !functionName.isEmpty else {
                continue // 单个模块写坏了就跳过，不连累其他模块
            }
            modules.append(ModuleDescriptor(
                id: moduleId,
                title: dict["title"] as? String ?? moduleId,
                description: dict["description"] as? String ?? "",
                functionName: functionName,
                type: dict["type"] as? String,
                cacheDuration: dict["cacheDuration"] as? Int ?? 0,
                params: dict["params"] as? [[String: Any]] ?? []
            ))
        }
        guard !modules.isEmpty else {
            throw WidgetHostError.invalidFormat("这个脚本的模块清单是空的，没有可用的功能")
        }

        return BuiltHost(context: context, meta: meta, modules: modules, exceptionBox: box, requestInterceptor: interceptor)
    }

    /// 站点字段有多个叫法（site / siteUrl / homepage），哪个有取哪个；都没有或为空就 nil。
    private static func siteString(from metaDict: [String: Any]) -> String? {
        for key in ["site", "siteUrl", "homepage"] {
            if let value = metaDict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - Widget 桥接

    /// 注入全局 Widget 对象：Widget.http.get / Widget.storage.get / set，
    /// 再加一个空的 console.log（有的模块会 log，没它会报异常）。
    private static func installWidgetBridge(in context: JSContext, interceptor: CategoryRequestInterceptor) {
        let widget = JSValue(newObjectIn: context)!
        let http = JSValue(newObjectIn: context)!
        let storage = JSValue(newObjectIn: context)!

        // Widget.http.get(url, {headers}) -> Promise<{status, data}>
        // JS 调它时得到一个真 Promise；Swift 在后台发请求，完事回主线程 resolve/reject。
        // 注意：JSValue 的 block 用 @convention(block)，resolve/reject 必须在主线程调，
        // 所以这里只在 executor 里收下它们，真正的 resolve/reject 包在 MainActor.run 里。
        let httpGet: @convention(block) (String, JSValue?) -> JSValue = { [weak context] urlString, options in
            guard let context else {
                // JS 正在执行时 context 不可能已释放；这行理论上走不到。
                fatalError("WidgetHost: JSContext 已释放，无法发起请求")
            }
            return makeHttpGetPromise(in: context, urlString: urlString, options: options, interceptor: interceptor)
        }
        http.setValue(httpGet, forProperty: "get")
        widget.setValue(http, forProperty: "http")

        // Widget.storage.get(key) / set(key, value)：同步，UserDefaults，前缀 fw.storage.。
        // get 不存在返回 JS null（模块里 `if (raw)` 判空能正常工作）。
        let storageGet: @convention(block) (String) -> JSValue = { [weak context] key in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放")
            }
            if let value = UserDefaults.standard.string(forKey: "fw.storage." + key) {
                return JSValue(object: value, in: context)!
            }
            return JSValue(nullIn: context)!
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, value in
            UserDefaults.standard.set(value.toString(), forKey: "fw.storage." + key)
        }
        storage.setValue(storageGet, forProperty: "get")
        storage.setValue(storageSet, forProperty: "set")
        widget.setValue(storage, forProperty: "storage")

        let console = JSValue(newObjectIn: context)!
        let log: @convention(block) (JSValue) -> Void = { value in
            #if DEBUG
            print("[JS]", value.toString())
            #endif
        }
        console.setValue(log, forProperty: "log")
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        context.setObject(widget, forKeyedSubscript: "Widget" as NSString)
    }

    /// 从 context 取 Promise 构造器，用 executor block 造一个 JS Promise。
    /// executor 被 Promise 构造器同步调用，交出 resolve/reject；
    /// Swift 拿着它们去后台发请求，完事回主线程结算。
    private static func makeHttpGetPromise(in context: JSContext, urlString: String, options: JSValue?, interceptor: CategoryRequestInterceptor) -> JSValue {
        guard let promiseConstructor = context.objectForKeyedSubscript("Promise"),
              !promiseConstructor.isUndefined else {
            fatalError("WidgetHost: JS 环境里没有 Promise")
        }
        // headers 在 executor 里同步抠出来（当时还在主线程），Task 只带纯 Swift 值走，
        // resolve/reject 装进 Sendable 盒子带进 Task（JSValue 本身不是 Sendable）。
        let headers = headers(from: options)
        // 分类拦截：武装窗口内、且是同源 WP 帖子请求时，改成带 categories=<id> 的 URL；
        // 不命中返回原 URL。改写在发请求前同步完成（JS 调 http.get 时还在主线程）。
        let effectiveURL = interceptor.rewrittenURL(for: urlString) ?? urlString
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            let box = JSCallbackBox(resolve: resolve, reject: reject)
            Task {
                do {
                    let (status, data) = try await Self.fetchHTTP(urlString: effectiveURL, headers: headers)
                    await MainActor.run {
                        guard let ctx = box.resolve.context else { return }
                        let result = JSValue(newObjectIn: ctx)!
                        result.setValue(status, forProperty: "status")
                        result.setValue(data, forProperty: "data")
                        box.resolve.call(withArguments: [result])
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        guard let ctx = box.reject.context else { return }
                        if let jsError = ctx.objectForKeyedSubscript("Error")?.construct(withArguments: [message]) {
                            box.reject.call(withArguments: [jsError])
                        } else {
                            box.reject.call(withArguments: [message])
                        }
                    }
                }
            }
        }
        guard let promise = promiseConstructor.construct(withArguments: [executor]) else {
            fatalError("WidgetHost: 构造 Promise 失败")
        }
        return promise
    }

    private static func headers(from options: JSValue?) -> [String: String] {
        var headers: [String: String] = ["User-Agent": NetConstants.iPhoneUserAgent]
        if let dict = options?.objectForKeyedSubscript("headers")?.toDictionary() {
            for (key, value) in dict {
                if let keyString = key as? String {
                    headers[keyString] = "\(value)"
                }
            }
        }
        return headers
    }

    /// 真正发请求。只在传输层失败时 throw（对应 Promise reject）；
    /// HTTP 状态码是多少都 resolve 回去（{status, data}），让模块自己按 status 判断，
    /// pornjav 的 httpGetStatus 就是这么用的（404 也要看 status）。
    private static func fetchHTTP(urlString: String, headers: [String: String]) async throws -> (status: Int, data: Any) {
        guard let url = URL(string: urlString) else {
            throw WidgetHostError.callFailed("链接格式不对：\(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (raw, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, httpDataObject(from: raw))
    }

    /// 响应体能解析成 JSON 就给对象/数组，否则给文本。
    /// 模块里 `typeof data === "object"` 时直接当 JSON 用，文本时 JSON.parse。
    private static func httpDataObject(from raw: Data) -> Any {
        if let json = try? JSONSerialization.jsonObject(with: raw),
           json is [String: Any] || json is [Any] {
            return json
        }
        return String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
    }

    // MARK: - 对外接口

    /// 当前模块的分类识别规则（按 WidgetMeta.id 配，没配的用默认）。
    var categoryRule: CategoryDetectionRule {
        CategoryDetectionRules.rule(forModuleId: meta.id)
    }

    /// 宿主侧打分判断：这项是不是分类（跳转桩），而不是视频。
    func isCategoryItem(_ item: VideoItem) -> Bool {
        item.isCategory(under: categoryRule)
    }

    // MARK: - 线路竞速（进模块时跑一次，定本次首选线）

    /// 固定验线模块：params 里 kind 常量为 "fixed" 的那个；
    /// 兜底：id 或标题含 "fixed" / "固定验线"。
    /// pornjav.js 里就是 id "pornjav-fixed"、kind 常量 "fixed"，
    /// 返回两个固定样本 JUQ-984（nmcorp 线）＋ ATID-686（memojav 线）。
    /// 自检（SourceStore）也用这个找探针入口。
    func fixedProbeModule() -> ModuleDescriptor? {
        modules.first { module in
            module.params.contains { param in
                (param["name"] as? String) == "kind"
                && (param["type"] as? String) == "constant"
                && (param["value"] as? String) == "fixed"
            }
        } ?? modules.first { module in
            module.id.lowercased().contains("fixed")
            || module.title.contains("固定验线")
        }
    }

    /// 进模块时后台竞速（只跑一次）：调固定验线拿样本，各调 loadResource 解线计时，
    /// 最快且能播的线记为本次首选线（preferredLine，内存里，进模块时重算）。
    /// 没分出胜负 / 两条都死 / 无固定验线 → preferredLine 保持 nil，按现有逻辑。
    /// 不抛错、不阻塞调用方；后台跑，跑完写 preferredLine。
    /// 播放器读 preferredLine：首选 memojav 走快路径直拼；首选 nmcorp 先走 loadResource 拿 nmcorp 线。
    func raceLinesIfNeeded() {
        guard !didRaceLines else { return }
        didRaceLines = true
        Task.detached { [weak self] in
            guard let self else { return }
            let winner = await self.runLineRace()
            self.raceLock.lock()
            self._preferredLine = winner
            self.raceLock.unlock()
        }
    }

    /// 真正跑竞速：固定验线取样本，并发调 loadResource 解线计时。
    /// 每样本取第一条能播的线（.m3u8 或 .mp4）定种类；最快的那种线获胜。
    /// 没样本 / 都解不出 / 种类认不出 → nil（按现有逻辑）。
    /// 并发跑：两条线同时解，总耗时取最慢的一条，不叠加。
    private func runLineRace() async -> PreferredLine? {
        guard let probe = fixedProbeModule() else { return nil }
        let samples: [VideoItem]
        do {
            samples = try await loadList(moduleId: probe.id, page: 1)
        } catch {
            return nil
        }
        guard !samples.isEmpty else { return nil }
        var best: (kind: PreferredLine, elapsed: TimeInterval)?
        await withTaskGroup(of: (PreferredLine, TimeInterval)?.self) { group in
            for sample in samples {
                group.addTask {
                    let start = Date()
                    let lines = (try? await self.loadResource(link: sample.link, title: sample.title)) ?? []
                    let elapsed = Date().timeIntervalSince(start)
                    // 该样本第一条能播的线定种类；种类认不出则这个样本不算
                    for line in lines {
                        let lower = line.url.lowercased()
                        guard !line.url.isEmpty,
                              lower.contains(".m3u8") || lower.contains(".mp4") else { continue }
                        if let kind = PlaybackEngine.preferredLineKind(of: line) {
                            return (kind, elapsed)
                        }
                        break
                    }
                    return nil
                }
            }
            for await result in group {
                guard let result else { continue }
                if best == nil || result.1 < best!.elapsed {
                    best = result
                }
            }
        }
        return best?.kind
    }

    /// 调指定模块的列表函数，返回视频列表。
    func loadList(moduleId: String, page: Int) async throws -> [VideoItem] {
        guard let module = modules.first(where: { $0.id == moduleId }) else {
            throw WidgetHostError.functionMissing("没有这个模块：\(moduleId)")
        }
        let result = try await callFunction(module.functionName, params: buildParams(for: module, page: page, inputs: [:]))
        return try parseVideoItems(result)
    }

    /// 调 type == "stream" 的模块（一般是 loadResource），返回播放线路。
    /// url 为空的项已跳过；模块说“无可用播放源”时返回空数组，由调用方决定怎么显示。
    func loadResource(link: String, title: String) async throws -> [PlayLine] {
        guard let module = modules.first(where: { $0.type == "stream" }) else {
            throw WidgetHostError.functionMissing("这个模块没有播放解析功能")
        }
        let result = try await callFunction(module.functionName, params: buildParams(for: module, page: 1, inputs: ["link": link, "title": title]))
        return parsePlayLines(result)
    }

    /// 调 WidgetMetadata.search.functionName（一般是 searchVideos）。
    func search(keyword: String, page: Int) async throws -> [VideoItem] {
        guard let functionName = meta.searchFunctionName, !functionName.isEmpty else {
            throw WidgetHostError.functionMissing("这个模块不支持搜索")
        }
        let params: [String: Any]
        if let module = modules.first(where: { $0.functionName == functionName }) {
            params = buildParams(for: module, page: page, inputs: ["keyword": keyword])
        } else {
            params = ["keyword": keyword, "page": page]
        }
        let result = try await callFunction(functionName, params: params)
        return try parseVideoItems(result)
    }

    /// 取某分类下的视频。模块零改动，宿主侧两条路（按顺序）：
    /// (1) 请求拦截：调模块的 latest 列表，桥里把模块发出的同源 /wp-json/wp/v2/posts
    ///     请求改成带 &categories=<id>，模块照原样返回视频；只作用于这一次调用，
    ///     调用完立即撤掉；拦截没命中（模块没发这类请求）或没返回视频就走 (2)。
    /// (2) 直调 WP REST：GET /wp-json/wp/v2/posts?categories=<id>&per_page=20&page=<n>&_embed=1，
    ///     映射成 VideoItem；点视频时把帖子链接交回现有的 loadResource 解析播放。
    /// 分类链接绝不送进 loadResource。
    /// categoryId 是数字编号或 "pornjav-cat-33" 这类原始 id；siteHost / categorySlug
    /// 没有时对应路径自动跳过（拦截要求同源、直调要求域名）。
    func loadCategoryVideos(categoryId: String, categoryName: String, page: Int, siteHost: String? = nil, categorySlug: String? = nil) async throws -> [VideoItem] {
        let numericId = VideoItem.numericId(from: categoryId)
        let apiHost = siteHost.map { Self.stripWWWPrefix($0) }

        // (1) 请求拦截：调模块 latest，桥里改写它发出的 WP 帖子请求
        if let numericId, let apiHost, let latest = latestListModule() {
            let token = requestInterceptor.arm(siteHost: apiHost, categoryId: numericId)
            do {
                let result = try await callFunction(latest.functionName, params: buildParams(for: latest, page: page, inputs: [:]))
                let items = try parseVideoItems(result)
                let hit = requestInterceptor.didRewrite(token: token)
                requestInterceptor.disarm(token: token)
                if hit && !items.isEmpty {
                    return items
                }
                // 拦截命中但返回空，或没命中：都继续走直调 WP REST（真空还是假空由它判定）
            } catch is CancellationError {
                requestInterceptor.disarm(token: token)
                throw
            } catch {
                requestInterceptor.disarm(token: token)
                // 模块这条路抛错也继续走直调；直调再失败才报
            }
        }

        // (2) 直调 WP REST：有数字编号直接查帖子
        if let numericId, let apiHost {
            return try await fetchCategoryPostsDirect(siteHost: apiHost, categoryId: numericId, categoryName: categoryName, page: page)
        }
        // 没数字编号时按 slug 查分类拿 id 再查帖子
        if let apiHost, let slug = categorySlug, !slug.isEmpty,
           let resolved = try? await resolveWordPressCategoryId(siteHost: apiHost, slug: slug) {
            return try await fetchCategoryPostsDirect(siteHost: apiHost, categoryId: resolved, categoryName: categoryName, page: page)
        }

        throw WidgetHostError.functionMissing("该分类暂不支持浏览")
    }

    /// 导入时做格式校验：新建一个临时 WidgetHost（只 evaluate + 取元数据，不发请求）。
    static func validate(jsSource: String) -> (ok: Bool, meta: WidgetMeta?, error: String?) {
        do {
            let host = try WidgetHost(jsSource: jsSource)
            return (true, host.meta, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (false, nil, message)
        }
    }

    // MARK: - 内部：分类取列表（拦截 + 直调 WP REST）

    /// 找“最新”列表模块：params 里 kind 常量是 "latest" 的那个。
    /// 拦截路径调它（loadList kind=latest），桥里改写它发出的 WP 帖子请求。
    private func latestListModule() -> ModuleDescriptor? {
        modules.first { module in
            module.params.contains { param in
                (param["name"] as? String) == "kind"
                && (param["type"] as? String) == "constant"
                && (param["value"] as? String) == "latest"
            }
        }
    }

    /// 直调 WP REST 取某分类的帖子，映射成 VideoItem。
    /// 标题 HTML 解码、链接用帖子原链接、封面用 _embedded wp:featuredmedia[0].source_url、
    /// category 字段用分类名；点视频时把帖子链接交回现有的 loadResource 解析播放。
    private func fetchCategoryPostsDirect(siteHost: String, categoryId: String, categoryName: String, page: Int) async throws -> [VideoItem] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/wp-json/wp/v2/posts"
        components.queryItems = [
            URLQueryItem(name: "categories", value: categoryId),
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "_embed", value: "1"),
        ]
        guard let url = components.url else {
            throw WidgetHostError.callFailed("分类地址拼不出来")
        }
        let (status, items) = try await fetchWordPressArray(url: url)
        guard status == 200 else {
            if status == 400 { return [] } // 页码超出总页数：WP 用 400 表示没更多了
            throw WidgetHostError.callFailed("分类加载失败（HTTP \(status)）")
        }
        guard let items else {
            throw WidgetHostError.unexpectedResult("分类返回的不是帖子列表")
        }
        return items.compactMap { wordpressPostToVideoItem($0, categoryName: categoryName) }
    }

    /// 直调 WP REST 时没有数字编号：先按 slug 查分类拿 id。
    private func resolveWordPressCategoryId(siteHost: String, slug: String) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/wp-json/wp/v2/categories"
        components.queryItems = [URLQueryItem(name: "slug", value: slug)]
        guard let url = components.url else { return nil }
        let (status, items) = try await fetchWordPressArray(url: url)
        guard status == 200, let first = items?.first else { return nil }
        if let id = first["id"] as? Int { return "\(id)" }
        if let idString = first["id"] as? String, !idString.isEmpty { return idString }
        return nil
    }

    /// 直调 WP REST 的通用 GET：返回 (status, JSON 数组或 nil)。
    /// 传输失败时 throw；HTTP 状态码原样返回，由调用方判定。
    private func fetchWordPressArray(url: URL) async throws -> (status: Int, items: [[String: Any]]?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (raw, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let items = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        return (status, items)
    }

    /// 一篇 WP 帖子 → VideoItem（直调路径用）。标题为空或链接为空的帖子跳过。
    private func wordpressPostToVideoItem(_ post: [String: Any], categoryName: String) -> VideoItem? {
        guard let link = post["link"] as? String, !link.isEmpty else { return nil }
        let rawTitle = (post["title"] as? [String: Any])?["rendered"] as? String ?? ""
        let title = Self.htmlDecoded(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var cover: String? = nil
        if let embedded = post["_embedded"] as? [String: Any],
           let media = embedded["wp:featuredmedia"] as? [[String: Any]],
           let first = media.first,
           let source = first["source_url"] as? String, !source.isEmpty {
            cover = source
        }
        return VideoItem(
            id: link,
            title: title,
            link: link,
            coverURL: cover,
            description: "",
            category: categoryName
        )
    }

    /// WP 标题里的 HTML 实体解码（&amp; &#123; &#x1F; 这类），顺手去掉残留标签。
    private static func htmlDecoded(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            if ch == "<" {
                if let gt = raw[i...].firstIndex(of: ">") {
                    i = raw.index(after: gt)
                    continue
                }
                out.append(ch)
                i = raw.index(after: i)
                continue
            }
            if ch == "&" {
                let tail = raw[i...]
                if let semi = tail.firstIndex(of: ";"),
                   tail.distance(from: tail.startIndex, to: semi) <= 9 {
                    let body = String(tail[tail.index(after: tail.startIndex)..<semi])
                    if let decoded = decodeHTMLEntity(body) {
                        out.append(decoded)
                        i = raw.index(after: semi)
                        continue
                    }
                }
                out.append(ch)
                i = raw.index(after: i)
                continue
            }
            out.append(ch)
            i = raw.index(after: i)
        }
        return out
    }

    /// 单个 HTML 实体 → 字符；不认识的返回 nil（调用方原样保留 "&..."）。
    private static func decodeHTMLEntity(_ body: String) -> String? {
        switch body {
        case "amp": return "&"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default:
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(String(body.dropFirst(2)), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    return String(Character(scalar))
                }
            } else if body.hasPrefix("#") {
                if let code = UInt32(String(body.dropFirst())),
                   let scalar = Unicode.Scalar(code) {
                    return String(Character(scalar))
                }
            }
            return nil
        }
    }

    /// 去掉 host 前的 www.（pornjav 的 API 在 apex 域名，分类链接可能是 www）。
    private static func stripWWWPrefix(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - 内部：调函数与 Promise 桥接

    /// 按模块描述拼 params：constant 取 value，page 取页码，input 取传入的 inputs。
    private func buildParams(for module: ModuleDescriptor, page: Int, inputs: [String: String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for param in module.params {
            guard let name = param["name"] as? String, !name.isEmpty else { continue }
            switch param["type"] as? String {
            case "constant":
                out[name] = param["value"] ?? ""
            case "page":
                out[name] = page
            case "input":
                out[name] = inputs[name] ?? ""
            default:
                out[name] = param["value"] ?? ""
            }
        }
        return out
    }

    private func callFunction(_ name: String, params: [String: Any]) async throws -> JSValue {
        try await callFunction(name, args: [params])
    }

    /// 调 JS 函数（async 函数返回 Promise）。函数查找与调用在主线程做，
    /// 返回的 Promise 再经 awaitPromise 桥回 Swift async。
    private func callFunction(_ name: String, args: [Any]) async throws -> JSValue {
        let returned = try await MainActor.run { () throws -> JSValue in
            guard let fn = context.objectForKeyedSubscript(name),
                  !fn.isUndefined, !fn.isNull else {
                throw WidgetHostError.functionMissing("模块里没有这个功能：\(name)")
            }
            guard let ret = fn.call(withArguments: args) else {
                throw WidgetHostError.callFailed("调用 \(name) 没有返回结果")
            }
            if let exception = takeException() {
                throw WidgetHostError.jsException(exception)
            }
            return ret
        }
        return try await awaitPromise(returned)
    }

    /// 读走并清空最近一次 JS 异常（只能在主线程调，调用处都在 MainActor.run 里）。
    private func takeException() -> String? {
        let message = exceptionBox.message
        exceptionBox.message = nil
        return message.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 等一个 JS Promise，30 秒超时。超时或 reject 都 throw。
    private func awaitPromise(_ value: JSValue) async throws -> JSValue {
        let box = JSValueBox(value)
        return try await withThrowingTaskGroup(of: JSValue.self) { group in
            group.addTask { try await self.awaitPromiseRaw(box.value) }
            group.addTask {
                try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                throw WidgetHostError.callFailed("模块 30 秒没返回，可能是站挂了或网络太慢")
            }
            guard let result = try await group.next() else {
                throw WidgetHostError.callFailed("模块没有返回")
            }
            group.cancelAll()
            return result
        }
    }

    /// Promise 桥接的核心：
    /// - 不是 Promise（没有 then）就直接当结果用——有的模块同步返回数组，不包 Promise；
    /// - 是 Promise 就调它的 then(onFulfilled, onRejected)，用 continuation 转成 Swift async。
    /// 关键点：then 必须用 invokeMethod 调（直接把 then 抠出来 call 会丢 this，
    /// JSC 会报 TypeError）；then 的调用必须在主线程。
    private func awaitPromiseRaw(_ value: JSValue) async throws -> JSValue {
        let box = JSValueBox(value)
        let thenValue = await MainActor.run { box.value.objectForKeyedSubscript("then") }
        guard let thenValue, !thenValue.isUndefined, !thenValue.isNull else {
            return value
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceBox()
            // 回调装进 Sendable 盒子再带进 DispatchQueue 的闭包（JSValue 本身不是 Sendable）。
            let callbacks = PromiseCallbacks(
                fulfilled: { resolved in
                    guard once.tryTake() else { return }
                    continuation.resume(returning: resolved)
                },
                rejected: { reason in
                    guard once.tryTake() else { return }
                    let messageValue = reason.objectForKeyedSubscript("message")
                    let message: String
                    if let messageValue, !messageValue.isUndefined, !messageValue.isNull,
                       !messageValue.toString().isEmpty {
                        message = messageValue.toString()
                    } else {
                        message = reason.toString()
                    }
                    continuation.resume(throwing: WidgetHostError.callFailed(message.isEmpty ? "模块执行失败" : message))
                }
            )
            DispatchQueue.main.async {
                _ = box.value.invokeMethod("then", withArguments: [callbacks.fulfilled, callbacks.rejected])
            }
        }
    }

    // MARK: - 内部：结果解析

    private func parseVideoItems(_ value: JSValue) throws -> [VideoItem] {
        guard let array = value.toArray() else {
            throw WidgetHostError.unexpectedResult("模块返回的不是列表，看不懂")
        }
        var items: [VideoItem] = []
        for raw in array {
            guard let dict = raw as? [String: Any] else { continue }
            items.append(videoItem(from: dict))
        }
        return items
    }

    private func videoItem(from dict: [String: Any]) -> VideoItem {
        let link = dict["link"] as? String ?? ""
        // 封面字段名各模块不统一，多个候选按顺序取第一个非空的
        let coverKeys = ["coverUrl", "posterUrl", "posterURL", "posterurl", "poster_url",
                         "posterPath", "poster_path", "backdropPath", "thumbnailUrl",
                         "imageUrl", "detailPoster", "detailPosterUrl", "detailPosterURL",
                         "cover", "image"]
        var cover: String? = nil
        for key in coverKeys {
            if let url = dict[key] as? String, !url.isEmpty {
                cover = url
                break
            }
        }
        return VideoItem(
            id: (dict["id"] as? String)?.nilIfEmpty ?? link.nilIfEmpty ?? UUID().uuidString,
            title: dict["title"] as? String ?? "",
            link: link,
            coverURL: cover,
            description: dict["description"] as? String ?? "",
            category: (dict["_cat"] as? String) ?? (dict["category"] as? String) ?? ""
        )
    }

    private func parsePlayLines(_ value: JSValue) -> [PlayLine] {
        var dicts: [[String: Any]] = []
        if let array = value.toArray() {
            dicts = array.compactMap { $0 as? [String: Any] }
        } else if let single = value.toDictionary() {
            var stringDict: [String: Any] = [:]
            for (key, value) in single {
                if let keyString = key as? String {
                    stringDict[keyString] = value
                }
            }
            dicts = [stringDict]
        }
        var lines: [PlayLine] = []
        for dict in dicts {
            guard let url = dict["url"] as? String, !url.isEmpty else { continue }
            lines.append(PlayLine(
                name: dict["name"] as? String ?? "线路",
                url: url,
                description: dict["description"] as? String ?? ""
            ))
        }
        return lines
    }
}

// MARK: - 小盒子（线程 / Sendable 用）

/// 接 JS 异常信息的盒子（exceptionHandler 回调里写，takeException 里读）。
private final class ExceptionBox {
    var message: String?
}

/// 防 continuation 被两个回调各 resume 一次（Promise 正常只调一个，但防一手，
/// 重复 resume 会直接 crash）。
private final class OnceBox {
    private let lock = NSLock()
    private var done = false

    func tryTake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// 把 JSValue 包一层 @unchecked Sendable，带进 Task / @Sendable 闭包。
/// 盒子只负责传递，JSValue 的方法调用仍只在主线程上做。
private final class JSValueBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

/// http.get 的 resolve/reject，带进后台 Task 用。
private final class JSCallbackBox: @unchecked Sendable {
    let resolve: JSValue
    let reject: JSValue
    init(resolve: JSValue, reject: JSValue) {
        self.resolve = resolve
        self.reject = reject
    }
}

/// Promise.then 的两个回调，带进 DispatchQueue.main.async 用。
private final class PromiseCallbacks: @unchecked Sendable {
    let fulfilled: @convention(block) (JSValue) -> Void
    let rejected: @convention(block) (JSValue) -> Void

    init(fulfilled: @escaping @convention(block) (JSValue) -> Void,
         rejected: @escaping @convention(block) (JSValue) -> Void) {
        self.fulfilled = fulfilled
        self.rejected = rejected
    }
}

/// 分类请求拦截：一次性的 URL 改写。
/// 点分类时武装（arm），调模块 latest 期间，桥里把模块发出的同源
/// /wp-json/wp/v2/posts 请求改成带 categories=<id>；调用完立即撤掉（disarm）。
/// 只改这一次调用、只匹配帖子列表路径、只同源（模块站点域名，www. 前缀不计）。
/// 线程安全（NSLock）；token 防止并发调用互相撤掉对方的武装。
private final class CategoryRequestInterceptor: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: (token: UUID, siteHost: String, categoryId: String)?
    private var rewroteTokens: Set<UUID> = []

    func arm(siteHost: String, categoryId: String) -> UUID {
        let token = UUID()
        lock.lock()
        armed = (token, siteHost, categoryId)
        lock.unlock()
        return token
    }

    func disarm(token: UUID) {
        lock.lock()
        if armed?.token == token { armed = nil }
        lock.unlock()
    }

    /// 本次武装窗口内是否改写过至少一个请求（判断拦截是否命中）；读一次即清掉记录。
    func didRewrite(token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rewroteTokens.remove(token) != nil
    }

    /// 命中返回改写后的 URL，不命中返回 nil（调用方用原 URL）。
    func rewrittenURL(for urlString: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let armed else { return nil }
        guard let url = URL(string: urlString),
              let host = url.host,
              Self.sameSite(host, armed.siteHost),
              url.path == "/wp-json/wp/v2/posts",
              !urlString.contains("categories=") else { return nil }
        let separator = urlString.contains("?") ? "&" : "?"
        let rewritten = urlString + separator + "categories=" + armed.categoryId
        rewroteTokens.insert(armed.token)
        return rewritten
    }

    private static func sameSite(_ host: String, _ siteHost: String) -> Bool {
        stripWWW(host.lowercased()) == stripWWW(siteHost.lowercased())
    }

    private static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
