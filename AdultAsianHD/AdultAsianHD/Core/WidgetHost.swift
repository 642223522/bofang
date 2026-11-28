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
    /// 在途 Widget.http 请求登记表（见 HTTPRequestRegistry）：executor Task
    /// 是 detached 的，host 释放时没人取消，记在这里统一取消。
    /// 注意：声明上不带初值（初值在 init 里从 built.httpRegistry 拿）——
    /// let 带了初值又在 init 里再赋一次会编译失败（run #15 的 originalHost
    /// 同款坑，run #17 第二轮又栽了一次）。
    private let httpRegistry: HTTPRequestRegistry
    /// 在途定时器登记表（见 TimerRegistry，chunk-1 P1-6）：setTimeout/setInterval
    /// 不再用 installWidgetBridge 里的局部变量，host 释放时统一取消，
    /// 不让定时器在 host 释放后还跑模块代码。声明上不带初值（与 httpRegistry 同款原因）。
    private let timerRegistry: TimerRegistry
    /// 安装桥时从全新 context 上取下的原生 Promise 构造器（chunk-1 P1-3）：
    /// 模块改写全局 Promise 后，Widget.http 仍用它造 Promise，不 fatalError。
    /// 强引用放在 host 身上（host → 构造器 → context，不成环）；桥里的
    /// http.get/post block 只拿弱盒 NativePromiseStore（见 installWidgetBridge）。
    /// 声明上不带初值（与 httpRegistry 同款原因）。
    private let nativePromiseConstructor: JSValue?
    /// 线路竞速（进模块时跑一次）：本次该模块的首选线。
    /// 本会话（开软件到关软件）每个模块只自动竞速一次：首选线记在 SourceStore
    /// 的会话缓存里，新 host 不重竞时 preferredLine 兜底读它（见下面 getter）。
    /// 内存里；关软件即丢弃，下次打开重竞。nil = 没竞速 / 没分出胜负 /
    /// 两条都死 / 无固定验线 → 按现有逻辑。
    /// 锁保护：竞速在后台 Task 写，播放器在主线程读。
    private let raceLock = NSLock()
    private var _preferredLine: PreferredLine?
    var preferredLine: PreferredLine? {
        raceLock.lock()
        defer { raceLock.unlock() }
        if let line = _preferredLine { return line }
        // 本会话别的 host 已竞出首选线：直接用它，不再重竞。
        // 竞速还在跑时这里是 nil，播放器按现有逻辑走（与竞速前一样）。
        return SourceStore.shared.sessionPreferredLine(for: meta.id)
    }
    /// sourceGeneration：源 JS 的内容指纹（SourceStore.loadHost 传）；
    /// 线路竞速的种子只认同代种子，源换了 JS 旧种子作废。默认 ""（未知，
    /// 种子校验时跳过代际比对）。
    let sourceGeneration: String
    /// 是否已跑过竞速（一个 host 只跑一次，进模块时触发）。
    private var didRaceLines = false
    /// 用户可见请求计数（列表/分类/搜索/详情）：竞速取样时看到它 >0 就让路，
    /// 不跟首屏抢网。竞速自己的 loadResource 不计数（不然自己把自己堵死）。
    private let userRequestLock = NSLock()
    private var userRequestCount = 0
    private var isUserRequestActive: Bool {
        userRequestLock.lock()
        defer { userRequestLock.unlock() }
        return userRequestCount > 0
    }
    private func beginUserRequest() {
        userRequestLock.lock()
        userRequestCount += 1
        userRequestLock.unlock()
    }
    private func endUserRequest() {
        userRequestLock.lock()
        userRequestCount = max(0, userRequestCount - 1)
        userRequestLock.unlock()
    }
    /// slug→分类 id 缓存（host|slug → id，TTL 1 小时）：没数字编号时才查 slug，
    /// 查一次记下来，同一 host 同一 slug 不重复发 /categories 请求。
    private static let categoryIdCacheLock = NSLock()
    private static var categoryIdCache: [String: (id: String, at: Date)] = [:]
    private static let categoryIdCacheTTL: TimeInterval = 3600

    /// Widget.html 的两个 .txt 资源（cheerio bundle + 胶水）：每进程只读一次盘，
    /// __fwEnsureCheerio / 胶水加载时直接取缓存（读不到就是 nil，按“不可用”走）。
    private static let cheerioBundle: String? = {
        guard let url = Bundle.main.url(forResource: "cheerio.min", withExtension: "js.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }()
    private static let widgetHTMLGlue: String? = {
        guard let url = Bundle.main.url(forResource: "WidgetHTML", withExtension: "js.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }()

    enum WidgetHostError: Error, LocalizedError {
        case invalidFormat(String)
        case jsException(String)
        case functionMissing(String)
        case callFailed(String)
        case unexpectedResult(String)
        /// 传输层错误（Widget.http 桥还原出来的底层 URLError 码，见 mapJSRejection）：
        /// 账本/诊断靠它区分“疑需节点”与真失败，不能压扁成普通 JS 异常。
        case transport(urlErrorCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let message): return message
            case .jsException(let message): return "脚本运行出错：\(message)"
            case .functionMissing(let message): return message
            case .callFailed(let message): return "调用模块失败：\(message)"
            case .unexpectedResult(let message): return message
            case .transport(let code, let message): return "网络请求失败（\(code)）：\(message)"
            }
        }
    }

    /// 超时一本账（chunk-1 P1-10）：全文件共用的超时常量，集中在这里，
    /// 不再让超时数字散落在各处（Widget.http 默认 12s、awaitPromise 30s、
    /// parseMs 可声明到 60s 等各说各话）。
    /// promiseWindowMs 是 awaitPromise 的窗口；CheckTimeouts.effectiveMs
    /// （Models.swift）夹到窗口减余量，不再让模块声明的 parseMs 被静默截断。
    /// http 超时是秒（timeoutInterval 用）；其余是毫秒。
    enum WidgetTimeoutBudget {
        /// awaitPromise 窗口：模块一次调用最长等 30 秒。
        static let promiseWindowMs = 30_000
        /// 窗口内给 Swift 侧收尾留的余量（毫秒）。
        static let reserveMs = 2_000
        /// Widget.http 默认超时（秒）。
        static let httpDefaultSeconds: TimeInterval = 12
        /// Widget.http 超时夹值下限（秒）。
        static let httpMinSeconds: TimeInterval = 3
        /// Widget.http 超时夹值上限（秒）。
        static let httpMaxSeconds: TimeInterval = 25
        /// options.timeout 的启发式分界：> 120 当毫秒，否则当秒。
        static let timeoutMillisThreshold: Double = 120
    }

    // MARK: - 初始化

    /// 建 context、注入 Widget 桥接、evaluate 模块源码、取出元数据与模块清单。
    /// 取不到或格式不对就 throw（中文人话）。本方法只 evaluate，不发任何请求。
    /// fallbackTitle：WidgetMetadata 缺标题时用的兜底（一般传文件名），再没有用 id。
    /// preknownModuleID：调用方已知的可信模块 id（SourceStore.loadHost 传
    /// SourceRecord.id），evaluateScript 之前就预填进 ModuleIDBox，
    /// 模块顶层代码调 storage 走的就是本模块前缀（P1-2）；导入校验没有可信
    /// id 时传 nil，build 里用一次性临时命名空间，绝不共用空串。
    init(jsSource: String, fallbackTitle: String? = nil, sourceGeneration: String = "", preknownModuleID: String? = nil) throws {
        let built = try Self.buildOnMainThread(jsSource: jsSource, fallbackTitle: fallbackTitle, preknownModuleID: preknownModuleID)
        self.context = built.context
        self.meta = built.meta
        self.modules = built.modules
        self.exceptionBox = built.exceptionBox
        self.requestInterceptor = built.requestInterceptor
        self.httpRegistry = built.httpRegistry
        self.timerRegistry = built.timerRegistry
        self.nativePromiseConstructor = built.nativePromiseConstructor
        self.sourceGeneration = sourceGeneration
        // 模块声明的强制传输 host 交给网络层登记（宿主不硬编码任何 host）。
        if !built.meta.forceTransportHosts.isEmpty {
            DiagnosticHTTPClient.shared.registerForcedTransportHosts(built.meta.forceTransportHosts)
        }
    }

    deinit {
        // host 释放：在途的 Widget.http 请求全部取消，不让 detached 的
        // executor Task 继续跑、继续 resolve 已释放的 JSContext。
        httpRegistry.cancelAll()
        // host 释放：在途的定时器全部取消，不让 setTimeout/setInterval
        // 在 host 释放后还在主线程跑模块代码（chunk-1 P1-6）。
        timerRegistry.cancelAll()
    }

    private struct BuiltHost {
        let context: JSContext
        let meta: WidgetMeta
        let modules: [ModuleDescriptor]
        let exceptionBox: ExceptionBox
        let requestInterceptor: CategoryRequestInterceptor
        let httpRegistry: HTTPRequestRegistry
        let timerRegistry: TimerRegistry
        let nativePromiseConstructor: JSValue?
    }

    private static func buildOnMainThread(jsSource: String, fallbackTitle: String? = nil, preknownModuleID: String? = nil) throws -> BuiltHost {
        if Thread.isMainThread {
            return try build(jsSource: jsSource, fallbackTitle: fallbackTitle, preknownModuleID: preknownModuleID)
        }
        // 不在主线程时同步切过去建（init 是同步的，没法 await；
        // 主线程调进来时走上面那条，不会死锁）。
        var result: Result<BuiltHost, Error>?
        DispatchQueue.main.sync {
            result = Result { try build(jsSource: jsSource, fallbackTitle: fallbackTitle, preknownModuleID: preknownModuleID) }
        }
        return try result!.get()
    }

    private static func build(jsSource: String, fallbackTitle: String? = nil, preknownModuleID: String? = nil) throws -> BuiltHost {
        guard let context = JSContext() else {
            throw WidgetHostError.invalidFormat("创建 JS 环境失败")
        }
        let box = ExceptionBox()
        // P1-5 方案 (ii)：自定义 handler 会替代默认 handler，context.exception
        // 恒为 nil，所以全文件只读/写 box.message，不再碰 context.exception。
        context.exceptionHandler = { _, exception in
            box.message = exception?.toString()
        }

        let interceptor = CategoryRequestInterceptor()
        let httpRegistry = HTTPRequestRegistry()
        let timerRegistry = TimerRegistry()
        // 原生 Promise 构造器（P1-3）：context 刚建、模块源码还没跑，
        // 全局 Promise 一定是内建的；现在取下强引用，之后模块再怎么改写
        // 全局 Promise 都不影响 Widget.http。强引用走 BuiltHost 进 host，
        // 桥里的 block 只拿弱盒 promiseStore（不成环）。
        let nativePromiseConstructor = context.objectForKeyedSubscript("Promise")
        let promiseStore = NativePromiseStore()
        promiseStore.constructor = nativePromiseConstructor
        // P1-11：模块 id 的盒子——桥里的 storage/localStorage block 只拿
        // 这个盒子、每次调用现算前缀。P1-2：调用方已知的可信 id 在装桥之前
        // 就预填进去，模块顶层代码调 storage 走的就是本模块前缀；
        // 导入校验没有可信 id 时用一次性临时命名空间（"__import__.<随机>"），
        // 校验阶段的读写落在独立前缀下，绝不共用空串前缀；
        // meta.id 到手后下面再以它为准（临时 host 随即丢弃）。
        let moduleIDBox = ModuleIDBox()
        // 导入校验没有可信 id 时的临时命名空间：记下来，meta 到手后清掉
        // 它名下的 storage/localStorage 孤儿键（见下面 metaId 校正处）。
        let tempImportID: String?
        if let preknownModuleID, !preknownModuleID.isEmpty {
            moduleIDBox.id = preknownModuleID
            tempImportID = nil
        } else {
            let temp = "__import__." + UUID().uuidString
            moduleIDBox.id = temp
            tempImportID = temp
        }
        installWidgetBridge(in: context, interceptor: interceptor, httpRegistry: httpRegistry, timerRegistry: timerRegistry, promiseStore: promiseStore, exceptionBox: box, moduleIDBox: moduleIDBox)
        // build() 失败路径清理（P1-1/P2-1 合修）：下面任一 throw 都会直接
        // 丢掉 BuiltHost，没人走 WidgetHost.init/deinit，顶层 JS 在
        // evaluateScript 里已挂的 setInterval（顶层 setInterval 未取消会
        // 永久空转）与在途 Widget.http 请求（detached executor Task）会
        // 泄漏——失败时在这里统一取消。
        // 临时前缀清理在 defer 顶层无条件跑一次（R5：成功与任意失败点都只
        // 清一次；原来成功路径在 metaId 校正处另清一份，第 5/6 个 throw 点
        // 会与 defer 各扫一次。temp 是 "__import__.<随机 UUID>"，模块 id
        // 不可能撞上，故不再判 temp != metaId）。
        var builtSucceeded = false
        defer {
            if !builtSucceeded {
                httpRegistry.cancelAll()
                timerRegistry.cancelAll()
            }
            if let temp = tempImportID {
                Self.clearUserDefaultsKeys(withPrefix: "fw.storage." + temp + ".")
                Self.clearUserDefaultsKeys(withPrefix: "fw.localstorage." + temp + ".")
            }
        }

        context.evaluateScript(jsSource)
        if let message = box.message, !message.isEmpty {
            throw WidgetHostError.jsException(message)
        }

        // 取 WidgetMetadata（顶层 const 写法走 globalSymbol 的求值回退，chunk-1 P1-8）
        guard let metaValue = Self.globalSymbol(in: context, named: "WidgetMetadata"),
              !metaValue.isUndefined, !metaValue.isNull,
              let metaDict = metaValue.toDictionary() as? [String: Any] else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（缺 WidgetMetadata）")
        }
        let metaId = metaDict["id"] as? String ?? ""
        guard !metaId.isEmpty else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（模块信息不完整，缺 id）")
        }
        // P1-11 + P1-2：id 以模块自报的 meta.id 为准。正常与预填一致
        //（预填的 id 本就是上次导入时从同一个模块的 meta 取的），
        // 不一致时信模块、不信旧记录；导入校验时这里把临时命名空间换成真 id。
        if moduleIDBox.id != metaId {
            moduleIDBox.id = metaId
        }
        // 标题缺失不整文件报错：先用调用方给的文件名，再退回 id。
        let metaTitle: String = {
            if let t = metaDict["title"] as? String, !t.isEmpty { return t }
            if let f = fallbackTitle, !f.isEmpty { return f }
            return metaId
        }()
        let searchDict = metaDict["search"] as? [String: Any]
        // 竞速解析超时（毫秒）：模块在 WidgetMetadata.checkTimeouts 里声明，
        // 没声明的步为 nil，竞速用分步默认值（见 CheckTimeouts.effectiveMs）。
        let checkDict = metaDict["checkTimeouts"] as? [String: Any]
        let checkTimeouts = CheckTimeouts(
            listMs: checkDict?["listMs"] as? Int,
            detailMs: checkDict?["detailMs"] as? Int,
            parseMs: checkDict?["parseMs"] as? Int,
            playlistMs: checkDict?["playlistMs"] as? Int,
            firstFrameMs: checkDict?["firstFrameMs"] as? Int
        )
        // 强制传输 host：模块在 WidgetMetadata.forceTransportHosts 里声明
        //（字符串数组）；宿主只提供能力，要不要强制由模块说了算。
        let forceTransportHosts: [String] = {
            guard let arr = metaDict["forceTransportHosts"] as? [Any] else { return [] }
            return arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                .filter { !$0.isEmpty }
        }()
        let meta = WidgetMeta(
            id: metaId,
            title: metaTitle,
            description: metaDict["description"] as? String ?? "",
            version: metaDict["version"] as? String ?? "1.0.0",
            searchFunctionName: searchDict?["functionName"] as? String,
            author: (metaDict["author"] as? String)?.nilIfEmpty,
            site: siteString(from: metaDict),
            checkTimeouts: checkTimeouts,
            forceTransportHosts: forceTransportHosts
        )

        // 取模块清单（超集，三路，比 Rex 更宽松）：
        // (1) 全局 JS_MODULES；(2) WidgetMetadata.modules（如 huangguo.js 的 HG_MODULES）；
        // (3) 兜底扫顶层：任何一个元素含 id + functionName 的数组（变量名任意）。
        guard let rawModules = findModuleList(in: context, metaDict: metaDict) else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（找不到模块清单）")
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
                requiresWebView: dict["requiresWebView"] as? Bool ?? false,
                params: dict["params"] as? [[String: Any]] ?? []
            ))
        }
        guard !modules.isEmpty else {
            throw WidgetHostError.invalidFormat("这个脚本的模块清单是空的，没有可用的功能")
        }

        builtSucceeded = true
        return BuiltHost(context: context, meta: meta, modules: modules, exceptionBox: box, requestInterceptor: interceptor, httpRegistry: httpRegistry, timerRegistry: timerRegistry, nativePromiseConstructor: nativePromiseConstructor)
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

    /// 按前缀删 UserDefaults 键（导入校验临时命名空间清理用；只清给定的
    /// 临时前缀，调用方保证不传真实模块前缀）。
    private static func clearUserDefaultsKeys(withPrefix prefix: String) {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 读全局符号（chunk-1 P1-8）：顶层 const/let/class 不挂在全局对象上，
    /// objectForKeyedSubscript 读不到；读不到时回退到直接求值。
    /// 名字先校验标识符格式（^[A-Za-z_$][A-Za-z0-9_$]*$），否则就是脚本注入。
    /// 回退只在首次读取为 nil/undefined/null 时触发，不每次都走 evaluateScript。
    /// 只能在主线程调（调用处都在 build / MainActor.run 里）。
    private static func globalSymbol(in context: JSContext, named name: String) -> JSValue? {
        if let value = context.objectForKeyedSubscript(name),
           !value.isUndefined, !value.isNull {
            return value
        }
        guard name.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil else {
            return nil
        }
        guard let value = context.evaluateScript("typeof \(name) !== 'undefined' ? \(name) : undefined"),
              !value.isUndefined, !value.isNull else {
            return nil
        }
        return value
    }

    /// 找模块清单（超集，三路）：(1) 全局 JS_MODULES；(2) WidgetMetadata.modules；
    /// (3) 兜底扫顶层变量：任何一个元素含 id + functionName 的数组（变量名任意，比 Rex 更宽松）。
    /// 返回解析好的 [[String: Any]]，三路都找不到返回 nil。
    private static func findModuleList(in context: JSContext, metaDict: [String: Any]) -> [[String: Any]]? {
        // (1) 全局 JS_MODULES（pornjav.js 那套老格式；const 写法走 globalSymbol 回退，P1-8）
        if let value = Self.globalSymbol(in: context, named: "JS_MODULES"),
           !value.isUndefined, !value.isNull,
           let raw = value.toArray() {
            let dicts = raw.compactMap { $0 as? [String: Any] }
            if !dicts.isEmpty { return dicts }
        }
        // (2) WidgetMetadata.modules（huangguo.js：HG_MODULES 只挂在这里）
        if let raw = metaDict["modules"] as? [Any] {
            let dicts = raw.compactMap { $0 as? [String: Any] }
            if !dicts.isEmpty { return dicts }
        }
        // (3) 兜底扫顶层：变量名任意，只要首个元素像模块（id + functionName 齐全）。
        // HG_CATS 这种元素是数组的、BLOCK_TERMS 这种空数组，首元素一关就过不去。
        guard let keysValue = context.evaluateScript("Object.keys(this)"),
              let keys = keysValue.toArray() as? [String] else { return nil }
        for key in keys {
            guard key != "JS_MODULES", key != "WidgetMetadata", key != "Widget" else { continue }
            guard let value = Self.globalSymbol(in: context, named: key),
                  !value.isUndefined, !value.isNull,
                  value.isArray,
                  let raw = value.toArray(), !raw.isEmpty,
                  let first = raw.first as? [String: Any],
                  let firstId = first["id"] as? String, !firstId.isEmpty,
                  let firstFn = first["functionName"] as? String, !firstFn.isEmpty else { continue }
            let dicts = raw.compactMap { $0 as? [String: Any] }
            if !dicts.isEmpty { return dicts }
        }
        return nil
    }

    // MARK: - Widget 桥接

    /// 注入全局 Widget 对象与 JS 全局 API：
    /// Widget.http.get / post（回值 {status, data, headers, arrayBuffer}）、
    /// Widget.storage.get / set / remove / clear、localStorage（getItem/setItem/removeItem/clear，
    /// 前缀 fw.localstorage.<moduleId>.）、全局 fetch（GET/POST 最小实现）、setTimeout / clearTimeout、
    /// setInterval / clearInterval、console.log / info / debug / warn / error（多参数拼接）。
    /// Widget.html.load / loadURL（Cheerio DOM 解析，见 Core/WidgetHTML.js.txt；
    /// URL/URLSearchParams 在建桥时就装（模块可能在第一次调 html.load 之前就 new URL，
    /// 懒装会让它 ReferenceError）；只有 cheerio bundle 由 __fwEnsureCheerio 懒注入——
    /// 只在第一次调 html.load/loadURL 时装，不用的模块不付这个钱；
    /// 裸 JSC 没有 URL，cheerio 的 prop('href')/prop('src') 靠它解析相对地址）。
    /// 模块发现三路超集、loadDetail/childItems/relatedItems 解析、分类拦截器都不在这里动。
    private static func installWidgetBridge(in context: JSContext, interceptor: CategoryRequestInterceptor, httpRegistry: HTTPRequestRegistry, timerRegistry: TimerRegistry, promiseStore: NativePromiseStore, exceptionBox: ExceptionBox, moduleIDBox: ModuleIDBox) {
        let widget = JSValue(newObjectIn: context)!
        let http = JSValue(newObjectIn: context)!
        let storage = JSValue(newObjectIn: context)!

        // Widget.http.get(url, {headers}) -> Promise<{status, data, headers, arrayBuffer}>
        // headers：响应头全量（原样 key + 全小写 key 各一份，至少含 set-cookie）；
        // arrayBuffer：响应体原字节的 ArrayBuffer（16 MiB 以上或转换失败时该属性缺省，
        // data 照旧是 JSON 对象/数组或文本——data 不是二进制安全的，二进制请用 arrayBuffer）。
        // JS 调它时得到一个真 Promise；Swift 在后台发请求，完事回主线程 resolve/reject。
        // 注意：JSValue 的 block 用 @convention(block)，resolve/reject 必须在主线程调，
        // 所以这里只在 executor 里收下它们，真正的 resolve/reject 包在 MainActor.run 里。
        let httpGet: @convention(block) (String, JSValue?) -> JSValue = { [weak context] urlString, options in
            guard let context else {
                // JS 正在执行时 context 不可能已释放；这行理论上走不到。
                fatalError("WidgetHost: JSContext 已释放，无法发起请求")
            }
            return makeHttpGetPromise(in: context, urlString: urlString, options: options, interceptor: interceptor, httpRegistry: httpRegistry, nativePromiseConstructor: promiseStore.constructor, exceptionBox: exceptionBox)
        }
        http.setValue(httpGet, forProperty: "get")

        // Widget.http.post(url, body, {headers}) -> Promise<{status, data, headers, arrayBuffer}>
        // 回值形状与 get 相同（见上面 get 的注释）；POST 不套分类拦截器（拦截只改 WP 帖子 GET）。
        // body 一般是字符串（huangguo 现铸签名传 "{}"）；是对象时转 JSON。
        let httpPost: @convention(block) (String, JSValue?, JSValue?) -> JSValue = { [weak context] urlString, body, options in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放，无法发起请求")
            }
            return makeHttpPostPromise(in: context, urlString: urlString, body: body, options: options, httpRegistry: httpRegistry, nativePromiseConstructor: promiseStore.constructor, exceptionBox: exceptionBox)
        }
        http.setValue(httpPost, forProperty: "post")
        widget.setValue(http, forProperty: "http")

        // Widget.storage.get(key) / set(key, value)：同步，UserDefaults，按模块 id 隔离，
        // 前缀 fw.storage.<moduleId>.（P1-11：原来是固定前缀 fw.storage.，任何模块都能
        // 读写别家模块存的 token）。id 在装桥之前已预填（loadHost 传 SourceRecord.id，
        // 导入校验用临时命名空间），evaluateScript 之后再以 meta.id 为准校正一次；
        // 前缀不在安装时拼死——block 每次调用现算（盒子里的 id 可能被校正）。
        // 前缀末尾带 "."：clear() 按前缀枚举删键时，"user.pornjav" 不会误删 "user.pornjav2" 的键。
        // get 不存在返回 JS null（模块里 `if (raw)` 判空能正常工作）。
        let storagePrefix: () -> String = { "fw.storage." + moduleIDBox.id + "." }
        let localStoragePrefix: () -> String = { "fw.localstorage." + moduleIDBox.id + "." }
        let storageGet: @convention(block) (String) -> JSValue = { [weak context] key in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放")
            }
            if let value = UserDefaults.standard.string(forKey: storagePrefix() + key) {
                return JSValue(object: value, in: context)!
            }
            return JSValue(nullIn: context)!
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, value in
            UserDefaults.standard.set(value.toString(), forKey: storagePrefix() + key)
        }
        // Widget.storage.remove(key) / clear()：与 get/set 同一套按模块隔离的前缀。
        // clear 只清本模块 fw.storage.<moduleId>. 前缀的 key，不动 localStorage（前缀不同）、
        // 不动别家模块的 key、不动别的 key。
        let clearKeysWithPrefix: (String) -> Void = { prefix in
            let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let storageRemove: @convention(block) (String) -> Void = { key in
            UserDefaults.standard.removeObject(forKey: storagePrefix() + key)
        }
        let storageClear: @convention(block) () -> Void = {
            // P2-4：顶层求值期 id 还没定（空串）时不执行——空前缀
            // "fw.storage.." 会把别的模块顶层求值期落下的键一并清掉。
            // 正常加载已预填真 id、校验用临时命名空间，这行只是防卫。
            guard !moduleIDBox.id.isEmpty else { return }
            clearKeysWithPrefix(storagePrefix())
        }
        storage.setValue(storageGet, forProperty: "get")
        storage.setValue(storageSet, forProperty: "set")
        storage.setValue(storageRemove, forProperty: "remove")
        storage.setValue(storageClear, forProperty: "clear")
        widget.setValue(storage, forProperty: "storage")

        // localStorage：与 Widget.storage 同款持久化（UserDefaults），前缀分开
        //（fw.localstorage.<moduleId>.，与 fw.storage.<moduleId>. 互不干扰，也与别家模块互不干扰），值按字符串存。
        // getItem 不存在返回 JS null（与 Widget.storage.get 同款，模块里 `if (raw)` 判空能正常工作）。
        // 只实现 getItem/setItem/removeItem/clear（任务定的四件套）；length/key(index) 未实现。
        let localStorage = JSValue(newObjectIn: context)!
        let localStorageGetItem: @convention(block) (String) -> JSValue = { [weak context] key in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放")
            }
            if let value = UserDefaults.standard.string(forKey: localStoragePrefix() + key) {
                return JSValue(object: value, in: context)!
            }
            return JSValue(nullIn: context)!
        }
        let localStorageSetItem: @convention(block) (String, JSValue) -> Void = { key, value in
            UserDefaults.standard.set(value.toString(), forKey: localStoragePrefix() + key)
        }
        let localStorageRemoveItem: @convention(block) (String) -> Void = { key in
            UserDefaults.standard.removeObject(forKey: localStoragePrefix() + key)
        }
        let localStorageClear: @convention(block) () -> Void = {
            // P2-4：与 Widget.storage.clear 同款，id 为空时不执行。
            guard !moduleIDBox.id.isEmpty else { return }
            clearKeysWithPrefix(localStoragePrefix())
        }
        localStorage.setValue(localStorageGetItem, forProperty: "getItem")
        localStorage.setValue(localStorageSetItem, forProperty: "setItem")
        localStorage.setValue(localStorageRemoveItem, forProperty: "removeItem")
        localStorage.setValue(localStorageClear, forProperty: "clear")
        context.setObject(localStorage, forKeyedSubscript: "localStorage" as NSString)

        // console.log / info / debug / warn / error：多参数拼接（朋友演示同款：
        // Array.prototype.slice.call(arguments).map(String).join(' ')）。
        // 裸 JSC 的 Swift block 只能按固定签名接参，接不到“任意多个参数”，
        // 所以多参数拼接放在 JS 层做，Swift 只接拼好的一个字符串（__fwConsolePrint 内部桥）。
        // error 加 "[error] " 前缀（warn 同款 "[warn] "）；只在 DEBUG 下打印
        //（现有 #if DEBUG 保留；Release 下 JS 照调、Swift 不打印）。
        // 每个参数的 String(v) 单独 try/catch：String(Symbol) 会抛 TypeError，
        // 抛的那个参数记成 "[object Symbol]" 这类，不让一次 log 炸掉整个调用。
        let consoleSink: @convention(block) (String, String) -> Void = { level, message in
            #if DEBUG
            switch level {
            case "error": print("[JS] [error] \(message)")
            case "warn": print("[JS] [warn] \(message)")
            default: print("[JS] \(message)")
            }
            #endif
        }
        context.setObject(consoleSink as @convention(block) (String, String) -> Void, forKeyedSubscript: "__fwConsolePrint" as NSString)
        context.evaluateScript("""
            (function (g) {
                var joinArgs = function (args) {
                    return Array.prototype.slice.call(args).map(function (v) {
                        try { return String(v); } catch (e) { return Object.prototype.toString.call(v); }
                    }).join(' ');
                };
                var c = {};
                c.log = function () { g.__fwConsolePrint('log', joinArgs(arguments)); };
                c.info = function () { g.__fwConsolePrint('log', joinArgs(arguments)); };
                c.debug = function () { g.__fwConsolePrint('log', joinArgs(arguments)); };
                c.warn = function () { g.__fwConsolePrint('warn', joinArgs(arguments)); };
                c.error = function () { g.__fwConsolePrint('error', joinArgs(arguments)); };
                g.console = c;
            })(this);
            """)
        // 内部 eval 的异常也要清掉（同 URL 胶水那处）：console 安装脚本
        // 抛错时不留给模块求值，takeException 不会误算到模块头上。
        exceptionBox.message = nil

        // setTimeout / clearTimeout：裸 JavaScriptCore 没有这两个（浏览器才有），
        // 但模块里常用来做超时兜底（比如 onlybokep 封面补全的 8 秒封顶）；
        // 没有它模块调 setTimeout 会直接报 ReferenceError。补一个最小实现：
        // 主线程延时回调，返回一个数字 id 供 clearTimeout 取消。
        // 注意：回调里 JSContext 可能已释放，调之前先判空，不 crash。
        // 定时器状态不再放 installWidgetBridge 的局部变量（chunk-1 P1-6）：
        // 局部 timers/timerCounter 会让 DispatchWorkItem 强引用的 callback
        //（JSValue 强引用 context）把 context 永远钉住，setInterval 不清就永不释放，
        // host 释放后定时器还在主线程跑模块代码。改走 TimerRegistry
        //（与 HTTPRequestRegistry 同构，见文件末尾），deinit 时 cancelAll。
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak context] callback, delayMs in
            // delay 非数/没传时按 0 算（JS 调 setTimeout(fn) 不带延迟时 JSC 传过来的就是 NaN）。
            let delay = delayMs.isFinite ? delayMs : 0
            // 回调不直接进 work 闭包，装进 TimerCallbackBox：cancel 时盒子里的
            // callback 置 nil，GCD 队列里已取消的 work 到期前不再钉住 JSValue/JSContext。
            let callbackBox = TimerCallbackBox(callback)
            guard let registered = timerRegistry.register(callbackBox, { id in
                DispatchWorkItem {
                    timerRegistry.remove(id)
                    guard let context, let callback = callbackBox.callback,
                          !callback.isUndefined, !callback.isNull else { return }
                    callback.call(withArguments: [])
                    // P1-4c：回调抛的异常读完即清，不留给下一次调用。
                    if let message = exceptionBox.message, !message.isEmpty {
                        #if DEBUG
                        print("[WidgetHost] setTimeout 回调抛错：\(message)")
                        #endif
                        exceptionBox.message = nil
                    }
                }
            }) else {
                #if DEBUG
                print("[WidgetHost] setTimeout 已达上限（\(TimerRegistry.maxTimers) 个），本次调用忽略")
                #endif
                return 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0, execute: registered.work)
            return registered.id
        }
        let clearTimeout: @convention(block) (Int) -> Void = { id in
            timerRegistry.cancel(id)
        }
        context.setObject(setTimeout as @convention(block) (JSValue, Double) -> Int, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeout as @convention(block) (Int) -> Void, forKeyedSubscript: "clearTimeout" as NSString)

        // setInterval / clearInterval：与上面 setTimeout/clearTimeout 同款机制
        //（主线程延时回调、数字 id、DispatchWorkItem，共用同一个 TimerRegistry，
        // 所以 clearTimeout 也能停 interval、clearInterval 也能停 timeout，与浏览器一致）。
        // 每次 tick 都是一次新的 DispatchWorkItem：tick 触发时先看 id 是否还在表里
        //（clearInterval 已把它拿掉就不触发也不重排），回调完、id 还在表里才排下一次，
        // 所以回调里调 clearInterval（包括自己清自己）能停。delay 下限 4ms，
        // 免得 setInterval(fn, 0) 在主线程空转（浏览器同款钳制；setTimeout 不动，仍按 0 算）。
        let setInterval: @convention(block) (JSValue, Double) -> Int = { [weak context] callback, delayMs in
            // delay 非数/没传时按 4ms 算（JSC 传过来的 NaN 与 setTimeout 同款处理，只是下限不同）。
            let delay = delayMs.isFinite ? max(delayMs, 4) : 4
            guard let context else { return 0 }
            // 同 setTimeout：回调走 TimerCallbackBox，cancel 立即释放。
            let callbackBox = TimerCallbackBox(callback)
            guard let registered = timerRegistry.register(callbackBox, { id in
                Self.makeIntervalTickWork(id: id, delayMs: delay, callbackBox: callbackBox, context: context, timerRegistry: timerRegistry, exceptionBox: exceptionBox)
            }) else {
                #if DEBUG
                print("[WidgetHost] setInterval 已达上限（\(TimerRegistry.maxTimers) 个），本次调用忽略")
                #endif
                return 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0, execute: registered.work)
            return registered.id
        }
        let clearInterval: @convention(block) (Int) -> Void = { id in
            timerRegistry.cancel(id)
        }
        context.setObject(setInterval as @convention(block) (JSValue, Double) -> Int, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(clearInterval as @convention(block) (Int) -> Void, forKeyedSubscript: "clearInterval" as NSString)

        context.setObject(widget, forKeyedSubscript: "Widget" as NSString)

        // Widget.html（Cheerio DOM 解析，见 Core/WidgetHTML.js.txt）：
        // URL/URLSearchParams 在建桥时就装（模块可能在第一次调 html.load 之前就 new URL，
        // 懒装会让它 ReferenceError；Forward/Rex 里 URL 本来就是运行时自带的）。
        // 只有 cheerio bundle 留给 __fwEnsureCheerio 懒注入（382KB，第一次调 load/loadURL
        // 时才注入，约 30ms，之后常驻；不用的模块不付这个钱）。
        // bundle 是 Core/cheerio.min.js.txt（esbuild 打包的 cheerio 1.2.0，.txt 资源进包，不违反 0 .js 门禁）。
        // 解析走 Foundation URL（RFC 3986），JS 侧只负责拼对象与抛错。
        // 不提供 createObjectURL/revokeObjectURL（没有 blob URL 的概念）。
        let resolveURL: @convention(block) (String, String?) -> NSDictionary? = { urlString, baseString in
            // WHATWG 预处理：先全局删掉 ASCII tab/LF/CR（URL 内部的也删，不只首尾；
            // 脏 HTML 的多行 href 属性里常有换行，不删会被编成 %0A 导致 404），
            // 再去掉首尾 C0 控制字符与空格（U+0000–U+0020）。
            // 注意："\r\n" 在 Swift 里是单个字形簇（Character），Character.filter
            // 认不出它（既不等于 "\r" 也不等于 "\n"，会漏网）；这里按 Unicode 标量
            // 值过滤，"\r\n" 是两个标量，直接处理，不用先整体替换。
            let stripSet = CharacterSet(charactersIn: UnicodeScalar(0)...UnicodeScalar(0x20))
            let clean = { (s: String) -> String in
                let filtered = String(s.unicodeScalars.filter { $0.value != 0x09 && $0.value != 0x0A && $0.value != 0x0D })
                return filtered.trimmingCharacters(in: stripSet)
            }
            let trimmed = clean(urlString)
            let trimmedBase = baseString.map(clean)
            let base: URL? = trimmedBase.flatMap { URL(string: $0) }
            // 特殊协议集合（WHATWG 特殊 scheme，含 file）：空路径补 "/"。
            // file 是特殊协议但允许空 host，所以"必须有 host"另用一套集合。
            let specialSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]
            let schemesRequiringHost: Set<String> = ["http", "https", "ws", "wss", "ftp"]
            // base 传了但解析失败、或解析出来没有 scheme（Foundation 能建出无 scheme 的
            // 相对 URL，非 nil）→ 无效（WHATWG 会抛），不能悄悄当成没传 base。
            // 特殊协议的 base 还必须有 host（Foundation 能建出 "https:" 这种无 host 的，
            // WHATWG 不认；"http:///foo" 同理）。file 不要求 host。
            if baseString != nil {
                guard let b = base, b.scheme != nil else { return nil }
                if schemesRequiringHost.contains(b.scheme!.lowercased()), (b.host ?? "").isEmpty { return nil }
            }
            // 空串（或只剩空白）解析为 base 本身，但要剥掉 base 的 #fragment
            //（WHATWG：空引用指向 base 文档，不带 fragment）；没有 base 时无效。
            let resolved: URL?
            if trimmed.isEmpty {
                guard let base else { return nil }
                var comps = URLComponents(url: base, resolvingAgainstBaseURL: true)
                comps?.fragment = nil
                resolved = comps?.url ?? base
            } else {
                resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL
            }
            guard let resolved, resolved.scheme != nil else { return nil }
            let scheme = resolved.scheme!.lowercased()
            // host 小写（WHATWG 小写 host，Foundation 保留输入大小写）。
            // file: 的 localhost 规范化为空 host（WHATWG：file://localhost/path
            // 等同 file:///path；ChatGPT R6 P2-3）。
            var host = (resolved.host ?? "").lowercased()
            if scheme == "file" && host == "localhost" { host = "" }
            // 特殊协议必须有 host（"https:"、"http:///foo" 这种 Foundation 能建出来，
            // WHATWG 不认；不拦会产出 hostname:""、origin:"null" 的坏 URL）。file 除外。
            let special = specialSchemes.contains(scheme)
            if schemesRequiringHost.contains(scheme) && host.isEmpty { return nil }
            let port = resolved.port
            // file: URL 不能带端口和账号（WHATWG/Node：new URL('file://a:8080/x')、
            // new URL('file://user:pass@a.com/x') 都抛 Invalid URL；
            // 静默清掉会让 href 与 host/port 字段自相矛盾——ChatGPT R8 P2-1 / Gemini R8 P1；
            // 账号这一项是 Gemini R9 P2。这里直接拒绝，protocol setter 切到 file: 时也会
            // 因解析失败而忽略，符合 Node 行为）。
            if scheme == "file" && (port != nil || resolved.user != nil || resolved.password != nil) { return nil }
            let defaultPort: Int? = {
                switch scheme {
                case "http", "ws": return 80
                case "https", "wss": return 443
                case "ftp": return 21
                default: return nil
                }
            }()
            let effectivePort = (port != nil && port != defaultPort) ? String(port!) : ""
            // IPv6 host 拼端口要加方括号；Foundation 的 .host 可能去括号也可能带括号，
            // 两种都处理（已带括号的不重复加；不带括号但含冒号的加括号）。
            let formattedHost: String = {
                guard !host.isEmpty else { return "" }
                if host.hasPrefix("[") { return host }
                return host.contains(":") ? "[\(host)]" : host
            }()
            let hostWithPort = formattedHost.isEmpty ? "" : (effectivePort.isEmpty ? formattedHost : "\(formattedHost):\(effectivePort)")
            // file: 的 origin 恒为 opaque（"null"，WHATWG），即使有 host 也不例外。
            let origin = (special && scheme != "file" && !host.isEmpty) ? "\(scheme)://\(hostWithPort)" : "null"
            // href 归一化：把算好的值写回一份可变的 URLComponents 再序列化（上轮的 bug：
            // components 是 let 且一个值都没写回，components?.string 输出的是未归一化的
            // 原串——大写 host、默认端口、空路径都没修，href 与 origin/pathname 矛盾）。
            // 只改这几项：scheme 小写、host 小写、默认端口置 nil、特殊协议空路径补 "/"、
            // 空 query/fragment 置 nil（不然会序列化成 "?" / "#"）；其余字段原样保留。
            // URLComponents 建不出来就返回 nil（让 JS 侧抛 Invalid URL），不再静默
            // 回退到未归一化的 resolved.absoluteString（回退串与归一化字段打架）。
            guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { return nil }
            components.scheme = scheme
            if scheme == "file" {
                // file: host 规范化：localhost 已在 host 归一化里变 ""；host 为空时显式置 ""，
                // 保证序列化带 "//"（"file:/tmp/a" → "file:///tmp/a"；ChatGPT R7 P2-1）。
                // 用 "" 而不用 nil（nil 可能把 "//" 也丢掉，变成 "file:/path"）。
                // IPv6 仍走 encodedHost（带括号形式），host 是未编码属性、写裸 "::1" 会被
                // 百分号编码——ChatGPT R8 P2-2 / Gemini R8 P2-3。
                if host.contains(":") {
                    components.encodedHost = formattedHost
                } else {
                    components.host = host
                }
            } else if !host.isEmpty {
                if host.contains(":") {
                    // IPv6：用 encodedHost 写回（带括号形式 "[::1]"）。host 是未编码属性，
                    // 写 "[::1]" 会被 Foundation 按 reg-name 百分号编码成 %5B::1%5D，
                    // href 变成 "https://%5B::1%5D:8443/a"（Gemini R6 P0-2；ChatGPT
                    // 说它本机 host 写回能行，但 encodedHost 是文档化写法，两边都安全）。
                    components.encodedHost = formattedHost
                } else {
                    components.host = host
                }
            }
            // host 为空时不动 components.host（file:/// 的空 authority 要保留 "//"，
            // 置 nil 会把它丢掉，变成 "file:/path"）——file: 分支上面已显式置 ""。
            // file: 带端口已在前面直接拒绝（return nil），这里不用再特殊处理。
            components.port = (port != nil && port != defaultPort) ? port : nil
            // percentEncodedPath 是非可选 String（不像 query/fragment 是 String?），
            // 不能用 ?? 或 if let（R6 的 if let 编不过：Initializer for conditional
            // binding must have Optional type——Gemini R6 P0-1 抓到的硬编译错）。
            // 特殊协议的 path 必须以 / 开头（空 path 补 "/"；"file:foo" 这种 path 是 "foo" 的
            // 也补 "/" → "/foo"，不然 components.string 按 RFC 3986 §3.3 返回 nil，
            // 原本合法的 file:foo 会变成抛 Invalid URL——Gemini R8 P2-2）。
            if special && !components.percentEncodedPath.hasPrefix("/") {
                components.percentEncodedPath = "/" + components.percentEncodedPath
            }
            // special-query percent-encode set：单引号 ' 必须编成 %27（WHATWG；
            // Foundation 会把字面 ' 原样留在 percentEncodedQuery 里）。
            // 只替换字面 '（已编好的 %27 里没有字面 '，不会双重编码；&、= 等结构字符不动）。
            if special, var q = components.percentEncodedQuery, q.contains("'") {
                q = q.replacingOccurrences(of: "'", with: "%27")
                components.percentEncodedQuery = q
            }
            if (components.percentEncodedQuery ?? "").isEmpty { components.percentEncodedQuery = nil }
            if (components.percentEncodedFragment ?? "").isEmpty { components.percentEncodedFragment = nil }
            // pathname/search/hash 从归一化后的 components 读（与 href 同一套值，不再各读各的）。
            // percentEncodedPath 是非可选 String，直接读；query/fragment 是 String?，用 if let。
            let pathname: String = {
                let p = components.percentEncodedPath
                if !p.isEmpty { return p }
                return special ? "/" : ""
            }()
            let search: String = {
                if let q = components.percentEncodedQuery, !q.isEmpty { return "?" + q }
                return ""
            }()
            let hash: String = {
                if let f = components.percentEncodedFragment, !f.isEmpty { return "#" + f }
                return ""
            }()
            // components.string 建不出来也返回 nil（不再回退未归一化原串）。
            guard let href = components.string else { return nil }
            return [
                "href": href,
                "protocol": scheme.isEmpty ? "" : "\(scheme):",
                "host": hostWithPort,
                "hostname": formattedHost,
                "port": effectivePort,
                "pathname": pathname,
                "search": search,
                "hash": hash,
                "origin": origin,
            ] as NSDictionary
        }
        context.setObject(resolveURL as @convention(block) (String, String?) -> NSDictionary?, forKeyedSubscript: "__fwResolveURL" as NSString)
        // URL 构造器（最小版）：裸 JavaScriptCore 里没有 URL（它是 Web API，不是 JS 内置），
        // 但 cheerio 的 prop('href')/prop('src') 靠 new URL(s, baseURI).href 解析相对地址，
        // 没有它 prop 就静默返回相对地址（已在沙箱复现）。模块里 new URL(...) 也靠它。
        // 两个构造器各装各的（JSC 哪天自带了其中一个就用原生的，另一个照样补）。
        // searchParams 是活的：set/append/delete 后回写 URL 的 search 与 href（WHATWG 行为），
        // 否则模块 u.searchParams.set('page','2') 再拿 u.href 发请求会发旧地址。
                context.evaluateScript("""
            (function (g) {
                // form-urlencoded 编码：encodeURIComponent 保留 ! ' ( ) ~，但 URLSearchParams
                // 的序列化要把这 5 个也编成 %XX；空格编成 +。lone surrogate 先替成 U+FFFD
                //（标准算法；encodeURIComponent 遇到它会直接抛 URIError）。
                // 注意：这里用的两个正则都没有反斜杠（字符类里 ( ) 不用转义），
                // Swift 多行字符串里不会触发转义坑。
                var formEncode = function (s) {
                    s = String(s);
                    var clean = '';
                    for (var i = 0; i < s.length; i++) {
                        var c = s.charCodeAt(i);
                        if (c >= 0xD800 && c <= 0xDBFF) {
                            if (i + 1 < s.length) {
                                var d = s.charCodeAt(i + 1);
                                if (d >= 0xDC00 && d <= 0xDFFF) { clean += s.charAt(i) + s.charAt(i + 1); i++; continue; }
                            }
                            clean += String.fromCharCode(0xFFFD);
                        } else if (c >= 0xDC00 && c <= 0xDFFF) {
                            clean += String.fromCharCode(0xFFFD);
                        } else {
                            clean += s.charAt(i);
                        }
                    }
                    return encodeURIComponent(clean).replace(/[!'()~]/g, function (ch) {
                        return '%' + ch.charCodeAt(0).toString(16).toUpperCase();
                    }).replace(/%20/g, '+');
                };
                // 查询串解析（共用）：跳过空段（连续 && 不产空参数）；用 indexOf('=')，
                // 等号后的内容原样保留（含 =）。'+' 按空格解；解码失败保留原串不抛。
                // 查询串/片段拼进完整 URL 前的轻量编码（WHATWG query/fragment percent-encode set）。
                // 只编 ASCII 结构字符（#、空白、控制字符、"、<、>、'、反引号），非 ASCII 留给
                // Swift 侧按 UTF-8 编码。不能用 encodeURIComponent（它会把 &、= 等 query 结构
                // 字符也编了，还会把 %XX 双重编码）。无正则、无反斜杠（Swift 多行字符串转义坑）。
                var encodeQueryValue = function (s, isSpecial) {
                    var out = '';
                    for (var i = 0; i < s.length; i++) {
                        var c = s.charCodeAt(i);
                        // tab/LF/CR 直接删掉（WHATWG：URL 解析器删 tab/LF/CR；构造器经 Swift clean
                        // 也是删，不删会与构造器行为不一致——R6 是编成 %09/%0A/%0D，错）。
                        if (c === 0x09 || c === 0x0A || c === 0x0D) { continue; }
                        // ' 只在 special URL 里编成 %27（Swift 侧 special-only 规则；非 special
                        // 不编，不然与构造器不一致——ChatGPT R7 P2-4 / Gemini R7 P2）。
                        if (c === 0x27 && !isSpecial) { out += s.charAt(i); continue; }
                        if (c <= 0x20 || c === 0x22 || c === 0x23 || c === 0x3C || c === 0x3E || c === 0x27) {
                            out += '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
                        } else {
                            out += s.charAt(i);
                        }
                    }
                    return out;
                };
                var encodeFragmentValue = function (s) {
                    var out = '';
                    for (var i = 0; i < s.length; i++) {
                        var c = s.charCodeAt(i);
                        // tab/LF/CR 直接删掉（同 encodeQueryValue）。
                        if (c === 0x09 || c === 0x0A || c === 0x0D) { continue; }
                        if (c <= 0x20 || c === 0x22 || c === 0x3C || c === 0x3E || c === 0x60) {
                            out += '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
                        } else {
                            out += s.charAt(i);
                        }
                    }
                    return out;
                };
                // 路径编码器（pathname setter 用）：编 ?、#、控制字符、空格、"、<、>、反引号、反斜杠，
                // / 保留为路径分隔符（不能用 encodeURIComponent 整段编，会把 / 也编了）。
                // tab/LF/CR 直接删掉（同上）。
                var encodePathValue = function (s, isSpecial) {
                    var out = '';
                    for (var i = 0; i < s.length; i++) {
                        var c = s.charCodeAt(i);
                        if (c === 0x09 || c === 0x0A || c === 0x0D) { continue; }
                        // 反斜杠：special URL 里作路径分隔符（变 /）；非 special 编 %5C。
                        if (c === 0x5C) {
                            out += isSpecial ? '/' : '%5C';
                            continue;
                        }
                        // path percent-encode set：? # 控制字符 空格 " < > 反引号 ^ { }（ChatGPT R7 P2-2）。
                        if (c <= 0x20 || c === 0x7F || c === 0x22 || c === 0x23 || c === 0x3C || c === 0x3E || c === 0x3F || c === 0x5E || c === 0x60 || c === 0x7B || c === 0x7D) {
                            out += '%' + (c < 16 ? '0' : '') + c.toString(16).toUpperCase();
                        } else {
                            out += s.charAt(i);
                        }
                    }
                    return out;
                };
                // 特殊协议集合（与 Swift 侧 specialSchemes 一致，含 file）。
                var isSpecialScheme = function (scheme) {
                    var s = String(scheme).toLowerCase();
                    if (s.charAt(s.length - 1) === ':') { s = s.slice(0, -1); }
                    return s === 'http' || s === 'https' || s === 'ws' || s === 'wss' || s === 'ftp' || s === 'file';
                };
                // 全 ASCII 数字校验（port setter 用：parseInt 会接受 '8080junk' 这种尾随字符）。
                var isAllDigits = function (s) {
                    if (!s) { return false; }
                    for (var i = 0; i < s.length; i++) {
                        var c = s.charCodeAt(i);
                        if (c < 0x30 || c > 0x39) { return false; }
                    }
                    return true;
                };
                var parseQuery = function (str, pairs) {
                    if (str.charAt(0) === '?') { str = str.slice(1); }
                    if (!str) { return; }
                    var decode = function (s) {
                        var spaced = s.split('+').join(' ');
                        try { return decodeURIComponent(spaced); } catch (e) { return spaced; }
                    };
                    var parts = str.split('&');
                    for (var i = 0; i < parts.length; i++) {
                        if (parts[i] === '') { continue; }
                        var eq = parts[i].indexOf('=');
                        var k = eq < 0 ? parts[i] : parts[i].slice(0, eq);
                        var v = eq < 0 ? '' : parts[i].slice(eq + 1);
                        pairs.push([decode(k), decode(v)]);
                    }
                };
                // 最小 URLSearchParams。
                // 构造器先定义成本地变量，再按需挂到全局——这样 URL 内部永远用自己这份，
                // 不依赖全局是不是原生实现。
                // _pairs/_onChange 用 defineProperty 设成不可枚举（模块 for..in / Object.keys
                // 不该看到它们；new URLSearchParams(sp) 时也不会把它们当成 query key）。
                // 公开构造器不收 onChange 参数（URL 构造器在内部给 searchParams 赋值
                // sp._onChange = onQueryChange，避免内部回调暴露在公开 API 上）。
                // init 识别：字符串 → parseQuery；同款实例 → instanceof 拷 pairs；
                // 数组 → [k, v] 对；Map / 原生 URLSearchParams / 其他可迭代 → Symbol.iterator；
                // 普通对象 → 自有可枚举 key（旧代码的 init._pairs 鸭子类型会误判普通对象，
                // { _pairs: "abc" } 会被拆成 a=undefined&b=undefined&c=undefined，已删）。
                // 把 pair 统一转成 [k, v]（数组直接接受；非数组要求可迭代且恰好两个值；
                // 单纯有 length 和数字属性的 array-like（如 {0:'a',1:'b',length:2}）拒绝——
                // WHATWG 要求 pair 是可迭代的二元序列）。
                var toPair = function (pair) {
                    if (Array.isArray(pair)) {
                        if (pair.length !== 2) {
                            throw new TypeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.");
                        }
                        return [String(pair[0]), String(pair[1])];
                    }
                    if (pair && typeof Symbol !== 'undefined' && Symbol.iterator && typeof pair[Symbol.iterator] === 'function') {
                        var it = pair[Symbol.iterator]();
                        var first = it.next();
                        if (first.done) {
                            throw new TypeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.");
                        }
                        var second = it.next();
                        if (second.done) {
                            throw new TypeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.");
                        }
                        var third = it.next();
                        if (!third.done) {
                            throw new TypeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.");
                        }
                        return [String(first.value), String(second.value)];
                    }
                    throw new TypeError("Failed to construct 'URLSearchParams': The provided value cannot be converted to a sequence.");
                };
                var URLSearchParamsCtor = function (init) {
                    if (!(this instanceof URLSearchParamsCtor)) {
                        throw new TypeError("Failed to construct 'URLSearchParams': Please use the 'new' operator");
                    }
                    Object.defineProperty(this, '_pairs', { value: [], writable: true, enumerable: false, configurable: true });
                    Object.defineProperty(this, '_onChange', { value: null, writable: true, enumerable: false, configurable: true });
                    if (typeof init === 'string') {
                        parseQuery(init, this._pairs);
                    } else if (init && typeof init === 'object') {
                        if (init instanceof URLSearchParamsCtor) {
                            for (var a = 0; a < init._pairs.length; a++) {
                                this._pairs.push([init._pairs[a][0], init._pairs[a][1]]);
                            }
                        } else if (Array.isArray(init)) {
                            for (var b = 0; b < init.length; b++) {
                                this._pairs.push(toPair(init[b]));
                            }
                        } else if (typeof Symbol !== 'undefined' && Symbol.iterator && typeof init[Symbol.iterator] === 'function') {
                            var it = init[Symbol.iterator]();
                            var step;
                            while (!(step = it.next()).done) {
                                this._pairs.push(toPair(step.value));
                            }
                        } else {
                            for (var key in init) {
                                if (Object.prototype.hasOwnProperty.call(init, key)) {
                                    this._pairs.push([key, String(init[key])]);
                                }
                            }
                        }
                    } else if (init !== undefined && init !== null) {
                        // 原始值（数字、布尔等）：String(init) 再按查询串解析（123 → "123="）。
                        parseQuery(String(init), this._pairs);
                    }
                };
                URLSearchParamsCtor.prototype.get = function (name) {
                    name = String(name);
                    for (var i = 0; i < this._pairs.length; i++) {
                        if (this._pairs[i][0] === name) { return this._pairs[i][1]; }
                    }
                    return null;
                };
                URLSearchParamsCtor.prototype.getAll = function (name) {
                    name = String(name);
                    var out = [];
                    for (var i = 0; i < this._pairs.length; i++) {
                        if (this._pairs[i][0] === name) { out.push(this._pairs[i][1]); }
                    }
                    return out;
                };
                URLSearchParamsCtor.prototype.has = function (name) {
                    return this.get(name) !== null;
                };
                URLSearchParamsCtor.prototype.set = function (name, value) {
                    name = String(name);
                    value = String(value);
                    var kept = [];
                    var found = false;
                    for (var i = 0; i < this._pairs.length; i++) {
                        if (this._pairs[i][0] === name) {
                            if (!found) { kept.push([name, value]); found = true; }
                        } else {
                            kept.push(this._pairs[i]);
                        }
                    }
                    if (!found) { kept.push([name, value]); }
                    this._pairs = kept;
                    if (this._onChange) { this._onChange(this.toString()); }
                };
                URLSearchParamsCtor.prototype.append = function (name, value) {
                    this._pairs.push([String(name), String(value)]);
                    if (this._onChange) { this._onChange(this.toString()); }
                };
                URLSearchParamsCtor.prototype.delete = function (name) {
                    name = String(name);
                    var kept = [];
                    for (var i = 0; i < this._pairs.length; i++) {
                        if (this._pairs[i][0] !== name) { kept.push(this._pairs[i]); }
                    }
                    this._pairs = kept;
                    if (this._onChange) { this._onChange(this.toString()); }
                };
                URLSearchParamsCtor.prototype.toString = function () {
                    var out = [];
                    for (var i = 0; i < this._pairs.length; i++) {
                        out.push(formEncode(this._pairs[i][0]) + '=' + formEncode(this._pairs[i][1]));
                    }
                    return out.join('&');
                };
                // forEach/keys/values/entries/sort：见下面 toIter 与 sort 的说明。
                URLSearchParamsCtor.prototype.forEach = function (cb, thisArg) {
                    for (var i = 0; i < this._pairs.length; i++) {
                        cb.call(thisArg, this._pairs[i][1], this._pairs[i][0], this);
                    }
                };
                // forEach/keys/values/entries：返回迭代器（数组的 Symbol.iterator 自带
                // .next()，for..of、[...]、Array.from()、.next() 都能用；返回的是快照，
                // 之后改 _pairs 不影响它）。entries 深拷贝内层 [k, v]，外部改 entry[1]
                // 不会篡改 _pairs。sort 按 key 排序（稳定排序），改完触发 _onChange。
                var toIter = function (arr) {
                    if (typeof Symbol !== 'undefined' && Symbol.iterator && typeof arr[Symbol.iterator] === 'function') {
                        return arr[Symbol.iterator]();
                    }
                    return arr;
                };
                URLSearchParamsCtor.prototype.keys = function () {
                    var out = [];
                    for (var i = 0; i < this._pairs.length; i++) { out.push(this._pairs[i][0]); }
                    return toIter(out);
                };
                URLSearchParamsCtor.prototype.values = function () {
                    var out = [];
                    for (var i = 0; i < this._pairs.length; i++) { out.push(this._pairs[i][1]); }
                    return toIter(out);
                };
                URLSearchParamsCtor.prototype.entries = function () {
                    var out = [];
                    for (var i = 0; i < this._pairs.length; i++) {
                        out.push([this._pairs[i][0], this._pairs[i][1]]);
                    }
                    return toIter(out);
                };
                URLSearchParamsCtor.prototype.sort = function () {
                    var sorted = this._pairs.slice();
                    sorted.sort(function (a, b) {
                        if (a[0] < b[0]) { return -1; }
                        if (a[0] > b[0]) { return 1; }
                        return 0;
                    });
                    this._pairs = sorted;
                    if (this._onChange) { this._onChange(this.toString()); }
                };
                if (typeof Symbol !== 'undefined' && Symbol.iterator) {
                    URLSearchParamsCtor.prototype[Symbol.iterator] = function () {
                        return this.entries();
                    };
                }
                if (typeof g.URLSearchParams !== 'function') { g.URLSearchParams = URLSearchParamsCtor; }
                if (typeof g.URL !== 'function') {
                    var URLCtor = function (url, base) {
                        if (!(this instanceof URLCtor)) {
                            throw new TypeError("Failed to construct 'URL': Please use the 'new' operator");
                        }
                        // base 只有 undefined 算省略；null 要透传成 "null"（WHATWG 里 null 不是省略，
                        // Swift 侧解析失败会返回 nil，这里抛 Invalid URL）。
                        var parts = g.__fwResolveURL(String(url), base === undefined ? null : String(base));
                        if (!parts) { throw new TypeError('Invalid URL'); }
                        var self = this;
                        // 闭包里维护唯一真相：_prefix（search 之前的部分）、_search、_hash、_href，
                        // 再加 _protocol/_host/_hostname/_port/_pathname/_origin/_protoAuth
                        //（scheme + authority 部分）。公开的 protocol/host/hostname/port/
                        // pathname/origin/href/search/hash 全走 defineProperty 读写这份状态，
                        // 不再用可变的 this.xxx 反推（上轮的 bug：先改 hash 再改 searchParams，
                        // prefix 切片会用变长的 hash 截断 pathname；先改 href 再改 searchParams
                        // 会把 href 回滚回旧值；pathname 等字段是普通属性，改完不同步 _href/_prefix，
                        // 下次改 search 会把它静默覆盖回旧路径）。
                        var _prefix = parts.href.slice(0, parts.href.length - parts.search.length - parts.hash.length);
                        var _search = parts.search;
                        var _hash = parts.hash;
                        var _href = parts.href;
                        var _protocol = parts.protocol;
                        var _host = parts.host;
                        var _hostname = parts.hostname;
                        var _port = parts.port;
                        var _pathname = parts.pathname;
                        var _origin = parts.origin;
                        // _protoAuth = href 去掉 pathname/search/hash（即 scheme + authority）。
                        var _protoAuth = parts.href.slice(0, parts.href.length - parts.pathname.length - parts.search.length - parts.hash.length);
                        // 从 parts 重建全部状态（所有 setter 共用：先拼候选串，再调 __fwResolveURL
                        // 重解析，让 Swift 侧做归一化与编码；searchParams 原地重建，不换对象，
                        // 模块手里的引用不断）。
                        var applyParts = function (p) {
                            _prefix = p.href.slice(0, p.href.length - p.search.length - p.hash.length);
                            _search = p.search;
                            _hash = p.hash;
                            _href = p.href;
                            _protocol = p.protocol;
                            _host = p.host;
                            _hostname = p.hostname;
                            _port = p.port;
                            _pathname = p.pathname;
                            _origin = p.origin;
                            _protoAuth = p.href.slice(0, p.href.length - p.pathname.length - p.search.length - p.hash.length);
                            self.searchParams._pairs.length = 0;
                            parseQuery(p.search, self.searchParams._pairs);
                        };
                        // searchParams 改动后回写：只换查询串，path 与 fragment 原样保留
                        //（_href = _prefix + 新 search + _hash；query 已由 formEncode 编过，
                        // 没有空格/#，直接拼是安全的）。
                        var onQueryChange = function (query) {
                            var newSearch = query ? '?' + query : '';
                            _search = newSearch;
                            _href = _prefix + _search + _hash;
                        };
                        this.searchParams = new URLSearchParamsCtor(parts.search);
                        this.searchParams._onChange = onQueryChange;
                        // 用新的 host[:port] 替换 _protoAuth 里的 host 部分，保留 userinfo
                        //（_protoAuth 含 user:pass@，直接拼 _protocol + '//' + newHost 会丢掉它——
                        // ChatGPT R7 P2-3 / Gemini R7 P1-3）。
                        var protoAuthWithHost = function (newHostPort) {
                            var auth = _protoAuth;
                            var schemeEnd = auth.indexOf('://');
                            if (schemeEnd < 0) { return _protocol + '//' + newHostPort; }
                            var afterScheme = auth.slice(schemeEnd + 3);
                            var atIdx = afterScheme.indexOf('@');
                            if (atIdx >= 0) {
                                return auth.slice(0, schemeEnd + 3) + afterScheme.slice(0, atIdx + 1) + newHostPort;
                            }
                            return _protocol + '//' + newHostPort;
                        };
                        // protocol/host/hostname/port/pathname：defineProperty 读写闭包状态，
                        // setter 拼候选串重解析 + applyParts 全量同步。origin 只读（WHATWG）。
                        // 全部 setter 按 WHATWG 不抛错：解析失败保持原值（构造器仍抛 Invalid URL）。
                        Object.defineProperty(this, 'protocol', {
                            get: function () { return _protocol; },
                            set: function (v) {
                                var newProto = String(v);
                                if (newProto.charAt(newProto.length - 1) !== ':') { newProto += ':'; }
                                // WHATWG：不允许在特殊与非特殊协议之间切换（https: → foo: 拒绝）。
                                if (isSpecialScheme(_protocol) !== isSpecialScheme(newProto)) { return; }
                                // 切到 file: 时，当前 URL 不能带端口或账号（file: URL 没有端口和 userinfo；
                                // Node：http://a:8080/x 切 file: 后 href 不变——ChatGPT R8 P2-3）。
                                if (newProto.toLowerCase() === 'file:') {
                                    if (_port) { return; }
                                    if (_protoAuth.indexOf('@') >= 0) { return; }
                                }
                                var p = g.__fwResolveURL(newProto + _protoAuth.slice(_protocol.length) + _pathname + _search + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'host', {
                            get: function () { return _host; },
                            set: function (v) {
                                // 无 authority 的 URL（如 mailto:）不能设 host，直接忽略。
                                if (_protoAuth.indexOf('://') < 0) { return; }
                                var newHost = String(v);
                                // 含 /、?、#、反斜杠、空白、@ 的输入会注入并改 pathname/query/fragment，
                                // 拒绝（host setter 只改 host，不顺便改别的组件）。
                                for (var i = 0; i < newHost.length; i++) {
                                    var c = newHost.charCodeAt(i);
                                    if (c <= 0x20 || c === 0x2F || c === 0x3F || c === 0x23 || c === 0x40 || c === 0x5C) { return; }
                                }
                                var p = g.__fwResolveURL(protoAuthWithHost(newHost) + _pathname + _search + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'hostname', {
                            get: function () { return _hostname; },
                            set: function (v) {
                                if (_protoAuth.indexOf('://') < 0) { return; }
                                var newHostname = String(v);
                                // 含 /、?、#、反斜杠、空白、@ 的输入拒绝（同 host setter）。
                                // 冒号只允许出现在 bracketed IPv6 里（[::1]），裸冒号 + 别的字符拒绝。
                                if (newHostname.charAt(0) === '[') {
                                    if (newHostname.charAt(newHostname.length - 1) !== ']') { return; }
                                    for (var j = 0; j < newHostname.length; j++) {
                                        var cj = newHostname.charCodeAt(j);
                                        if (cj <= 0x20 || cj === 0x2F || cj === 0x3F || cj === 0x23 || cj === 0x40 || cj === 0x5C) { return; }
                                    }
                                } else {
                                    for (var i = 0; i < newHostname.length; i++) {
                                        var c = newHostname.charCodeAt(i);
                                        if (c <= 0x20 || c === 0x2F || c === 0x3F || c === 0x23 || c === 0x40 || c === 0x5C || c === 0x3A) { return; }
                                    }
                                }
                                var portPart = _port ? ':' + _port : '';
                                var p = g.__fwResolveURL(protoAuthWithHost(newHostname + portPart) + _pathname + _search + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'port', {
                            get: function () { return _port; },
                            set: function (v) {
                                // 无 authority、file:、或空 host 的 URL 不能设端口（foo:///x 设 port 会
                                // 拼出 foo://:8080/x——ChatGPT R8 P2-4 / Gemini R8 P2-4）。
                                if (_protoAuth.indexOf('://') < 0 || _protocol === 'file:' || !_hostname) { return; }
                                var newPort = String(v);
                                var portPart = '';
                                if (newPort !== '') {
                                    // 全是 ASCII 数字才接受（parseInt 会接受 '8080junk'、'80.5' 这种尾随字符）。
                                    if (!isAllDigits(newPort)) { return; }
                                    var n = parseInt(newPort, 10);
                                    if (isNaN(n) || n < 0 || n > 65535) { return; }
                                    portPart = ':' + n;
                                }
                                var p = g.__fwResolveURL(protoAuthWithHost(_hostname + portPart) + _pathname + _search + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'pathname', {
                            get: function () { return _pathname; },
                            set: function (v) {
                                // 先按 path percent-encode set 编码（?、#、空格等编掉，不能让它们
                                // 在拼串后被解析器当成 query/fragment 起点，破坏原 search/hash）。
                                var newPath = encodePathValue(String(v), isSpecialScheme(_protocol));
                                // 有 authority 的 URL 且新 path 非空、不以 / 开头时补一个 /，
                                // 不然 _protoAuth + newPath 会拼成另一个 host。
                                if (_protoAuth.indexOf('://') >= 0 && newPath !== '' && newPath.charAt(0) !== '/') {
                                    newPath = '/' + newPath;
                                }
                                var p = g.__fwResolveURL(_protoAuth + newPath + _search + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'origin', {
                            get: function () { return _origin; },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'href', {
                            get: function () { return _href; },
                            set: function (v) {
                                var p = g.__fwResolveURL(String(v), null);
                                // WHATWG：只有 href setter 在解析失败时抛 TypeError，
                                // 其他组件 setter（protocol/host/hostname/port/pathname/search/hash）
                                // 都是静默忽略。R6 把 href 的 throw 一并去掉了，是错的，恢复。
                                if (!p) { throw new TypeError('Invalid URL'); }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'search', {
                            get: function () { return _search; },
                            set: function (v) {
                                // String(v) 直转：null → "null"（WHATWG 字符串化语义），
                                // 不再特殊处理成空串（上轮 u.search = null 会错误清空 query）。
                                // 先按 query percent-encode set 编码输入（# 编成 %23，不能让它
                                // 在拼串后被解析器当成 fragment 起点；尾随空格也编掉，不然 Swift
                                // 侧 clean 会把它静默裁掉），再拼候选串重解析。
                                var s = String(v);
                                if (s.charAt(0) === '?') { s = s.slice(1); }
                                s = encodeQueryValue(s, isSpecialScheme(_protocol));
                                var p = g.__fwResolveURL(_prefix + (s ? '?' + s : '') + _hash, null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                        Object.defineProperty(this, 'hash', {
                            get: function () { return _hash; },
                            set: function (v) {
                                var h = String(v);
                                if (h.charAt(0) === '#') { h = h.slice(1); }
                                h = encodeFragmentValue(h);
                                var p = g.__fwResolveURL(_prefix + _search + (h ? '#' + h : ''), null);
                                if (!p) { return; }
                                applyParts(p);
                            },
                            enumerable: true,
                            configurable: true
                        });
                    };
                    URLCtor.prototype.toString = function () { return this.href; };
                    URLCtor.prototype.toJSON = function () { return this.href; };
                    g.URL = URLCtor;
                }
            })(this);
            """)
        // 内部 eval 的异常也要清掉盒子里的那份（同胶水那处）。
        exceptionBox.message = nil

        // __fwEnsureCheerio：懒注入 cheerio bundle + atob（第一次调 load/loadURL 时
        // 才注入，约 30ms，之后常驻；不用的模块不付这个钱）。
        // bundle 是 Core/cheerio.min.js.txt（esbuild 打包的 cheerio 1.2.0，.txt 资源进包，不违反 0 .js 门禁）。
        // 注意：bundle 加载时就要 atob（它内置的 base64 解码守卫是 typeof Buffer.from，
        // Buffer 不存在时直接抛 ReferenceError——已在沙箱复现）；裸 JSC 不一定有 atob，
        // 缺时先注入一个最小 atob polyfill（与 round30-pack 的 harness 里测过的逐字一致）。
        // 读不到 bundle 或注入后 global 仍缺失时返回 false，load() 那边抛一个清楚的错，
        // 不连累整个桥（桥在 build 时继续建，模块调 html.load 才报错）。
        let ensureCheerio: @convention(block) () -> Bool = { [weak context] in
            guard let context else { return false }
            if let fn = context.objectForKeyedSubscript("__fwCheerioLoad"), !fn.isUndefined, !fn.isNull {
                return true
            }
            if context.evaluateScript("typeof atob")?.toString() != "function" {
                context.evaluateScript("""
                    (function (g) {
                        if (typeof g.atob === 'function') { return; }
                        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
                        var map = {};
                        for (var i = 0; i < chars.length; i++) { map[chars.charAt(i)] = i; }
                        g.atob = function (input) {
                            var str = String(input);
                            var bad = function () {
                                var err = new Error('InvalidCharacterError: The string to be decoded is not correctly encoded.');
                                err.name = 'InvalidCharacterError';
                                throw err;
                            };
                            // 只许 Base64 字符与 ASCII 空白；非法字符直接抛错（原生 atob 抛
                            // InvalidCharacterError），不悄悄删掉——损坏数据不能变成看似有效的数据。
                            // 注意：这里故意不用正则写空白转义（Swift 多行字符串里反斜杠要双写，
                            // 容易错），改用 charCode 比较，JS 文本里一个反斜杠也没有。
                            var clean = '';
                            for (var j = 0; j < str.length; j++) {
                                var ch = str.charAt(j);
                                var code = str.charCodeAt(j);
                                if (code === 32 || code === 9 || code === 10 || code === 12 || code === 13) { continue; }
                                if (map[ch] === undefined && ch !== '=') { bad(); }
                                clean += ch;
                            }
                            // 结构：长度是 4 的倍数；'=' 只许在末尾，最多两个。
                            if (clean.length % 4 !== 0) { bad(); }
                            var eq = 0;
                            for (var k = clean.length - 1; k >= 0 && clean.charAt(k) === '='; k--) { eq++; }
                            if (eq > 2) { bad(); }
                            if (clean.indexOf('=') !== -1 && clean.indexOf('=') < clean.length - eq) { bad(); }
                            var out = '';
                            var i = 0;
                            while (i < clean.length) {
                                var e1 = map[clean.charAt(i++)];
                                var e2 = map[clean.charAt(i++)];
                                var e3 = map[clean.charAt(i++)];
                                var e4 = map[clean.charAt(i++)];
                                if (e1 === undefined || e2 === undefined) { break; }
                                var c1 = (e1 << 2) | (e2 >> 4);
                                out += String.fromCharCode(c1);
                                if (e3 !== undefined) {
                                    var c2 = ((e2 & 15) << 4) | (e3 >> 2);
                                    out += String.fromCharCode(c2);
                                    if (e4 !== undefined) {
                                        var c3 = ((e3 & 3) << 6) | e4;
                                        out += String.fromCharCode(c3);
                                    }
                                }
                            }
                            return out;
                        };
                    })(this);
                    """)
                // atob 注入的异常也要清掉（同胶水那处：不然 takeException 会误算到模块头上）。
                exceptionBox.message = nil
            }
            guard let bundle = Self.cheerioBundle else { return false }
            // withSourceURL 让堆栈里有文件名（否则 bundle 抛错时只剩匿名脚本）。
            context.evaluateScript(bundle, withSourceURL: URL(string: "host://cheerio.min.js.txt"))
            // bundle 抛错就直接清掉异常返回 false，不要继续检查 __fwCheerioLoad
            //（上轮的隐患：万一 __fwCheerioLoad 残留着旧值，会把失败当成功）。
            if let message = exceptionBox.message, !message.isEmpty {
                exceptionBox.message = nil
                return false
            }
            guard let fn = context.objectForKeyedSubscript("__fwCheerioLoad"), !fn.isUndefined, !fn.isNull else {
                // 注入失败的诊断：bundle 解析错与资源缺失走同一条 false 路，DEBUG 下把
                // JS 侧的异常打出来区分（不影响返回值；异常读完就清掉，别让它留着污染后事）。
                #if DEBUG
                if let message = exceptionBox.message, !message.isEmpty {
                    print("[WidgetHost] cheerio bundle 注入失败：\(message)")
                }
                #endif
                exceptionBox.message = nil
                return false
            }
            // 成功也清掉（防之前的 eval 留了 stale 异常，误算到后事头上）。
            exceptionBox.message = nil
            return true
        }
        context.setObject(ensureCheerio as @convention(block) () -> Bool, forKeyedSubscript: "__fwEnsureCheerio" as NSString)

        // Widget.html 的胶水（load/loadURL/护栏）在 Core/WidgetHTML.js.txt 里：
        // 读不到就跳过——模块调 Widget.html.load 时再报“不可用”，不连累整个桥。
        // 必须在 Widget 对象挂上之后再评（胶水里写 g.Widget.html = ...）。
        // withSourceURL 让堆栈里有文件名；胶水抛错时 DEBUG 下打出来并清掉异常。
        if let glue = Self.widgetHTMLGlue {
            context.evaluateScript(glue, withSourceURL: URL(string: "host://WidgetHTML.js.txt"))
            #if DEBUG
            if let message = exceptionBox.message, !message.isEmpty {
                print("[WidgetHost] WidgetHTML 胶水注入失败：\(message)")
            }
            #endif
            // 内部 eval 的异常也要清掉盒子里的那份：exceptionHandler 会把胶水脚本的
            // 异常也写进 box.message，不清的话 build() 会把它误算到模块源码头上
            //（模块源码还没跑就被拒绝加载）。模块源码的异常由 build() 自己读盒子。
            exceptionBox.message = nil
        }

        // Widget.crypto（原生解密/编解码，二进制桥，见 Core/WidgetCrypto.swift +
        // Core/WidgetCrypto.js.txt）：在 installWidgetBridge 末尾挂一次注册，不碰现有
        // Widget.*。原语挂全局 __fwCrypto*，胶水组装 Widget.crypto.*。读不到胶水时
        // install 内部跳过，模块调 Widget.crypto 时再报"不可用"，不连累整个桥。
        WidgetCrypto.install(into: context)
        #if DEBUG
        if let message = exceptionBox.message, !message.isEmpty {
            print("[WidgetHost] WidgetCrypto 胶水注入失败：\(message)")
        }
        #endif
        exceptionBox.message = nil

        // __fwArrayBufferFromBytes（内部助手，Widget.http 回值 .arrayBuffer 用）：
        // JS 数字数组（0–255）→ ArrayBuffer。只在 Swift 侧的 jsArrayBuffer 里调，模块不用直接调它。
        context.evaluateScript("""
            (function (g) {
                g.__fwArrayBufferFromBytes = function (bytes) { return new Uint8Array(bytes).buffer; };
            })(this);
            """)

        // fetch(url, options?) -> Promise<{ok, status, headers, text(), json(), arrayBuffer()}>
        // 最小实现：Widget.http.get/post 的 Promise 包装，不另起网络栈。
        // options 支持 {method, headers, body}：headers 可以是对象或 [key, value] 对数组；
        // body 原样交给 Widget.http.post（字符串直接发，对象转 JSON，与 httpBodyData 同款）。
        // 只支持 GET/POST（Widget.http 只有这两条），别的 method 直接 reject，不假装支持。
        // text()：data 是字符串就原样返回，是对象就 JSON.stringify；json()：data 是对象就原样返回，
        // 是字符串就 JSON.parse（解析失败 reject）。headers 是普通对象，另带 get(name)/has(name)
        //（大小写不敏感查）。url 只支持绝对地址（与 Widget.http 同款，无 base URL 概念）。
        context.evaluateScript("""
            (function (g) {
                var normalizeHeaders = function (headers) {
                    var out = {};
                    if (!headers) { return out; }
                    if (Array.isArray(headers)) {
                        headers.forEach(function (pair) {
                            if (pair && pair.length >= 2) { out[String(pair[0])] = String(pair[1]); }
                        });
                        return out;
                    }
                    if (typeof headers === 'object') {
                        Object.keys(headers).forEach(function (k) { out[k] = String(headers[k]); });
                    }
                    return out;
                };
                var makeHeaders = function (plain) {
                    var h = {};
                    if (plain && typeof plain === 'object') {
                        Object.keys(plain).forEach(function (k) { h[k] = plain[k]; });
                    }
                    h.get = function (name) {
                        var want = String(name).toLowerCase();
                        var keys = Object.keys(h);
                        for (var i = 0; i < keys.length; i++) {
                            if (keys[i] === 'get' || keys[i] === 'has') { continue; }
                            if (keys[i].toLowerCase() === want) { return h[keys[i]]; }
                        }
                        return null;
                    };
                    h.has = function (name) { return h.get(name) !== null; };
                    return h;
                };
                g.fetch = function (url, options) {
                    options = options || {};
                    var method = String(options.method || 'GET').toUpperCase();
                    var headers = normalizeHeaders(options.headers);
                    var requestURL = (url && typeof url === 'object' && url.url) ? String(url.url) : String(url);
                    var reqOpts = { headers: headers };
                    if (options.timeout !== undefined && options.timeout !== null) {
                        reqOpts.timeout = options.timeout;
                    }
                    var httpCall;
                    if (method === 'GET') {
                        httpCall = Widget.http.get(requestURL, reqOpts);
                    } else if (method === 'POST') {
                        httpCall = Widget.http.post(requestURL, options.body, reqOpts);
                    } else {
                        return Promise.reject(new Error('fetch: 只支持 GET/POST，暂不支持 ' + method));
                    }
                    return httpCall.then(function (res) {
                        var data = res.data;
                        var textValue = (typeof data === 'string') ? data : JSON.stringify(data);
                        return {
                            ok: res.status >= 200 && res.status < 300,
                            status: res.status,
                            headers: makeHeaders(res.headers),
                            url: (res.finalUrl ? res.finalUrl : requestURL),
                            text: function () { return Promise.resolve(textValue); },
                            json: function () {
                                try {
                                    return Promise.resolve((data !== null && typeof data === 'object') ? data : JSON.parse(textValue));
                                } catch (e) {
                                    return Promise.reject(e);
                                }
                            },
                            arrayBuffer: function () { return Promise.resolve(res.arrayBuffer); }
                        };
                    });
                };
            })(this);
            """)
        // 内部 eval 的异常也要清掉（同 console 安装那处）：fetch 与
        // __fwArrayBufferFromBytes 两段安装脚本的异常不留给模块求值。
        exceptionBox.message = nil
    }

    /// setInterval 一个 tick 的 work（P1-1）：静态方法，不捕获可变 var，
    /// 不与 setInterval 的 block 相互强捕获。work 闭包只弱持 context
    ///（[weak context]，context 释放后 tick 自停）；callback 装在
    /// TimerCallbackBox 里（盒子强持着 JS 函数才不会被 GC 收掉，cancel 时
    /// 盒子里的 callback 置 nil 立即释放），tick 触发时再从盒子里取。
    /// tick 触发时先看 id 是否还在表里（clearInterval 已把它拿掉就不触发
    /// 也不重排），回调完、id 还在表里才经 scheduleIntervalTick 排下一次，
    /// 所以回调里调 clearInterval（包括自己清自己）能停。
    private static func makeIntervalTickWork(id: Int, delayMs: Double, callbackBox: TimerCallbackBox, context: JSContext, timerRegistry: TimerRegistry, exceptionBox: ExceptionBox) -> DispatchWorkItem {
        DispatchWorkItem { [weak context] in
            // 已被 clear（注册表里没这个 id）就停，不触发也不重排。
            guard timerRegistry.contains(id) else { return }
            guard let context, let callback = callbackBox.callback,
                  !callback.isUndefined, !callback.isNull else {
                timerRegistry.remove(id)
                return
            }
            callback.call(withArguments: [])
            // P1-4c：同 setTimeout，读完即清。
            if let message = exceptionBox.message, !message.isEmpty {
                #if DEBUG
                print("[WidgetHost] setInterval 回调抛错：\(message)")
                #endif
                exceptionBox.message = nil
            }
            // 回调里可能调了 clearInterval；只有 id 还在表里才排下一次。
            if timerRegistry.contains(id) {
                Self.scheduleIntervalTick(id: id, delayMs: delayMs, callbackBox: callbackBox, context: context, timerRegistry: timerRegistry, exceptionBox: exceptionBox)
            }
        }
    }

    /// 排 setInterval 的下一次 tick（P1-1）：静态递归，不捕获可变 var。
    /// timerRegistry.store 在 id 已被取消时返回 false，这时不再 asyncAfter，
    /// 防取消后僵尸 tick。
    private static func scheduleIntervalTick(id: Int, delayMs: Double, callbackBox: TimerCallbackBox, context: JSContext, timerRegistry: TimerRegistry, exceptionBox: ExceptionBox) {
        let work = makeIntervalTickWork(id: id, delayMs: delayMs, callbackBox: callbackBox, context: context, timerRegistry: timerRegistry, exceptionBox: exceptionBox)
        guard timerRegistry.store(work, for: id) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delayMs / 1000.0, execute: work)
    }

    /// 从 context 取 Promise 构造器，用 executor block 造一个 JS Promise。
    /// executor 被 Promise 构造器同步调用，交出 resolve/reject；
    /// Swift 拿着它们去后台发请求，完事回主线程结算。
    /// 用原生 Promise 构造器造一个已拒绝的 Promise（chunk-1 P1-3）：
    /// 模块把全局 Promise 改坏、或 construct 失败时走这里，绝不 fatalError。
    /// 构造器取不到时，用 async 函数取回内建 Promise（async 函数恒用内建
    /// Promise，不受全局 Promise 改写影响）；再取不到就返回 undefined，
    /// JS 侧调 .then 会报 TypeError，总比崩 App 强——已是最后防线，
    /// 实践中走不到（构造器在建桥时就从全新 context 上取下强引用了）。
    private static func rejectedPromise(in context: JSContext, constructor: JSValue?, exceptionBox: ExceptionBox, message: String) -> JSValue {
        var ctor = constructor
        if ctor == nil || ctor!.isUndefined || ctor!.isNull {
            // 恢复求值自己的异常不留给后事（本次已自行处理）：
            // 求值前盒子里是什么，求值后还恢复成什么。
            let before = exceptionBox.message
            if let recovered = context.evaluateScript("(async function(){}()).constructor"),
               !recovered.isUndefined, !recovered.isNull {
                ctor = recovered
            }
            if exceptionBox.message != before {
                exceptionBox.message = before
            }
        }
        guard let ctor, !ctor.isUndefined, !ctor.isNull else {
            #if DEBUG
            print("[WidgetHost] Widget.http 拿不到可用的 Promise 构造器：\(message)")
            #endif
            return JSValue(undefinedIn: context)!
        }
        let errorValue: JSValue
        if let jsError = context.objectForKeyedSubscript("Error")?.construct(withArguments: [message]) {
            errorValue = jsError
        } else {
            errorValue = JSValue(object: message, in: context)!
        }
        if let rejected = ctor.invokeMethod("reject", withArguments: [errorValue]) {
            return rejected
        }
        #if DEBUG
        print("[WidgetHost] Promise.reject 失败：\(message)")
        #endif
        return JSValue(undefinedIn: context)!
    }

    private static func makeHttpGetPromise(in context: JSContext, urlString: String, options: JSValue?, interceptor: CategoryRequestInterceptor, httpRegistry: HTTPRequestRegistry, nativePromiseConstructor: JSValue?, exceptionBox: ExceptionBox) -> JSValue {
        let headers = headers(from: options)
        let timeout = timeoutInterval(from: options)
        let effectiveURL = interceptor.rewrittenURL(for: urlString) ?? urlString
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            let box = JSCallbackBox(resolve: resolve, reject: reject)
            // executor Task 是 detached 的：记进登记表，完事自己注销；
            // host 释放时由 cancelAll 统一取消。
            // P1-2：taskID 在建 Task 之前就定好（不跨线程读写 var），
            // defer 用同一个 id 注销；Task 若在 register 之前已跑完，
            // unregister 先记 finishedIDs，register 在锁内看到就不再登记，
            // 不会漏注销、不会滞留。
            let taskID = UUID()
            let task = Task {
                defer {
                    httpRegistry.unregister(taskID)
                }
                do {
                    let (status, data, responseHeaders, rawData, finalURL) = try await Self.fetchBridgeHTTP(
                        urlString: effectiveURL,
                        headers: headers,
                        timeout: timeout
                    )
                    await MainActor.run {
                        guard let ctx = box.resolve.context else { return }
                        let result = JSValue(newObjectIn: ctx)!
                        result.setValue(status, forProperty: "status")
                        result.setValue(data, forProperty: "data")
                        result.setValue(JSValue(object: responseHeaders, in: ctx) ?? JSValue(newObjectIn: ctx)!, forProperty: "headers")
                        result.setValue(finalURL, forProperty: "finalUrl")
                        WidgetHost.installArrayBuffer(from: rawData, in: ctx, on: result)
                        box.resolve.call(withArguments: [result])
                    }
                } catch {
                    // 传输层错误码要透传给 Swift 侧（账本/诊断靠它区分"疑需节点"与真失败）：
                    // localizedDescription 里没有码，JS Error 的 message 只能带字符串，
                    // 所以用结构化前缀挂在 message 前面，callFunction 侧再还原。
                    let nsError = error as NSError
                    let message: String
                    if nsError.domain == NSURLErrorDomain {
                        message = "__NATIVE_URLERROR__:\(nsError.code)|\(nsError.localizedDescription)"
                    } else {
                        message = error.localizedDescription
                    }
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
            httpRegistry.register(task, id: taskID)
        }
        // P1-3：构造器是建桥时从全新 context 上取下的原生构造器（不是现取的全局
        // Promise，模块改写全局 Promise 也影响不到它）；construct 失败也不
        // fatalError，返回一个已拒绝的 Promise。
        guard let promiseConstructor = nativePromiseConstructor,
              !promiseConstructor.isUndefined, !promiseConstructor.isNull,
              let promise = promiseConstructor.construct(withArguments: [executor]) else {
            return rejectedPromise(in: context, constructor: nativePromiseConstructor, exceptionBox: exceptionBox, message: "Widget.http.get 构造 Promise 失败")
        }
        return promise
    }

    private static func makeHttpPostPromise(in context: JSContext, urlString: String, body: JSValue?, options: JSValue?, httpRegistry: HTTPRequestRegistry, nativePromiseConstructor: JSValue?, exceptionBox: ExceptionBox) -> JSValue {
        let headers = headers(from: options)
        let timeout = timeoutInterval(from: options)
        let bodyData = httpBodyData(from: body)
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            let box = JSCallbackBox(resolve: resolve, reject: reject)
            // executor Task 是 detached 的：记进登记表，完事自己注销；
            // host 释放时由 cancelAll 统一取消（与 GET 同理）。
            // P1-2：taskID 在建 Task 之前就定好（与 GET 同款，不跨线程读写 var）；
            // 提前跑完的注销见 GET 处的注释，锁内对齐。
            let taskID = UUID()
            let task = Task {
                defer {
                    httpRegistry.unregister(taskID)
                }
                do {
                    let (status, data, responseHeaders, rawData, finalURL) = try await Self.fetchHTTP(
                        urlString: urlString,
                        method: "POST",
                        body: bodyData,
                        headers: headers,
                        timeout: timeout
                    )
                    await MainActor.run {
                        guard let ctx = box.resolve.context else { return }
                        let result = JSValue(newObjectIn: ctx)!
                        result.setValue(status, forProperty: "status")
                        result.setValue(data, forProperty: "data")
                        result.setValue(JSValue(object: responseHeaders, in: ctx) ?? JSValue(newObjectIn: ctx)!, forProperty: "headers")
                        result.setValue(finalURL, forProperty: "finalUrl")
                        WidgetHost.installArrayBuffer(from: rawData, in: ctx, on: result)
                        box.resolve.call(withArguments: [result])
                    }
                } catch {
                    // 传输层错误码要透传给 Swift 侧（账本/诊断靠它区分"疑需节点"与真失败）：
                    // localizedDescription 里没有码，JS Error 的 message 只能带字符串，
                    // 所以用结构化前缀挂在 message 前面，callFunction 侧再还原。
                    let nsError = error as NSError
                    let message: String
                    if nsError.domain == NSURLErrorDomain {
                        message = "__NATIVE_URLERROR__:\(nsError.code)|\(nsError.localizedDescription)"
                    } else {
                        message = error.localizedDescription
                    }
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
            httpRegistry.register(task, id: taskID)
        }
        // P1-3：与 GET 同款——原生构造器 + construct 失败返回已拒绝的 Promise，不 fatalError。
        guard let promiseConstructor = nativePromiseConstructor,
              !promiseConstructor.isUndefined, !promiseConstructor.isNull,
              let promise = promiseConstructor.construct(withArguments: [executor]) else {
            return rejectedPromise(in: context, constructor: nativePromiseConstructor, exceptionBox: exceptionBox, message: "Widget.http.post 构造 Promise 失败")
        }
        return promise
    }

    /// POST 的 body 转 Data：字符串直接 UTF-8；数组/对象转 JSON；没有/空返回 nil。
    private static func httpBodyData(from body: JSValue?) -> Data? {
        guard let body, !body.isUndefined, !body.isNull else { return nil }
        if body.isString {
            return body.toString().data(using: .utf8)
        }
        if body.isArray,
           let array = body.toArray(),
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array) {
            return data
        }
        if let dict = body.toDictionary() as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict) {
            return data
        }
        return body.toString().data(using: .utf8)
    }

    /// 从 options 提取超时时间（兼容毫秒如 8000 和秒如 8）；未传时默认
    /// WidgetTimeoutBudget.httpDefaultSeconds，让模块在 awaitPromise 窗口内
    /// 至少有余量切到备用镜像域名。默认值/夹值/毫秒分界全在超时一本账里（P1-10）。
    private static func timeoutInterval(from options: JSValue?) -> TimeInterval {
        guard let raw = options?.objectForKeyedSubscript("timeout"),
              !raw.isUndefined, !raw.isNull else {
            return WidgetTimeoutBudget.httpDefaultSeconds
        }
        let value = raw.toDouble()
        guard value.isFinite, value > 0 else { return WidgetTimeoutBudget.httpDefaultSeconds }
        let seconds = value > WidgetTimeoutBudget.timeoutMillisThreshold ? (value / 1000.0) : value
        return min(max(seconds, WidgetTimeoutBudget.httpMinSeconds), WidgetTimeoutBudget.httpMaxSeconds)
    }

    private static func headers(from options: JSValue?) -> [String: String] {
        var overrides: [String: String] = [:]
        if let dict = options?.objectForKeyedSubscript("headers")?.toDictionary() {
            for (key, value) in dict {
                if let keyString = key as? String {
                    overrides[keyString] = "\(value)"
                }
            }
        }
        return NetConstants.mergeHeaders(base: NetConstants.defaultBrowserHeaders, overrides: overrides)
    }

    private static func fetchHTTP(
        urlString: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String],
        timeout: TimeInterval = 12
    ) async throws -> (status: Int, data: Any, responseHeaders: [String: String], rawData: Data, finalURL: String) {
        guard let url = URL(string: urlString) else {
            throw WidgetHostError.callFailed("链接格式不对：\(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body { request.httpBody = body }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (raw, response) = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "widget",
            preservedHeaders: headers,
            timeout: timeout
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // finalUrl：重定向后的最终落点（URLSession 的 response.url 与 DoH 的
        // 末跳 response.url 都是最终 URL）；javtiful 的钩子靠它切 R2 直链，
        // 省掉 AVPlayer 在 mediaserverd 里重走 302 的 1–2 秒。
        return (status, httpDataObject(from: raw), responseHeaders(from: response), raw, response.url?.absoluteString ?? "")
    }

    /// 桥里模块 GET 的统一入口（run #20）：
    /// WP /posts 请求走 B 查询（_embed=wp:featuredmedia + _fields 瘦身），
    /// 结构失败时记一笔并一次性回退原查询；挑战直接抛（不重试、不回退——
    /// 挑战跟 B 无关）。非 WP 请求走原 fetchHTTP。
    private static func fetchBridgeHTTP(
        urlString: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Any, responseHeaders: [String: String], rawData: Data, finalURL: String) {
        guard let bURL = WPQueryOptimizer.bRewrittenURL(for: urlString) else {
            return try await fetchHTTP(urlString: urlString, headers: headers, timeout: timeout)
        }
        let host = URL(string: urlString)?.host ?? ""
        var result = try await fetchWPBridgeTuple(urlString: bURL, headers: headers, timeout: timeout)
        if WPQueryOptimizer.isStructuralFailure(status: result.status, bodyData: result.rawData) {
            WPQueryCapability.record(host: host, works: false)
            result = try await fetchWPBridgeTuple(urlString: urlString, headers: headers, timeout: timeout)
        } else {
            WPQueryCapability.record(host: host, works: true)
        }
        return result
    }

    /// 经 WordPressHTTP（挑战检测 + 单次可控重试 + 请求合并）取一个 WP GET，
    /// 拼成桥里 resolve 用的四元组。
    private static func fetchWPBridgeTuple(
        urlString: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> (status: Int, data: Any, responseHeaders: [String: String], rawData: Data, finalURL: String) {
        guard let url = URL(string: urlString) else {
            throw WidgetHostError.callFailed("链接格式不对：\(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (raw, response) = try await WordPressHTTP.shared.fetch(request, source: "widget", timeout: timeout)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, httpDataObject(from: raw), responseHeaders(from: response), raw, response.url?.absoluteString ?? "")
    }

    /// HTTPURLResponse.allHeaderFields 扁平成 [String: String]。
    /// 原样 key 留一份（如 'Set-Cookie'），再补一份全小写 key（如 'set-cookie'），
    /// 模块按哪种写法查都能查到；值一律转字符串。
    /// 边界：allHeaderFields 是字典，同名响应头（如多条 Set-Cookie）会被合并成一个值，
    /// 宿主侧分不开——需要逐条 cookie 的模块只能拿合并后的值自己拆。
    private static func responseHeaders(from response: URLResponse?) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            let keyString = "\(key)"
            let valueString = "\(value)"
            out[keyString] = valueString
            let lower = keyString.lowercased()
            if out[lower] == nil { out[lower] = valueString }
        }
        return out
    }

    /// Data → JS ArrayBuffer（供 Widget.http 回值 .arrayBuffer 与 fetch().arrayBuffer() 用）。
    /// 只用本文件已验证过的 API：JSValue(object:in:) + 安装时注入的 JS 助手
    /// __fwArrayBufferFromBytes（new Uint8Array(bytes).buffer），
    /// 不引入未经验证的 ArrayBuffer 构造器。
    /// 只在主线程调（调用点都在 MainActor.run 里，resolve/reject 与现有注释同款规矩）。
    /// 边界：按字节数组过桥，O(n) 装箱。单个响应不再设 16 MiB 上限
    ///（P1-1：原来 >16 MiB 直接返回 nil，模块读 .arrayBuffer 得 undefined，
    /// 等于静默丢弃；R5：单个超限响应也走 installArrayBuffer 的惰性
    /// token/FIFO 路径，只在模块读 .arrayBuffer 时才转换，不急切装箱。
    /// 16 MiB 上限只约束 FIFO 里未读响应的累计量，见
    /// ArrayBufferPendingQueue，不再卡单个响应）。
    /// 返回 nil = 没建出来，调用方直接不设该属性，不抛错。
    private static func jsArrayBuffer(from raw: Data, in context: JSContext) -> JSValue? {
        guard let helper = context.objectForKeyedSubscript("__fwArrayBufferFromBytes"),
              !helper.isUndefined, !helper.isNull else { return nil }
        let bytes: [Int] = raw.map { Int($0) }
        guard let jsArray = JSValue(object: bytes, in: context) else { return nil }
        guard let buffer = helper.call(withArguments: [jsArray]),
              !buffer.isUndefined, !buffer.isNull else { return nil }
        return buffer
    }

    /// 在 Widget.http 回值对象上装 .arrayBuffer（chunk-1 性能问题）：
    /// ≤1 MiB 直接急切构造（装箱量可接受，行为与原来一致）；
    /// 1–16 MiB 装惰性 getter，JS 第一次读 .arrayBuffer 时才构造——
    /// fetch().arrayBuffer() 与模块直接读 res.arrayBuffer 都是按需读，
    /// 平时不付装箱钱；首次访问后用 defineProperty 把访问器覆写成普通
    /// 数据属性，后续访问不再经过 getter。
    /// >16 MiB 也走惰性 token/FIFO 路径（R5：原来直接 return 静默丢弃；
    /// R4 改成安装时急切全量转换，主线程峰值数百 MiB、Jetsam 风险；
    /// 现在只在模块读 .arrayBuffer 时才转换，转换失败才缺省——
    /// 不静默丢弃、不急切装箱；单个超限项进队后不被自己淘汰，
    /// 见 store() 的 items.count > 1 守卫）。
    /// 只在主线程调（调用点都在 MainActor.run 里）。
    /// JS 侧契约不变：res.arrayBuffer 仍是 ArrayBuffer（或缺省），只是什么时候构造变了。
    /// P0-1：getter block 不捕获 raw / context / result——getter 挂在 result
    /// 上又强捕获 result/context 会形成跨边界强引用环（JS GC 看不到 Swift
    /// 侧的边），每条大响应永久泄漏 Data + 整个 JSContext；且原来 getter 内
    /// 调 result.setValue 走 [[Set]]，只读访问器（无 set）不会被替换成数据
    /// 属性，每次访问都重复全量装箱、严格模式下还抛 TypeError 污染 exceptionBox。
    /// 所以 Data 按 token 存在下面的弱键登记表里，getter 运行时用
    /// JSContext.current() 取 context、JSContext.currentThis() 取 result，
    /// 从 result 的不可枚举 __fwArrayBufferToken 属性读 token 再取 Data；
    /// 首次访问后删登记，并用 defineProperty（带 JSPropertyDescriptorValueKey）
    /// 把属性覆写成普通数据属性，不再走 setValue。
    private static func installArrayBuffer(from raw: Data, in context: JSContext, on result: JSValue) {
        if raw.count <= 1 * 1024 * 1024 {
            if let buffer = jsArrayBuffer(from: raw, in: context) {
                result.setValue(buffer, forProperty: "arrayBuffer")
            }
            return
        }
        // Data 登记（token → Data），与 result 的 JSValue 生命周期解耦：
        // 表按 context 弱键，context 释放时整条消失，从没被读过的 Data
        // 也随之释放，不永久滞留。
        let token = UUID().uuidString
        arrayBufferPendingLock.lock()
        var pending = arrayBufferPending.object(forKey: context)
        if pending == nil {
            pending = ArrayBufferPendingQueue()
            arrayBufferPending.setObject(pending, forKey: context)
        }
        // FIFO 封顶：超 4 条或 16 MiB 时最旧 token 在 store 里被淘汰。
        pending?.store(token: token, data: raw)
        arrayBufferPendingLock.unlock()
        // token 存在 result 的不可枚举内部属性上（getter 运行时从 this 上读）；
        // 不可枚举：模块 for..in / Object.keys / JSON.stringify 看不到它。
        guard let tokenValue = JSValue(object: token, in: context) else { return }
        result.defineProperty(
            "__fwArrayBufferToken",
            descriptor: [
                JSPropertyDescriptorValueKey: tokenValue,
                JSPropertyDescriptorWritableKey: true,
                JSPropertyDescriptorEnumerableKey: false,
                JSPropertyDescriptorConfigurableKey: true,
            ]
        )
        // getter 不捕获任何东西（空捕获列表）：raw / context / result 全在
        // 运行时取，block 与 result 之间没有强引用环。
        let getter: @convention(block) () -> JSValue? = {
            guard let context = JSContext.current(),
                  let this = JSContext.currentThis(),
                  let token = this.objectForKeyedSubscript("__fwArrayBufferToken")?.toString() else { return nil }
            arrayBufferPendingLock.lock()
            // take() 读删一次完成：首次访问即删登记，不留窗口。
            let raw = arrayBufferPending.object(forKey: context)?.take(token: token)
            arrayBufferPendingLock.unlock()
            guard let raw, let buffer = WidgetHost.jsArrayBuffer(from: raw, in: context) else {
                // P2-3：Data 已被 FIFO 淘汰（或转换失败）时，把属性定成
                // undefined 数据属性再返回——后续读取不再进 getter 查空表
                //（原来每次读都重新进原生 getter、加锁、take 查空表）。
                // 读到的值与原来一致（getter 返回 nil 即 undefined），
                // 只是不再反复走 getter。
                if let undefined = JSValue(undefinedIn: context) {
                    this.defineProperty(
                        "arrayBuffer",
                        descriptor: [
                            JSPropertyDescriptorValueKey: undefined,
                            JSPropertyDescriptorWritableKey: true,
                            JSPropertyDescriptorEnumerableKey: true,
                            JSPropertyDescriptorConfigurableKey: true,
                        ]
                    )
                }
                return nil
            }
            // 首次访问后用 defineProperty 把访问器覆写成普通数据属性。
            this.defineProperty(
                "arrayBuffer",
                descriptor: [
                    JSPropertyDescriptorValueKey: buffer,
                    JSPropertyDescriptorWritableKey: true,
                    JSPropertyDescriptorEnumerableKey: true,
                    JSPropertyDescriptorConfigurableKey: true,
                ]
            )
            return buffer
        }
        guard let getterValue = JSValue(object: getter, in: context) else { return }
        result.defineProperty(
            "arrayBuffer",
            descriptor: [
                JSPropertyDescriptorGetKey: getterValue,
                JSPropertyDescriptorConfigurableKey: true,
                JSPropertyDescriptorEnumerableKey: true,
            ]
        )
    }

    /// 惰性 arrayBuffer 的待装箱 Data 登记表（P0-1，见 installArrayBuffer）：
    /// 弱键是 JSContext（context 释放时条目自动消失），值是每 context 一个
    /// FIFO 队列。NSMapTable 弱键依赖零化弱引用，JSContext 是 NSObject，可用。
    private static let arrayBufferPendingLock = NSLock()
    private static let arrayBufferPending = NSMapTable<JSContext, ArrayBufferPendingQueue>.weakToStrongObjects()

    /// 每 context 的惰性 arrayBuffer 待装箱队列（FIFO 封顶：最多最近 4 条
    /// 或总计 16 MiB，超限淘汰最旧 token）。模块只读 res.data、从不访问
    /// .arrayBuffer 时，未读的 Data 不再随浏览页数在整个会话里堆积。
    /// 只在 arrayBufferPendingLock 后访问。
    private final class ArrayBufferPendingQueue {
        static let maxEntries = 4
        static let maxBytes = 16 * 1024 * 1024
        private var items: [(token: String, data: Data)] = []
        private var totalBytes = 0

        func store(token: String, data: Data) {
            items.append((token, data))
            totalBytes += data.count
            // FIFO 只限制未读累计量：淘汰最旧项，但刚存进来的这一项自己
            // 绝不被淘汰（items.count > 1 守卫：超限时先淘汰旧项，只剩
            // 新项时即便仍超累计上限也留着它，不静默丢弃。注：旧
            // installArrayBuffer 的 >16 MiB guard 在进队前就 return，
            // store() 实际从未见过超限项，守卫是防超限项进队后自淘汰，
            // 不是修已发生的旧行为）。
            while (items.count > Self.maxEntries || totalBytes > Self.maxBytes) && items.count > 1 {
                let oldest = items.removeFirst()
                totalBytes -= oldest.data.count
            }
        }

        /// 取出并删除（getter 首次访问用）：读删一次完成，不留窗口。
        func take(token: String) -> Data? {
            guard let idx = items.firstIndex(where: { $0.token == token }) else { return nil }
            let data = items[idx].data
            items.remove(at: idx)
            totalBytes -= data.count
            return data
        }
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
    /// 竞速也用这个找固定验线样本。
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

    /// 线路竞速的种子：只认原始 latest 第 1 页、120 秒内的新鲜种子。
    /// sourceGeneration 是源 JS 指纹（loadHost 时算）：源换了 JS，旧种子作废。
    struct LineRaceSeed {
        let moduleID: String
        let sourceGeneration: String
        let page: Int
        let items: [VideoItem]
        let createdAt: Date

        init(moduleID: String, sourceGeneration: String, page: Int, items: [VideoItem], createdAt: Date) {
            self.moduleID = moduleID
            self.sourceGeneration = sourceGeneration
            self.page = page
            self.items = items
            self.createdAt = createdAt
        }
    }

    /// 种子竞速（自动路，run #20）：首屏 latest 第 1 页画出来后，VideoGridView
    /// 拿着刚取到的列表调进来；不再进模块就跑，不再为取样另调一次 latest
    ///（180 秒 seenFilter 会把取样当成一次 latest 浏览，污染后续去重）。
    /// 种子须满足：page == 1、120 秒内、同代、latest 模块；否则直接不跑。
    /// 最多 4 个发现样本，低优先级，用户可见请求开始时暂停取样。
    /// 每个模块、每次打开软件到关闭软件，最多自动竞速一次。
    /// 本会话已竞过 → 不再跑，直接用会话里定的首选线（preferredLine 兜底读它）。
    /// 没分出胜负 / 两条都死 → preferredLine 保持 nil，按现有逻辑。
    /// 不抛错、不阻塞调用方；后台跑，跑完写 preferredLine，并把结果
    ///（胜出线、各线耗时）记到 SourceStore，供检测页显示。
    /// 播放器读 preferredLine：首选 memojav 走快路径直拼；首选 nmcorp 先走 loadResource 拿 nmcorp 线。
    func raceLinesIfNeeded(seed: LineRaceSeed) {
        guard !didRaceLines else { return }
        guard seed.page == 1,
              Date().timeIntervalSince(seed.createdAt) < 120,
              seed.moduleID == latestListModule()?.id,
              seed.sourceGeneration.isEmpty || sourceGeneration.isEmpty
                || seed.sourceGeneration == sourceGeneration,
              !seed.items.isEmpty else { return }
        didRaceLines = true
        // 本会话已竞过：不再下测试片段抢网，首选线由 preferredLine 兜底读会话缓存。
        if SourceStore.shared.hasRacedThisSession(meta.id) { return }
        // 同步先把 id 记进本会话已竞集合：重入瞬间（进模块又立刻返回再进）
        // 两个 host 不会都开竞。
        SourceStore.shared.markRaceStarted(for: meta.id)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let outcome = await self.runLineRace(seed: seed)
            await self.finishRace(outcome)
        }
    }

    /// 手动重竞（检测页“重新竞速”）：现取 latest 第 1 页做新鲜种子再竞；
    /// latest 取不到时退回固定验线取样（手动动作，不抢首屏网；
    /// 固定验线 kind 是 "fixed"，不污染 latest 的 seenFilter）。
    /// force=true 无视本会话去重，强制重测一次。
    func raceLinesIfNeeded(force: Bool) {
        guard !didRaceLines else { return }
        didRaceLines = true
        // 同步先把 id 记进本会话已竞集合：重入瞬间（进模块又立刻返回再进）
        // 两个 host 不会都开竞。手动重竞也记，防并发的自动竞速插进来。
        SourceStore.shared.markRaceStarted(for: meta.id)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let outcome: LineRaceOutcome
            if let latest = self.latestListModule(),
               let samples = try? await self.loadList(moduleId: latest.id, page: 1),
               !samples.isEmpty {
                let seed = LineRaceSeed(moduleID: latest.id, sourceGeneration: self.sourceGeneration, page: 1, items: samples, createdAt: Date())
                outcome = await self.runLineRace(seed: seed)
            } else {
                outcome = await self.runLineRaceFromFixedProbe()
            }
            await self.finishRace(outcome)
        }
    }

    /// 点视频时的按需发现（run #20）：首播后台的 loadResource 已解出线路，
    /// 若还没定首选线，用第一条能认出种类的线暂定下来（不另跑竞速、不阻塞播放）。
    /// 只写内存里的 _preferredLine，不记会话“已竞”（种子竞速仍可跑、跑完覆盖它）。
    func noteTappedVideoDiscovery(lines: [PlayLine]) {
        raceLock.lock()
        defer { raceLock.unlock() }
        guard _preferredLine == nil,
              SourceStore.shared.sessionPreferredLine(for: meta.id) == nil else { return }
        for line in lines {
            guard let kind = PlaybackEngine.preferredLineKind(of: line) else { continue }
            _preferredLine = kind
            break
        }
    }

    /// 该模块是不是“最新”列表模块（VideoGridView 种子触发用）。
    func isLatestListModule(_ moduleId: String) -> Bool {
        latestListModule()?.id == moduleId
    }

    /// 竞速收尾（两路共用）：写 preferredLine、记结果到 SourceStore、进会话缓存。
    /// key 是 WidgetMeta.id，与 SourceRecord.id 同一个值。
    private func finishRace(_ outcome: LineRaceOutcome) async {
        raceLock.lock()
        _preferredLine = outcome.winner
        raceLock.unlock()
        await SourceStore.shared.recordRaceResult(
            LineRaceResult(
                winnerLabel: outcome.winner?.displayLabel,
                timings: outcome.timings,
                racedAt: Date(),
                note: outcome.note
            ),
            for: meta.id
        )
        // 首选线进会话缓存：同会话再进这个模块的新 host 直接用，不重竞。
        SourceStore.shared.markRaceFinished(for: meta.id, preferredLine: outcome.winner)
    }

    /// 一次竞速的内部结果：胜出线 + 每种线的最快耗时 + 没分出胜负的原因。
    /// 算法与原来一字不差（并发解线、每样本第一条可播线定种类、最快获胜）；
    /// 只是把原来只留胜者、其余丢掉的计时也收起来，记到 SourceStore 供检测页显示。
    private struct LineRaceOutcome {
        let winner: PreferredLine?
        let timings: [LineTiming]
        let note: String?
    }

    /// 种子竞速：种子 items 里最多取 4 个发现样本，并发解线计时。
    private func runLineRace(seed: LineRaceSeed) async -> LineRaceOutcome {
        await raceSamples(Array(seed.items.prefix(4)))
    }

    /// 固定验线取样（手动重竞的兜底）：固定验线模块取样本，并发解线计时。
    private func runLineRaceFromFixedProbe() async -> LineRaceOutcome {
        guard let probe = fixedProbeModule() else {
            return LineRaceOutcome(winner: nil, timings: [], note: "没有固定验线")
        }
        let samples: [VideoItem]
        do {
            samples = try await loadList(moduleId: probe.id, page: 1)
        } catch {
            return LineRaceOutcome(winner: nil, timings: [], note: "验线样本取不到")
        }
        guard !samples.isEmpty else {
            return LineRaceOutcome(winner: nil, timings: [], note: "固定验线没有返回样本")
        }
        return await raceSamples(samples)
    }

    /// 竞速核心：给定样本，并发调 loadResource 解线计时；每样本第一条能播的线
    /// 定种类，最快的那种线获胜。取样前先让路：用户可见请求（列表/分类/搜索/详情）
    /// 在跑时等一等（每 0.3 秒看一次，最多让 60 秒），不跟首屏抢网。
    /// 解线有解析步超时兜底（CheckTimeouts.effectiveMs 解析，模块声明的 parseMs 优先），
    /// 挂住的样本不等它，返回空线。
    private func raceSamples(_ samples: [VideoItem]) async -> LineRaceOutcome {
        guard !samples.isEmpty else {
            return LineRaceOutcome(winner: nil, timings: [], note: "没有样本")
        }
        let gateDeadline = Date().addingTimeInterval(60)
        let parseMs = CheckTimeouts.effectiveMs(for: .parse, declared: self.meta.checkTimeouts.parseMs)
        var best: (kind: PreferredLine, elapsed: TimeInterval)?
        var fastestByKind: [PreferredLine: TimeInterval] = [:]
        var firstNonRacePlayable: (kind: PlaybackEngine.PlayableLineKind, elapsed: TimeInterval)?
        typealias RaceSampleResult = (preferred: (PreferredLine, TimeInterval)?, nonRace: (PlaybackEngine.PlayableLineKind, TimeInterval)?)
        await withTaskGroup(of: RaceSampleResult.self) { group in
            for sample in samples {
                group.addTask {
                    while self.isUserRequestActive && Date() < gateDeadline {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if Task.isCancelled { return (nil, nil) }
                    }
                    if Task.isCancelled { return (nil, nil) }
                    let start = Date()
                    let lines = await self.loadResourceWithTimeout(link: sample.link, title: sample.title, milliseconds: parseMs)
                    let elapsed = Date().timeIntervalSince(start)
                    // 该样本第一条能播的线定种类；种类认不出则这个样本不算
                    for line in lines {
                        guard !line.url.isEmpty,
                              let kind = PlaybackEngine.classifyPlayableLine(line) else { continue }
                        if let preferred = PlaybackEngine.preferredLineKind(of: line) {
                            return ((preferred, elapsed), nil)
                        }
                        // 有可播线但无竞速种类：记下来（显示“无需竞速”用），不参与竞速
                        return (nil, (kind, elapsed))
                    }
                    return (nil, nil)
                }
            }
            for await result in group {
                if let preferred = result.preferred {
                    if let prev = fastestByKind[preferred.0] {
                        fastestByKind[preferred.0] = min(prev, preferred.1)
                    } else {
                        fastestByKind[preferred.0] = preferred.1
                    }
                    if best == nil || preferred.1 < best!.elapsed {
                        best = preferred
                    }
                }
                if firstNonRacePlayable == nil, let nonRace = result.nonRace {
                    firstNonRacePlayable = nonRace
                }
            }
        }
        let timings = fastestByKind
            .map { LineTiming(kind: $0.key.displayLabel, milliseconds: Int($0.value * 1000)) }
            .sorted { $0.milliseconds < $1.milliseconds }
        guard let winner = best?.kind else {
            if let playable = firstNonRacePlayable {
                let kindText: String
                switch playable.kind {
                case .hls: kindText = "HLS"
                case .directFile: kindText = "直链"
                case .embed: kindText = "嵌页"
                }
                return LineRaceOutcome(winner: nil, timings: timings, note: "无需竞速（\(kindText) · \(Int(playable.elapsed * 1000))ms）")
            }
            return LineRaceOutcome(winner: nil, timings: timings, note: "样本都解不出可播线路")
        }
        return LineRaceOutcome(winner: winner, timings: timings, note: nil)
    }

    /// 带超时的 loadResource（竞速用；超时返回空数组，不抛错）。
    /// 超时值由 raceSamples 按 CheckTimeouts.effectiveMs 算好传进来。
    private func loadResourceWithTimeout(link: String, title: String, milliseconds: Int) async -> [PlayLine] {
        let result = try? await withThrowingTaskGroup(of: [PlayLine].self) { group in
            group.addTask { try await self.loadResource(link: link, title: title) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                throw CheckStepError.timeout(milliseconds)
            }
            guard let lines = try await group.next() else {
                throw CheckStepError.timeout(milliseconds)
            }
            group.cancelAll()
            return lines
        }
        return result ?? []
    }

    /// 调指定模块的列表函数，返回视频列表。
    /// requiresWebView 的模块也能跑：列表本身是 JS 调 API，不依赖播放器；
    /// 播的时候按线路类型路由（直链→AVPlayer，嵌入页→解流/WebView）。
    func loadList(moduleId: String, page: Int) async throws -> [VideoItem] {
        beginUserRequest()
        defer { endUserRequest() }
        guard let module = modules.first(where: { $0.id == moduleId }) else {
            throw WidgetHostError.functionMissing("没有这个模块：\(moduleId)")
        }
        let result = try await callFunction(module.functionName, params: buildParams(for: module, page: page, inputs: [:]))
        return try parseVideoItems(result)
    }

    /// 调 type == "stream" 的模块（一般是 loadResource），返回播放线路。
    /// url 为空的项已跳过；模块说“无可用播放源”时返回空数组，由调用方决定怎么显示。
    /// requiresWebView 的模块也能跑：返回的嵌入页线路走解流/WebView 播放器。
    func loadResource(link: String, title: String) async throws -> [PlayLine] {
        guard let module = modules.first(where: { $0.type == "stream" }) else {
            throw WidgetHostError.functionMissing("这个模块没有播放解析功能")
        }
        let result = try await callFunction(module.functionName, params: buildParams(for: module, page: 1, inputs: ["link": link, "title": title]))
        return parsePlayLines(result)
    }

    /// 调模块的 loadDetail(link)（短剧/分集类模块有，如 huangguo.js），返回详情与分集。
    /// 没有 loadDetail 函数的模块 throw functionMissing，调用方据此隐藏分集区（不是错误）。
    /// loadDetail 在模块里是 loadDetail(link) 单字符串参数，不是 params 对象。
    func loadDetail(link: String) async throws -> DetailItem {
        beginUserRequest()
        defer { endUserRequest() }
        let result = try await callFunction("loadDetail", args: [link])
        return try parseDetailItem(result)
    }

    /// 调 WidgetMetadata.search.functionName（一般是 searchVideos）。
    /// requiresWebView 的模块也能跑（搜索是 JS 调 API，与播放器无关）。
    func search(keyword: String, page: Int) async throws -> [VideoItem] {
        beginUserRequest()
        defer { endUserRequest() }
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

    /// 取某分类下的视频。优先走模块分类（run #27，javhd 这类非 WP 站）：
    /// 模块声明了 kind="category" 的列表入口时，直接调模块 loadList（slug 作 input）。
    /// 没声明的模块（pornjav）走原有路（run #20）：直调 WP REST：
    /// GET /wp-json/wp/v2/posts?categories=<id>&per_page=20&page=<n>
    /// + B 查询（_embed=wp:featuredmedia&_fields 瘦身），映射成 VideoItem；
    /// 点视频时把帖子链接交回现有的 loadResource 解析播放。
    /// 拦截路径只作兜底：直调抛错才走它（绝不与直调并行——两路串行 8–12 秒，
    /// 且都会撞上同一面 Cloudflare 墙）；挑战/断路器打开的错不进兜底。
    /// 空数组是合法空结果（分类真没帖子），直接返回，不再换路。
    /// 分类链接绝不送进 loadResource。
    /// categoryId 是数字编号或模块给的 "pornjav-cat-321" 这类原始 id（数字从模块
    /// 的 /categories 响应里来，不硬编码）；siteHost / categorySlug
    /// 没有时对应路径自动跳过（拦截要求同源、直调要求域名）。
    func loadCategoryVideos(categoryId: String, categoryName: String, page: Int, siteHost: String? = nil, categorySlug: String? = nil) async throws -> [VideoItem] {
        beginUserRequest()
        defer { endUserRequest() }
        // 模块分类优先：有 kind="category" 入口的模块（javhd），点分类直接调模块
        // loadList（slug 作 input），不用走 WP REST。失败直接抛，不回退 WP
        //（该站没有 WP REST，回退只会再撞一次 404）。
        if let catModule = categoryListModule(), let slug = categorySlug, !slug.isEmpty {
            let result = try await callFunction(catModule.functionName, params: buildParams(for: catModule, page: page, inputs: ["slug": slug]))
            return try parseVideoItems(result)
        }
        let numericId = VideoItem.numericId(from: categoryId)
        let apiHost = siteHost.map { Self.stripWWWPrefix($0) }

        // 直调 WP REST：有数字编号直接查帖子
        if let numericId, let apiHost {
            do {
                return try await fetchCategoryPostsDirect(siteHost: apiHost, categoryId: numericId, categoryName: categoryName, page: page)
            } catch {
                // 挑战类错误（挑战/断路器打开）不进兜底：拦截走同一端点，
                // 只会再撞一次同一面墙。
                if let wpError = error as? WordPressHTTPError, wpError.isChallengeLike {
                    throw error
                }
                // 直调失败 → 兜底走拦截路径（调模块 latest，桥里改写它发出的 WP 帖子请求）
                if let latest = latestListModule() {
                    let token = requestInterceptor.arm(siteHost: apiHost, categoryId: numericId)
                    do {
                        let result = try await callFunction(latest.functionName, params: buildParams(for: latest, page: page, inputs: [:]))
                        let items = try parseVideoItems(result)
                        let hit = requestInterceptor.didRewrite(token: token)
                        requestInterceptor.disarm(token: token)
                        if hit && !items.isEmpty {
                            return items
                        }
                    } catch let e as CancellationError {
                        requestInterceptor.disarm(token: token)
                        throw e
                    } catch {
                        requestInterceptor.disarm(token: token)
                    }
                }
                throw error
            }
        }
        // 没数字编号时按 slug 查分类拿 id 再查帖子
        if let apiHost, let slug = categorySlug, !slug.isEmpty,
           let resolved = try? await resolveWordPressCategoryId(siteHost: apiHost, slug: slug) {
            return try await fetchCategoryPostsDirect(siteHost: apiHost, categoryId: resolved, categoryName: categoryName, page: page)
        }

        throw WidgetHostError.functionMissing("该分类暂不支持浏览")
    }

    /// 导入时做格式校验：新建一个临时 WidgetHost（只 evaluate + 取元数据，不发请求）。
    /// 没有可信 id 可预填，build 里用一次性临时命名空间，顶层求值期的
    /// storage 读写不落到任何真实模块前缀下；校验完 host 即丢弃。
    static func validate(jsSource: String, fallbackTitle: String? = nil) -> (ok: Bool, meta: WidgetMeta?, error: String?) {
        do {
            let host = try WidgetHost(jsSource: jsSource, fallbackTitle: fallbackTitle)
            return (true, host.meta, nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (false, nil, message)
        }
    }

    // MARK: - 内部：分类取列表（拦截 + 直调 WP REST）

    /// 找“最新”列表模块：params 里 kind 常量是 "latest" 的那个。
    /// 拦截路径调它（loadList kind=latest），桥里改写它发出的 WP 帖子请求。
    func latestListModule() -> ModuleDescriptor? {
        modules.first { module in
            module.params.contains { param in
                (param["name"] as? String) == "kind"
                && (param["type"] as? String) == "constant"
                && (param["value"] as? String) == "latest"
            }
        }
    }

    /// 找“分类”列表模块：params 里 kind 常量是 "category" 的那个（javhd）。
    /// 点分类时优先调它（slug 作 input），不用走 WP REST。
    func categoryListModule() -> ModuleDescriptor? {
        modules.first { module in
            module.params.contains { param in
                (param["name"] as? String) == "kind"
                && (param["type"] as? String) == "constant"
                && (param["value"] as? String) == "category"
            }
        }
    }

    /// 直调 WP REST 取某分类的帖子，映射成 VideoItem（run #20：B 查询默认）。
    /// 标题 HTML 解码、链接用帖子原链接、封面用 _embedded wp:featuredmedia[0].source_url、
    /// category 字段用分类名；点视频时把帖子链接交回现有的 loadResource 解析播放。
    /// B 查询结构失败时记一笔并一次性回退原 _embed=1 查询。
    private func fetchCategoryPostsDirect(siteHost: String, categoryId: String, categoryName: String, page: Int) async throws -> [VideoItem] {
        let useB = WPQueryCapability.isBEnabled(for: siteHost)
        guard let url = wpCategoryPostsURL(siteHost: siteHost, categoryId: categoryId, page: page, useB: useB) else {
            throw WidgetHostError.callFailed("分类地址拼不出来")
        }
        let (status, items, raw) = try await fetchWordPressArray(url: url)
        if useB, WPQueryOptimizer.isStructuralFailure(status: status, bodyData: raw) {
            WPQueryCapability.record(host: siteHost, works: false)
            guard let fallbackURL = wpCategoryPostsURL(siteHost: siteHost, categoryId: categoryId, page: page, useB: false) else {
                throw WidgetHostError.callFailed("分类地址拼不出来")
            }
            return try await fetchCategoryPostsFromURL(fallbackURL, categoryName: categoryName)
        }
        return try categoryPostsResult(status: status, items: items, categoryName: categoryName)
    }

    /// 直调 WP REST（回退路共用）：取一个已拼好的帖子 URL，映射成 VideoItem。
    private func fetchCategoryPostsFromURL(_ url: URL, categoryName: String) async throws -> [VideoItem] {
        let (status, items, _) = try await fetchWordPressArray(url: url)
        return try categoryPostsResult(status: status, items: items, categoryName: categoryName)
    }

    /// 分类直调的结果映射：200 → 帖子列表；400 → 空（页码超出总页数，
    /// WP 用 400 表示没更多了）；别的 → 抛错。items 为 nil（不是 JSON 数组）
    /// 也抛错——挑战由 WordPressHTTP 在前头拦截，不会走到这里。
    private func categoryPostsResult(status: Int, items: [[String: Any]]?, categoryName: String) throws -> [VideoItem] {
        guard status == 200 else {
            if status == 400 { return [] }
            throw WidgetHostError.callFailed("分类加载失败（HTTP \(status)）")
        }
        guard let items else {
            throw WidgetHostError.unexpectedResult("分类返回的不是帖子列表")
        }
        return items.compactMap { wordpressPostToVideoItem($0, categoryName: categoryName) }
    }

    /// 拼分类帖子 URL：categories + per_page 20 + page；B 开时用
    /// _embed=wp:featuredmedia&_fields 瘦身，关时用原 _embed=1。
    private func wpCategoryPostsURL(siteHost: String, categoryId: String, page: Int, useB: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/wp-json/wp/v2/posts"
        var queryItems = [
            URLQueryItem(name: "categories", value: categoryId),
            URLQueryItem(name: "per_page", value: "20"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        if useB {
            queryItems.append(contentsOf: WPQueryOptimizer.bQueryItems())
        } else {
            queryItems.append(URLQueryItem(name: "_embed", value: "1"))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// 直调 WP REST 时没有数字编号：先按 slug 查分类拿 id。
    /// 查到的映射记 1 小时缓存（host|slug → id），同一 slug 不重复发请求。
    private func resolveWordPressCategoryId(siteHost: String, slug: String) async throws -> String? {
        let cacheKey = siteHost.lowercased() + "|" + slug.lowercased()
        Self.categoryIdCacheLock.lock()
        if let cached = Self.categoryIdCache[cacheKey],
           Date().timeIntervalSince(cached.at) < Self.categoryIdCacheTTL {
            Self.categoryIdCacheLock.unlock()
            return cached.id
        }
        Self.categoryIdCacheLock.unlock()
        var components = URLComponents()
        components.scheme = "https"
        components.host = siteHost
        components.path = "/wp-json/wp/v2/categories"
        components.queryItems = [URLQueryItem(name: "slug", value: slug)]
        guard let url = components.url else { return nil }
        let (status, items, _) = try await fetchWordPressArray(url: url)
        guard status == 200, let first = items?.first else { return nil }
        let resolved: String?
        if let id = first["id"] as? Int {
            resolved = "\(id)"
        } else if let idString = first["id"] as? String, !idString.isEmpty {
            resolved = idString
        } else {
            resolved = nil
        }
        if let resolved {
            Self.categoryIdCacheLock.lock()
            Self.categoryIdCache[cacheKey] = (id: resolved, at: Date())
            Self.categoryIdCacheLock.unlock()
        }
        return resolved
    }

    /// 直调 WP REST 的通用 GET：返回 (status, JSON 数组或 nil, 原始 body)。
    /// 经 WordPressHTTP（挑战检测 + 单次可控重试 + 请求合并）发请求；
    /// 传输失败时 throw；HTTP 状态码原样返回，由调用方判定。
    private func fetchWordPressArray(url: URL) async throws -> (status: Int, items: [[String: Any]]?, rawData: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = WidgetTimeoutBudget.httpDefaultSeconds
        let headers = NetConstants.mergeHeaders(
            base: NetConstants.defaultBrowserHeaders,
            overrides: ["Accept": "application/json"]
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (raw, response) = try await WordPressHTTP.shared.fetch(request, source: "wp-direct", timeout: WidgetTimeoutBudget.httpDefaultSeconds)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let items = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        return (status, items, raw)
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

    private func callFunction(_ name: String, params: [String: Any]) async throws -> Any {
        try await callFunction(name, args: [params])
    }

    /// 调 JS 函数（async 函数返回 Promise）。函数查找与调用在主线程做，
    /// 返回的 Promise 再经 awaitPromise 桥回 Swift async。
    /// 返回的是主线程转好的 Swift/Foundation 值（P1-7），不再是 JSValue。
    private func callFunction(_ name: String, args: [Any]) async throws -> Any {
        let returned = try await MainActor.run { () throws -> JSValue in
            // P1-4b：调之前先清掉盒子里上一次的残留异常（定时器回调等），
            // 免得本次成功也被 takeException() 误判成失败。
            exceptionBox.message = nil
            guard let fn = Self.globalSymbol(in: context, named: name),
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

    /// 等一个 JS Promise，超时或 reject 都 throw。超时窗口见
    /// WidgetTimeoutBudget.promiseWindowMs（超时一本账，P1-10）。
    /// 返回前在主线程把 JSValue 转成 Swift/Foundation 值（P1-7），
    /// 调用方只解析 Swift 值，不在后台线程碰 JSValue。
    /// 超时后任务组 cancel 会一路传进 awaitPromiseRaw 的取消处理，
    /// JS 侧的等待随即收尾，不再空转占着连接池（旧逻辑：超时只 throw，
    /// continuation 没人 resume，JS 的 fetch 还在后台跑）。
    private func awaitPromise(_ value: JSValue) async throws -> Any {
        let box = JSValueBox(value)
        return try await withThrowingTaskGroup(of: Any.self) { group in
            group.addTask { try await self.awaitPromiseRaw(box.value) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(WidgetTimeoutBudget.promiseWindowMs) * 1_000_000)
                throw WidgetHostError.callFailed("模块 30 秒没返回，可能是站挂了或网络太慢")
            }
            guard let result = try await group.next() else {
                throw WidgetHostError.callFailed("模块没有返回")
            }
            group.cancelAll()
            return result
        }
    }

    /// 把 JS reject 的 message 还原成类型化错误：Widget.http 桥在传输层错误前挂了
    /// "__NATIVE_URLERROR__:<code>|<message>" 前缀（见 makeHttpGetPromise /
    /// makeHttpPostPromise），这里还原成 .transport(code:message)，账本/诊断靠它区分
    /// “疑需节点”与真失败；没有前缀的按原样走 .callFailed。
    private static func mapJSRejection(_ rawMessage: String) -> WidgetHostError {
        let prefix = "__NATIVE_URLERROR__:"
        guard rawMessage.hasPrefix(prefix) else {
            return .callFailed(rawMessage)
        }
        let payload = String(rawMessage.dropFirst(prefix.count))
        let parts = payload.split(separator: "|", maxSplits: 1)
        if let codeString = parts.first, let code = Int(codeString) {
            let message = parts.count > 1 ? String(parts[1]) : rawMessage
            return .transport(urlErrorCode: code, message: message)
        }
        return .callFailed(rawMessage)
    }

    /// Promise 桥接的核心：
    /// - 不是 Promise（没有 then）就直接当结果用——有的模块同步返回数组，不包 Promise；
    /// - 是 Promise 就调它的 then(onFulfilled, onRejected)，用 continuation 转成 Swift async。
    /// 关键点：then 必须用 invokeMethod 调（直接把 then 抠出来 call 会丢 this，
    /// JSC 会报 TypeError）；then 的调用必须在主线程。
    /// 取消：withTaskCancellationHandler + ContinuationBox。取消与 JS 回调共用一个
    /// OnceBox，谁先到谁 resume，另一个直接丢弃，绝不重复 resume。
    /// 两个竞态都处理了：① 任务进函数时已取消——onCancel 可能在 continuation 存进
    /// 盒子前就跑，所以存进去后要再查一次 Task.isCancelled；② 主队列的 then 调度
    /// 晚于取消——DispatchQueue.main.async 里先查取消再调 then，不给已取消的
    /// Promise 再挂回调。
    /// 返回的是主线程转好的 Swift/Foundation 值（P1-7），不再是 JSValue。
    private func awaitPromiseRaw(_ value: JSValue) async throws -> Any {
        let box = JSValueBox(value)
        // P1-4a：模块返回 undefined/null 时不对它取属性——JSC 内部 TypeError
        // 会写进 exceptionBox，污染下一次调用。非对象直接按同步结果走。
        let thenValue: JSValue? = await MainActor.run {
            guard box.value.isObject else { return nil }
            return box.value.objectForKeyedSubscript("then")
        }
        guard let thenValue, !thenValue.isUndefined, !thenValue.isNull else {
            // 不是 Promise（没有 then）就直接当结果用——有的模块同步返回数组，不包 Promise。
            // 在主线程转成 Swift 值再返回（P1-7）；undefined/null 转出来是 nil，记成 NSNull，
            // 解析侧按“不是列表/详情”抛错，与原来 toArray()/toDictionary() 为 nil 的行为一致。
            return await MainActor.run { box.value.toObject() ?? NSNull() }
        }
        let once = OnceBox()
        let contBox = ContinuationBox()
        let resolved = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValue, Error>) in
                contBox.set(continuation)
                if Task.isCancelled {
                    // once 被 onCancel 先占了时（它 take 时盒子还是空的，没 resume 到），
                    // 这里直接 resume 这次存进去的 continuation：JS 回调也被 once 拦着，
                    // 不会重复 resume；once 没被占时先占下来再 resume，同样只一次。
                    if once.tryTake() {
                        contBox.take()?.resume(throwing: CancellationError())
                    } else {
                        contBox.take()?.resume(throwing: CancellationError())
                    }
                    return
                }
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
                        let rawMessage = message.isEmpty ? "模块执行失败" : message
                        continuation.resume(throwing: Self.mapJSRejection(rawMessage))
                    }
                )
                DispatchQueue.main.async {
                    // 旧检查是死的：这个闭包跑在主队列上时 Task.isCancelled
                    // 读的是当前任务（主队列任务）的取消状态，永远 false。
                    // 用 once.isDone 判：onCancel 已抢占时直接返回，不再调 then
                    //（调了也没用——回调会被 once 拦住，continuation 永远等不到）。
                    guard !once.isDone else { return }
                    _ = box.value.invokeMethod("then", withArguments: [callbacks.fulfilled, callbacks.rejected])
                }
            }
        } onCancel: {
            if once.tryTake() {
                contBox.take()?.resume(throwing: CancellationError())
            }
        }
        // P1-7：Promise 兑现的 JSValue 也在主线程转成 Swift 值再交出去；
        // 调用方（解析）只碰 Swift/Foundation 值，不在后台线程碰 JSValue。
        // P0-1：这里不再调 httpRegistry.cancelAll()——一次模块调用失败/超时
        // 就取消同一 host 全部在途 Widget.http 请求，会杀掉竞速的另外几个样本
        // 与用户刚点的解析；在途请求只在 host 释放（deinit）时统一取消。
        return await MainActor.run { resolved.toObject() ?? NSNull() }
    }

    // MARK: - 内部：结果解析

    private func parseVideoItems(_ value: Any) throws -> [VideoItem] {
        guard let array = value as? [Any] else {
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

    /// 解析 loadDetail 返回的详情对象：复用 videoItem 的字段（id/标题/链接/封面/描述），
    /// 再取 videoUrl（首集预铸直链）与 childItems（分集）。
    private func parseDetailItem(_ value: Any) throws -> DetailItem {
        guard let dict = value as? [String: Any] else {
            throw WidgetHostError.unexpectedResult("模块返回的不是详情，看不懂")
        }
        let base = videoItem(from: dict)
        var episodes: [DetailEpisode] = []
        if let children = dict["childItems"] as? [Any] {
            for raw in children {
                guard let child = raw as? [String: Any] else { continue }
                let epLink = child["link"] as? String ?? ""
                guard !epLink.isEmpty else { continue }
                episodes.append(DetailEpisode(
                    id: (child["id"] as? String).flatMap { $0.nilIfEmpty } ?? epLink,
                    title: child["title"] as? String ?? epLink,
                    link: epLink,
                    videoURL: (child["videoUrl"] as? String).flatMap { $0.nilIfEmpty },
                    description: child["description"] as? String ?? "",
                    playerHint: child["playerHint"] as? String,
                    // 共享契约（A 路 Models 侧字段）：模块给的 referer 透传进模型，没给/空串/非字符串就是 nil，不要丢。
                    referer: (child["referer"] as? String).flatMap { $0.nilIfEmpty },
                    // 朋友桥标记透传（同 PlayLine.adStrip）。
                    adStrip: (child["adStrip"] as? Bool) ?? false,
                    // 共享契约（A 路 Models 侧字段）：模块给的 headers/cookie 透传进模型，没给就是 nil，不要丢。
                    headers: Self.headersDict(from: child),
                    cookie: Self.cookieString(from: child)
                ))
            }
        }
        // 朋友桥：loadDetail 给分类返回的相关视频（relatedItems），以前直接丢了。
        var related: [VideoItem] = []
        if let relArray = dict["relatedItems"] as? [Any] {
            for raw in relArray {
                guard let rel = raw as? [String: Any] else { continue }
                related.append(videoItem(from: rel))
            }
        }
        return DetailItem(
            id: base.id,
            title: base.title,
            link: base.link,
            coverURL: base.coverURL,
            description: base.description,
            videoURL: (dict["videoUrl"] as? String).flatMap { $0.nilIfEmpty },
            episodes: episodes,
            relatedItems: related
        )
    }

    /// 模块返回的 headers 字典 → [String: String]?（PlayLine/DetailEpisode.headers 用）。
    /// 键/值一律转字符串；不是字典、空字典 → nil（“模块没给”与“给了空字典”都记 nil，
    /// 调用方按 nil 走原有 headers 逻辑）。
    private static func headersDict(from dict: [String: Any]) -> [String: String]? {
        if let raw = dict["headers"] as? [String: Any], !raw.isEmpty {
            var out: [String: String] = [:]
            for (key, value) in raw { out[key] = "\(value)" }
            return out.isEmpty ? nil : out
        }
        if let raw = dict["headers"] as? [String: String], !raw.isEmpty {
            return raw
        }
        return nil
    }

    /// 模块返回的 cookie 字符串 → String?（不是字符串、空字符串 → nil）。
    /// 只认字符串，不强转：cookie 必须是原值，拼错一个字符就鉴权失败。
    private static func cookieString(from dict: [String: Any]) -> String? {
        (dict["cookie"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func parsePlayLines(_ value: Any) -> [PlayLine] {
        var dicts: [[String: Any]] = []
        if let array = value as? [Any] {
            dicts = array.compactMap { $0 as? [String: Any] }
        } else if let single = value as? [String: Any] {
            dicts = [single]
        }
        var lines: [PlayLine] = []
        for dict in dicts {
            guard let url = dict["url"] as? String, !url.isEmpty else { continue }
            lines.append(PlayLine(
                name: dict["name"] as? String ?? "线路",
                url: url,
                description: dict["description"] as? String ?? "",
                playerHint: dict["playerHint"] as? String,
                referer: (dict["referer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                // 朋友桥标记：模块说这条线要剥广告（onlybokep.js 透传），以前直接丢了。
                adStrip: (dict["adStrip"] as? Bool) ?? false,
                // 共享契约（A 路 Models 侧字段）：模块给的 headers/cookie 解析进模型，没给就是 nil，不要丢。
                headers: Self.headersDict(from: dict),
                cookie: Self.cookieString(from: dict)
            ))
        }
        return lines
    }
}

// MARK: - 小盒子（线程 / Sendable 用）

/// 模块 id 的盒子（chunk-1 P1-11）：桥安装时 id 还不知道，build() 取到
/// WidgetMetadata.id 后才填进去；桥里的 storage/localStorage block 每次调用
/// 时现算带 id 的前缀，不在安装时定死。全在主线程读写（JS 只在主线程跑，
/// 见文件头规矩），标 @unchecked Sendable 只是为了能进 @convention(block) 闭包。
/// 盒子本身是纯 Swift 对象，不留 JS 引用。id 只写一次（build 里 metaId 到手后），
/// 之后只读；host 释放不影响它（block 被 context 强引用，盒子随 context 走）。
private final class ModuleIDBox: @unchecked Sendable {
    var id: String = ""
}

/// 接 JS 异常信息的盒子（exceptionHandler 回调里写，takeException 里读）。
/// 全在主线程读写（JS 只在主线程跑，见文件头规矩），标 @unchecked Sendable
/// 只是为了能进定时器 work item 这类闭包。
private final class ExceptionBox: @unchecked Sendable {
    var message: String?
}

/// 原生 Promise 构造器的弱持有盒（chunk-1 P1-3）：
/// 强引用由 WidgetHost 实例持有（host → 构造器 → context，不成环）；
/// 桥里的 http.get/post block 只拿这个盒子，不直接强引用构造器——
/// block 被 context 强引用，强引用构造器会在 context↔block 间成环、
/// host 释放后也泄漏。盒子本身是纯 Swift 对象，不留 JS 引用。
private final class NativePromiseStore: @unchecked Sendable {
    weak var constructor: JSValue?
}

/// 在途定时器登记表（chunk-1 P1-6，与 HTTPRequestRegistry 同构）：
/// setTimeout/setInterval 的 DispatchWorkItem 记在这里；host deinit 时
/// cancelAll() 统一取消，不让定时器在 host 释放后还跑模块代码。
/// 上限 64 个：超限的 setTimeout/setInterval 调用直接忽略并返回 0
///（JS 侧拿到 0 这个无效 id，与原来“注册失败”的行为一致——原来超限
/// 是无上限增长，现在宁可丢掉新的也不让旧的泄漏）。
/// JS 定时器回调的间接持有盒：DispatchWorkItem 只强持盒子、不直接强持
/// callback: JSValue；cancel/cancelAll 时把盒子里的 callback 置 nil，
/// GCD 队列里已取消的 work 到期前不再钉住 JSValue/JSContext（长延时
/// 定时器取消后立即释放）。只在主线程读写 callback 时仍加锁，防
/// clearTimeout 与 tick 回调并发取。
private final class TimerCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _callback: JSValue?
    init(_ callback: JSValue) { _callback = callback }
    var callback: JSValue? {
        lock.lock()
        defer { lock.unlock() }
        return _callback
    }
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _callback = nil
    }
}

/// 一条定时器的登记项：work + 回调盒。remove（触发后）不清空盒子——
/// 正在跑的 work 还要用 callback；只有 cancel/cancelAll 清空。
private struct TimerEntry {
    var work: DispatchWorkItem
    let callbackBox: TimerCallbackBox
}

private final class TimerRegistry: @unchecked Sendable {
    /// 同时存在的定时器上限。
    static let maxTimers = 64

    private let lock = NSLock()
    private var timers: [Int: TimerEntry] = [:]
    private var counter = 0

    /// 分配 id 并登记一份 work；满上限返回 nil（调用方不得再排这个定时器）。
    /// makeWork 只负责建 DispatchWorkItem，不跑用户代码，持锁调它不会死锁。
    func register(_ callbackBox: TimerCallbackBox, _ makeWork: (Int) -> DispatchWorkItem) -> (id: Int, work: DispatchWorkItem)? {
        lock.lock()
        defer { lock.unlock() }
        guard timers.count < Self.maxTimers else { return nil }
        counter += 1
        let id = counter
        let work = makeWork(id)
        timers[id] = TimerEntry(work: work, callbackBox: callbackBox)
        return (id, work)
    }

    /// 换掉某个 id 的 work（setInterval 每 tick 建新的 work 时用）。
    /// id 已被 cancel 时不复活——清掉后不重排。返回 false = id 已不在表里，
    /// 调用方不得再排这个定时器（见 scheduleIntervalTick）。
    @discardableResult
    func store(_ work: DispatchWorkItem, for id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = timers[id] else { return false }
        entry.work = work
        timers[id] = entry
        return true
    }

    /// 该 id 是否还在表里（setInterval 的 tick 触发时查，决定停不停）。
    func contains(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timers[id] != nil
    }

    /// 从表里拿掉（setTimeout 触发一次后、setInterval 回调发现 context 没了时用），
    /// 不 cancel——work 正在跑，cancel 也没意义；不清空 callbackBox——
    /// 正在跑的 work 还要用 callback，work 跑完盒子随 work 一起释放。
    func remove(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        timers.removeValue(forKey: id)
    }

    /// 取消一个定时器（clearTimeout/clearInterval 用）：拿掉、清空回调、cancel。
    func cancel(_ id: Int) {
        lock.lock()
        let entry = timers.removeValue(forKey: id)
        lock.unlock()
        entry?.callbackBox.clear()
        entry?.work.cancel()
    }

    /// 取消全部在途定时器（host deinit 用）。
    func cancelAll() {
        lock.lock()
        let current = timers
        timers.removeAll()
        lock.unlock()
        for entry in current.values {
            entry.callbackBox.clear()
            entry.work.cancel()
        }
    }
}

/// 在途 Widget.http 请求登记表：executor Task 是 detached 的（无父子关系，
/// host 释放时没人取消），记在这里；host deinit 时统一取消，不让已死的
/// host 的请求继续跑、继续 resolve 已释放的 JSContext。
private final class HTTPRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 已跑完（defer 里的 unregister 先于 register 到达）的任务 id：
    /// Task 建好就可能在别的线程先跑完，register 时查这里，已跑完的
    /// 不再登记——否则 unregister 漏掉、已完成的任务永久滞留表里。
    /// cancelAll 时一并清掉（host 释放后旧 id 不再有意义）。
    private var finishedIDs: Set<UUID> = []

    /// 建 Task 之前先定 id（调用方 `let taskID = UUID()`），再把同一个 id
    /// 传进来登记；defer 里的 unregister 用同一个 id，锁内对齐。
    /// 无界增长修法：unregister 只在 tasks 里没这个 id（早于 register
    /// 到达）时才记 finishedIDs；register 命中 finishedIDs 时把它删掉
    ///（任务已跑完，不再登记），finishedIDs 不再随请求数永久累积。
    func register(_ task: Task<Void, Never>, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard finishedIDs.remove(id) == nil else { return }
        tasks[id] = task
    }

    func unregister(_ id: UUID) {
        lock.lock()
        if tasks.removeValue(forKey: id) == nil {
            finishedIDs.insert(id)
        }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let current = tasks
        tasks.removeAll()
        finishedIDs.removeAll()
        lock.unlock()
        for task in current.values { task.cancel() }
    }
}

/// 防 continuation 被两个回调各 resume 一次（Promise 正常只调一个，但防一手，
/// 重复 resume 会直接 crash）。
/// @unchecked Sendable：内部状态全在 NSLock 后，跨 Task/onCancel 闭包用安全
///（与 ContinuationBox 同款）；加这个标注只是让严格并发检查放行。
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// 是否已被占过（任一回调/onCancel 抢到了唯一一次 resume 权）。
    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func tryTake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// 把 CheckedContinuation 交给 withTaskCancellationHandler 的 onCancel 用：
/// onCancel 与 continuation 闭包不在同一个作用域，靠这个盒子传。
/// set/take 都加锁、take 后清掉，保证 continuation 只被 resume 一次
///（第二次 take 返回 nil；配合 OnceBox 双保险）。
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSValue, Error>?

    func set(_ continuation: CheckedContinuation<JSValue, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func take() -> CheckedContinuation<JSValue, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
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
