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
    /// fallbackTitle：WidgetMetadata 缺标题时用的兜底（一般传文件名），再没有用 id。
    init(jsSource: String, fallbackTitle: String? = nil) throws {
        let built = try Self.buildOnMainThread(jsSource: jsSource, fallbackTitle: fallbackTitle)
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

    private static func buildOnMainThread(jsSource: String, fallbackTitle: String? = nil) throws -> BuiltHost {
        if Thread.isMainThread {
            return try build(jsSource: jsSource, fallbackTitle: fallbackTitle)
        }
        // 不在主线程时同步切过去建（init 是同步的，没法 await；
        // 主线程调进来时走上面那条，不会死锁）。
        var result: Result<BuiltHost, Error>?
        DispatchQueue.main.sync {
            result = Result { try build(jsSource: jsSource, fallbackTitle: fallbackTitle) }
        }
        return try result!.get()
    }

    private static func build(jsSource: String, fallbackTitle: String? = nil) throws -> BuiltHost {
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
              let metaDict = metaValue.toDictionary() as? [String: Any] else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（缺 WidgetMetadata）")
        }
        let metaId = metaDict["id"] as? String ?? ""
        guard !metaId.isEmpty else {
            throw WidgetHostError.invalidFormat("这个脚本不是 ForwardWidget 模块格式（模块信息不完整，缺 id）")
        }
        // 标题缺失不整文件报错：先用调用方给的文件名，再退回 id。
        let metaTitle: String = {
            if let t = metaDict["title"] as? String, !t.isEmpty { return t }
            if let f = fallbackTitle, !f.isEmpty { return f }
            return metaId
        }()
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

    /// 找模块清单（超集，三路）：(1) 全局 JS_MODULES；(2) WidgetMetadata.modules；
    /// (3) 兜底扫顶层变量：任何一个元素含 id + functionName 的数组（变量名任意，比 Rex 更宽松）。
    /// 返回解析好的 [[String: Any]]，三路都找不到返回 nil。
    private static func findModuleList(in context: JSContext, metaDict: [String: Any]) -> [[String: Any]]? {
        // (1) 全局 JS_MODULES（pornjav.js 那套老格式）
        if let value = context.objectForKeyedSubscript("JS_MODULES"),
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
            guard let value = context.objectForKeyedSubscript(key),
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
    /// 前缀 fw.localstorage.）、全局 fetch（GET/POST 最小实现）、setTimeout / clearTimeout、
    /// setInterval / clearInterval、console.log / info / debug / warn / error（多参数拼接）。
    /// 模块发现三路超集、loadDetail/childItems/relatedItems 解析、分类拦截器都不在这里动。
    private static func installWidgetBridge(in context: JSContext, interceptor: CategoryRequestInterceptor) {
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
            return makeHttpGetPromise(in: context, urlString: urlString, options: options, interceptor: interceptor)
        }
        http.setValue(httpGet, forProperty: "get")

        // Widget.http.post(url, body, {headers}) -> Promise<{status, data, headers, arrayBuffer}>
        // 回值形状与 get 相同（见上面 get 的注释）；POST 不套分类拦截器（拦截只改 WP 帖子 GET）。
        // body 一般是字符串（huangguo 现铸签名传 "{}"）；是对象时转 JSON。
        let httpPost: @convention(block) (String, JSValue?, JSValue?) -> JSValue = { [weak context] urlString, body, options in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放，无法发起请求")
            }
            return makeHttpPostPromise(in: context, urlString: urlString, body: body, options: options)
        }
        http.setValue(httpPost, forProperty: "post")
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
        // Widget.storage.remove(key) / clear()：与 get/set 同一套 UserDefaults 前缀。
        // clear 只清 fw.storage. 前缀的 key，不动 localStorage（前缀不同）与别的 key。
        let clearKeysWithPrefix: (String) -> Void = { prefix in
            let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
            for key in keys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let storageRemove: @convention(block) (String) -> Void = { key in
            UserDefaults.standard.removeObject(forKey: "fw.storage." + key)
        }
        let storageClear: @convention(block) () -> Void = {
            clearKeysWithPrefix("fw.storage.")
        }
        storage.setValue(storageGet, forProperty: "get")
        storage.setValue(storageSet, forProperty: "set")
        storage.setValue(storageRemove, forProperty: "remove")
        storage.setValue(storageClear, forProperty: "clear")
        widget.setValue(storage, forProperty: "storage")

        // localStorage：与 Widget.storage 同款持久化（UserDefaults），前缀分开
        //（fw.localstorage.，与 fw.storage. 互不干扰），值按字符串存。
        // getItem 不存在返回 JS null（与 Widget.storage.get 同款，模块里 `if (raw)` 判空能正常工作）。
        // 只实现 getItem/setItem/removeItem/clear（任务定的四件套）；length/key(index) 未实现。
        let localStorage = JSValue(newObjectIn: context)!
        let localStorageGetItem: @convention(block) (String) -> JSValue = { [weak context] key in
            guard let context else {
                fatalError("WidgetHost: JSContext 已释放")
            }
            if let value = UserDefaults.standard.string(forKey: "fw.localstorage." + key) {
                return JSValue(object: value, in: context)!
            }
            return JSValue(nullIn: context)!
        }
        let localStorageSetItem: @convention(block) (String, JSValue) -> Void = { key, value in
            UserDefaults.standard.set(value.toString(), forKey: "fw.localstorage." + key)
        }
        let localStorageRemoveItem: @convention(block) (String) -> Void = { key in
            UserDefaults.standard.removeObject(forKey: "fw.localstorage." + key)
        }
        let localStorageClear: @convention(block) () -> Void = {
            clearKeysWithPrefix("fw.localstorage.")
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

        // setTimeout / clearTimeout：裸 JavaScriptCore 没有这两个（浏览器才有），
        // 但模块里常用来做超时兜底（比如 onlybokep 封面补全的 8 秒封顶）；
        // 没有它模块调 setTimeout 会直接报 ReferenceError。补一个最小实现：
        // 主线程延时回调，返回一个数字 id 供 clearTimeout 取消。
        // 注意：回调里 JSContext 可能已释放，调之前先判空，不 crash。
        var timerCounter = 0
        var timers: [Int: DispatchWorkItem] = [:]
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak context] callback, delayMs in
            timerCounter += 1
            let id = timerCounter
            // delay 非数/没传时按 0 算（JS 调 setTimeout(fn) 不带延迟时 JSC 传过来的就是 NaN）。
            let delay = delayMs.isFinite ? delayMs : 0
            let work = DispatchWorkItem {
                timers.removeValue(forKey: id)
                guard let context, !callback.isUndefined, !callback.isNull else { return }
                callback.call(withArguments: [])
            }
            timers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0, execute: work)
            return id
        }
        let clearTimeout: @convention(block) (Int) -> Void = { id in
            timers.removeValue(forKey: id)?.cancel()
        }
        context.setObject(setTimeout as @convention(block) (JSValue, Double) -> Int, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeout as @convention(block) (Int) -> Void, forKeyedSubscript: "clearTimeout" as NSString)

        // setInterval / clearInterval：与上面 setTimeout/clearTimeout 同款机制
        //（主线程延时回调、数字 id、DispatchWorkItem，共用同一个 timerCounter/timers 表，
        // 所以 clearTimeout 也能停 interval、clearInterval 也能停 timeout，与浏览器一致）。
        // 每次 tick 都是一次新的 DispatchWorkItem：tick 触发时先看 id 是否还在表里
        //（clearInterval 已把它拿掉就不触发也不重排），回调完、id 还在表里才排下一次，
        // 所以回调里调 clearInterval（包括自己清自己）能停。delay 下限 4ms，
        // 免得 setInterval(fn, 0) 在主线程空转（浏览器同款钳制；setTimeout 不动，仍按 0 算）。
        let setInterval: @convention(block) (JSValue, Double) -> Int = { [weak context] callback, delayMs in
            timerCounter += 1
            let id = timerCounter
            // delay 非数/没传时按 4ms 算（JSC 传过来的 NaN 与 setTimeout 同款处理，只是下限不同）。
            let delay = delayMs.isFinite ? max(delayMs, 4) : 4
            var scheduleNext: (() -> Void)!
            scheduleNext = {
                let work = DispatchWorkItem {
                    // 已被 clear（注册表里没这个 id）就停，不触发也不重排。
                    guard timers[id] != nil else { return }
                    guard let context, !callback.isUndefined, !callback.isNull else {
                        timers.removeValue(forKey: id)
                        return
                    }
                    callback.call(withArguments: [])
                    // 回调里可能调了 clearInterval；只有 id 还在表里才排下一次。
                    if timers[id] != nil {
                        scheduleNext()
                    }
                }
                timers[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000.0, execute: work)
            }
            scheduleNext()
            return id
        }
        let clearInterval: @convention(block) (Int) -> Void = { id in
            timers.removeValue(forKey: id)?.cancel()
        }
        context.setObject(setInterval as @convention(block) (JSValue, Double) -> Int, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(clearInterval as @convention(block) (Int) -> Void, forKeyedSubscript: "clearInterval" as NSString)

        context.setObject(widget, forKeyedSubscript: "Widget" as NSString)

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
                            url: requestURL,
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
    }

    /// 从 context 取 Promise 构造器，用 executor block 造一个 JS Promise。
    /// executor 被 Promise 构造器同步调用，交出 resolve/reject；
    /// Swift 拿着它们去后台发请求，完事回主线程结算。
    private static func makeHttpGetPromise(in context: JSContext, urlString: String, options: JSValue?, interceptor: CategoryRequestInterceptor) -> JSValue {
        guard let promiseConstructor = context.objectForKeyedSubscript("Promise"),
              !promiseConstructor.isUndefined else {
            fatalError("WidgetHost: JS 环境里没有 Promise")
        }
        let headers = headers(from: options)
        let timeout = timeoutInterval(from: options)
        let effectiveURL = interceptor.rewrittenURL(for: urlString) ?? urlString
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            let box = JSCallbackBox(resolve: resolve, reject: reject)
            Task {
                do {
                    let (status, data, responseHeaders, rawData) = try await Self.fetchHTTP(
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
                        if let buffer = WidgetHost.jsArrayBuffer(from: rawData, in: ctx) {
                            result.setValue(buffer, forProperty: "arrayBuffer")
                        }
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

    private static func makeHttpPostPromise(in context: JSContext, urlString: String, body: JSValue?, options: JSValue?) -> JSValue {
        guard let promiseConstructor = context.objectForKeyedSubscript("Promise"),
              !promiseConstructor.isUndefined else {
            fatalError("WidgetHost: JS 环境里没有 Promise")
        }
        let headers = headers(from: options)
        let timeout = timeoutInterval(from: options)
        let bodyData = httpBodyData(from: body)
        let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            let box = JSCallbackBox(resolve: resolve, reject: reject)
            Task {
                do {
                    let (status, data, responseHeaders, rawData) = try await Self.fetchHTTP(
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
                        if let buffer = WidgetHost.jsArrayBuffer(from: rawData, in: ctx) {
                            result.setValue(buffer, forProperty: "arrayBuffer")
                        }
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

    /// 从 options 提取超时时间（兼容毫秒如 8000 和秒如 8）；未传时默认 12 秒，
    /// 让模块在 30 秒 awaitPromise 窗口内至少有余量切到备用镜像域名。
    private static func timeoutInterval(from options: JSValue?) -> TimeInterval {
        guard let raw = options?.objectForKeyedSubscript("timeout"),
              !raw.isUndefined, !raw.isNull else {
            return 12
        }
        let value = raw.toDouble()
        guard value.isFinite, value > 0 else { return 12 }
        let seconds = value > 120 ? (value / 1000.0) : value
        return min(max(seconds, 3), 25)
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
    ) async throws -> (status: Int, data: Any, responseHeaders: [String: String], rawData: Data) {
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
        return (status, httpDataObject(from: raw), responseHeaders(from: response), raw)
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
    /// 边界：按字节数组过桥，O(n) 装箱；16 MiB 以上不建（避免一次巨额装箱冲内存），
    /// 此时 .arrayBuffer 属性直接缺省，data（文本/JSON）不受影响。
    /// 返回 nil = 没建出来，调用方直接不设该属性，不抛错。
    private static func jsArrayBuffer(from raw: Data, in context: JSContext) -> JSValue? {
        guard raw.count <= 16 * 1024 * 1024 else { return nil }
        guard let helper = context.objectForKeyedSubscript("__fwArrayBufferFromBytes"),
              !helper.isUndefined, !helper.isNull else { return nil }
        let bytes: [Int] = raw.map { Int($0) }
        guard let jsArray = JSValue(object: bytes, in: context) else { return nil }
        guard let buffer = helper.call(withArguments: [jsArray]),
              !buffer.isUndefined, !buffer.isNull else { return nil }
        return buffer
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

    /// 进模块时后台竞速：每个模块、每次打开软件到关闭软件，最多自动竞速一次。
    /// 旧行为是“一个 host 只跑一次”，但 loadHost 每次都 new host，等于每次进
    /// 模块、从封面页返回都重竞（下测试片段抢网，感觉慢）。
    /// 本会话已竞过 → 不再跑，直接用会话里定的首选线（preferredLine 兜底读它）。
    /// force=true（检测页“重新竞速”）无视会话去重，强制重测一次。
    /// 调固定验线拿样本，各调 loadResource 解线计时，最快且能播的线记为本次首选线。
    /// 没分出胜负 / 两条都死 / 无固定验线 → preferredLine 保持 nil，按现有逻辑。
    /// 不抛错、不阻塞调用方；后台跑，跑完写 preferredLine，并把结果
    /// （胜出线、各线耗时）记到 SourceStore，供检测页显示。
    /// 播放器读 preferredLine：首选 memojav 走快路径直拼；首选 nmcorp 先走 loadResource 拿 nmcorp 线。
    func raceLinesIfNeeded(force: Bool = false) {
        guard !didRaceLines else { return }
        didRaceLines = true
        // 本会话已竞过：不再下测试片段抢网，首选线由 preferredLine 兜底读会话缓存。
        if !force, SourceStore.shared.hasRacedThisSession(meta.id) {
            return
        }
        // 同步先把 id 记进本会话已竞集合：重入瞬间（进模块又立刻返回再进）
        // 两个 host 不会都开竞。手动重竞也记，防并发的自动竞速插进来。
        SourceStore.shared.markRaceStarted(for: meta.id)
        Task.detached { [weak self] in
            guard let self else { return }
            let outcome = await self.runLineRace()
            self.raceLock.lock()
            self._preferredLine = outcome.winner
            self.raceLock.unlock()
            // 结果记到 SourceStore（检测页显示用；竞速算法本身不动）。
            // key 是 WidgetMeta.id，与 SourceRecord.id 同一个值。
            await SourceStore.shared.recordRaceResult(
                LineRaceResult(
                    winnerLabel: outcome.winner?.displayLabel,
                    timings: outcome.timings,
                    racedAt: Date(),
                    note: outcome.note
                ),
                for: self.meta.id
            )
            // 首选线进会话缓存：同会话再进这个模块的新 host 直接用，不重竞。
            SourceStore.shared.markRaceFinished(for: self.meta.id, preferredLine: outcome.winner)
        }
    }

    /// 一次竞速的内部结果：胜出线 + 每种线的最快耗时 + 没分出胜负的原因。
    /// 算法与原来一字不差（并发解线、每样本第一条可播线定种类、最快获胜）；
    /// 只是把原来只留胜者、其余丢掉的计时也收起来，记到 SourceStore 供检测页显示。
    private struct LineRaceOutcome {
        let winner: PreferredLine?
        let timings: [LineTiming]
        let note: String?
    }

    /// 真正跑竞速：固定验线取样本，并发调 loadResource 解线计时。
    /// 每样本取第一条能播的线（.m3u8 或 .mp4）定种类；最快的那种线获胜。
    /// 没样本 / 都解不出 / 种类认不出 → winner 为 nil（按现有逻辑），note 写清原因。
    /// 并发跑：两条线同时解，总耗时取最慢的一条，不叠加。
    private func runLineRace() async -> LineRaceOutcome {
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
        var best: (kind: PreferredLine, elapsed: TimeInterval)?
        var fastestByKind: [PreferredLine: TimeInterval] = [:]
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
                if let prev = fastestByKind[result.0] {
                    fastestByKind[result.0] = min(prev, result.1)
                } else {
                    fastestByKind[result.0] = result.1
                }
                if best == nil || result.1 < best!.elapsed {
                    best = result
                }
            }
        }
        let timings = fastestByKind
            .map { LineTiming(kind: $0.key.displayLabel, milliseconds: Int($0.value * 1000)) }
            .sorted { $0.milliseconds < $1.milliseconds }
        guard let winner = best?.kind else {
            return LineRaceOutcome(winner: nil, timings: timings, note: "样本都解不出可播线路")
        }
        return LineRaceOutcome(winner: winner, timings: timings, note: nil)
    }

    /// 调指定模块的列表函数，返回视频列表。
    /// requiresWebView 的模块也能跑：列表本身是 JS 调 API，不依赖播放器；
    /// 播的时候按线路类型路由（直链→AVPlayer，嵌入页→解流/WebView）。
    func loadList(moduleId: String, page: Int) async throws -> [VideoItem] {
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
        let result = try await callFunction("loadDetail", args: [link])
        return try parseDetailItem(result)
    }

    /// 调 WidgetMetadata.search.functionName（一般是 searchVideos）。
    /// requiresWebView 的模块也能跑（搜索是 JS 调 API，与播放器无关）。
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
            } catch let e as CancellationError {
                requestInterceptor.disarm(token: token)
                throw e
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
        request.timeoutInterval = 12
        let headers = NetConstants.mergeHeaders(
            base: NetConstants.defaultBrowserHeaders,
            overrides: ["Accept": "application/json"]
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (raw, response) = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "wp-direct",
            preservedHeaders: headers,
            timeout: 12
        )
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
    /// 超时后任务组 cancel 会一路传进 awaitPromiseRaw 的取消处理，
    /// JS 侧的等待随即收尾，不再空转占着连接池（旧逻辑：超时只 throw，
    /// continuation 没人 resume，JS 的 fetch 还在后台跑）。
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
    /// 取消：withTaskCancellationHandler + ContinuationBox。取消与 JS 回调共用一个
    /// OnceBox，谁先到谁 resume，另一个直接丢弃，绝不重复 resume。
    /// 两个竞态都处理了：① 任务进函数时已取消——onCancel 可能在 continuation 存进
    /// 盒子前就跑，所以存进去后要再查一次 Task.isCancelled；② 主队列的 then 调度
    /// 晚于取消——DispatchQueue.main.async 里先查取消再调 then，不给已取消的
    /// Promise 再挂回调。
    private func awaitPromiseRaw(_ value: JSValue) async throws -> JSValue {
        let box = JSValueBox(value)
        let thenValue = await MainActor.run { box.value.objectForKeyedSubscript("then") }
        guard let thenValue, !thenValue.isUndefined, !thenValue.isNull else {
            return value
        }
        let once = OnceBox()
        let contBox = ContinuationBox()
        return try await withTaskCancellationHandler {
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
                        continuation.resume(throwing: WidgetHostError.callFailed(message.isEmpty ? "模块执行失败" : message))
                    }
                )
                DispatchQueue.main.async {
                    if Task.isCancelled {
                        if once.tryTake() {
                            contBox.take()?.resume(throwing: CancellationError())
                        }
                        return
                    }
                    _ = box.value.invokeMethod("then", withArguments: [callbacks.fulfilled, callbacks.rejected])
                }
            }
        } onCancel: {
            if once.tryTake() {
                contBox.take()?.resume(throwing: CancellationError())
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

    /// 解析 loadDetail 返回的详情对象：复用 videoItem 的字段（id/标题/链接/封面/描述），
    /// 再取 videoUrl（首集预铸直链）与 childItems（分集）。
    private func parseDetailItem(_ value: JSValue) throws -> DetailItem {
        guard let dict = value.toDictionary() as? [String: Any] else {
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
