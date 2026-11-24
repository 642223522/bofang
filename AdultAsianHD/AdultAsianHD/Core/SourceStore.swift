import Foundation
import Security
import Network
import AVFoundation

/// 源管理：导入 / 删除 / 导出 / 码云同步。
/// 源文件：Documents/Sources/<fileName>（一个模块一个 .js 文件）；
/// 清单：Documents/sources.json（JSON 编码 [SourceRecord]），启动时加载。
/// 新装 App 是空的——包里不带任何 JS 源。
/// @unchecked Sendable：状态只在主线程改（MainActor.run / 主线程同步），
/// 跨 Task 调用 importData / syncFromGitee 时不产生 Sendable 警告。
final class SourceStore: ObservableObject, @unchecked Sendable {

    static let shared = SourceStore()

    @Published private(set) var sources: [SourceRecord] = []
    /// 上次码云同步成功的时间（存 UserDefaults，源页显示用）
    @Published private(set) var lastSyncAt: Date?
    /// 自检结果：[源 id: 结果]，持久化在 Documents/check-results.json
    /// （与 sources.json 分开，不动 SourceRecord）。
    @Published private(set) var checkResults: [String: SourceCheckResult] = [:]

    private let fileManager = FileManager.default
    private let sourcesDirectory: URL
    private let manifestURL: URL
    private let checkResultsURL: URL

    private let giteeTokenKey = "gitee.token"
    private let lastSyncDefaultsKey = "gitee.lastSyncAt"
    /// 码云仓库与坏模块分支：上传只动 broken 分支，绝不动 js 分支。
    private let giteeRepo = "individual-freedom/ziyong-ziliao-beifang"
    private let brokenBranch = "broken"

    // MARK: - 自检后台任务（让路 + 断点续跑）

    /// 正在跑的后台自动自检 Task（轻检或深探针）。用户一点屏幕/切页/开始播放，
    /// 或 App 进后台，立刻 cancel；下次从断点接着跑（增量逻辑跳过已测过的）。
    private var autoCheckTask: Task<Void, Never>?
    /// 后台自动自检的轮次间隔：轻检 12 小时一轮；深探针 7 天一轮（分开轮次）。
    private let autoCheckInterval: TimeInterval = 12 * 3600
    private let deepProbeInterval: TimeInterval = 7 * 24 * 3600
    /// 上次自动轻检 / 上次深探针轮次的时间（UserDefaults）。
    private let lastAutoCheckDefaultsKey = "selfcheck.lastAutoCheckAt"
    private let lastDeepProbeDefaultsKey = "selfcheck.lastDeepProbeAt"
    /// “仅 Wi-Fi 时自动自检”开关（UserDefaults，默认关）。
    /// 只影响后台自动自检；手动自检和下载不受影响（下载仍可走流量）。
    static let wifiOnlyAutoCheckDefaultsKey = "selfcheck.wifiOnlyAutoCheck"
    /// 快扫每步超时（毫秒）：超时即判该步失败，不让一个慢源卡住整轮。
    static let stepTimeoutMilliseconds = 6000
    /// 深探针超时（秒）：静音真播 15 秒不出画即失败。
    private static let deepProbeTimeoutSeconds: TimeInterval = 15

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.sourcesDirectory = documents.appendingPathComponent("Sources", isDirectory: true)
        self.manifestURL = documents.appendingPathComponent("sources.json")
        self.checkResultsURL = documents.appendingPathComponent("check-results.json")
        try? fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        if let timestamp = UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? TimeInterval {
            self.lastSyncAt = Date(timeIntervalSince1970: timestamp)
        }
        loadManifest()
        loadCheckResults()
    }

    // MARK: - 清单读写

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let records = try? JSONDecoder().decode([SourceRecord].self, from: data) else {
            self.sources = []
            return
        }
        self.sources = records
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - 导入（验收第一项）

    /// 核心入口：文件 / 链接 / 同步下载到的 data 都走这里。
    /// 顺序：转 UTF-8 文本 → WidgetHost.validate 校验格式（不合格直接失败，人话原因）
    /// → 文件名冲突自动改名（xxx-2.js）→ 写文件 → 更新清单 → 主线程刷新 sources。
    func importData(_ data: Data, fileName: String, origin: String) async -> Result<SourceRecord, ImportError> {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.unreadable)
        }
        let validation = WidgetHost.validate(jsSource: text, fallbackTitle: fileName)
        guard validation.ok, let meta = validation.meta else {
            return .failure(.notModule(validation.error ?? "这个脚本不是 ForwardWidget 模块格式"))
        }
        // 去重：同模块 id 或同站点域名已存在，不重复添加（提示已存在相同源并跳过）
        if let duplicate = await existingDuplicate(for: meta, jsSource: text) {
            return .failure(.duplicate(duplicate.title))
        }
        let finalName = uniqueFileName(sanitizedFileName(fileName, fallback: meta.id))
        let fileURL = sourcesDirectory.appendingPathComponent(finalName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return .failure(.unreadable)
        }
        let record = SourceRecord(
            id: meta.id,
            title: meta.title,
            fileName: finalName,
            origin: origin,
            country: countryGuess(for: meta),
            version: meta.version,
            importedAt: Date()
        )
        await MainActor.run {
            self.sources.append(record)
            self.saveManifest()
        }
        return .success(record)
    }

    /// 从链接导入 .js：15 秒超时下载，下载到的 data 走 importData。
    /// 文件名取 URL 最后一段（没有就用模块 id + .js，importData 里兜底）。
    func importURL(_ urlString: String) async -> Result<SourceRecord, ImportError> {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            return .failure(.network("这个链接格式不对，复制完整的 http(s) 链接再试"))
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        let data: Data
        do {
            let (fetched, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.network("下载失败（服务器返回 HTTP \(http.statusCode)）"))
            }
            data = fetched
        } catch {
            return .failure(.network("下载失败：\(friendlyNetworkError(error))"))
        }
        var name = url.lastPathComponent
        if name == "/" || name.isEmpty {
            name = ""
        }
        return await importData(data, fileName: name, origin: "外部导入")
    }

    // MARK: - 去重（导入时 + 自检时）

    /// 从 JS 源码提取站点域名：优先 WidgetMetadata.site；其次 SITE / BASE_URL 变量；
    /// 再其次含 /wp-json/ 的 URL 的 host。归一化：小写、去 www. 前缀。
    /// 提不出返回 nil（该模块只按模块 id 去重）。
    static func siteDomain(fromJS js: String, metaSite: String? = nil) -> String? {
        if let site = metaSite, let host = URL(string: site)?.host, !host.isEmpty {
            return normalizedDomain(host)
        }
        // SITE / BASE_URL 变量，如 var SITE = "https://pornjav.tv";
        if let urlString = firstMatch(in: js, pattern: "(?:var|let|const)\\s+(?:SITE|site|BASE_URL|baseUrl|HOST|host|DOMAIN|domain)\\s*=\\s*[\"'](https?://[^\"'\\s]+)"),
           let host = URL(string: urlString)?.host, !host.isEmpty {
            return normalizedDomain(host)
        }
        // 含 /wp-json/ 的 URL（如 WP API 地址），取它的 host
        if let urlString = firstMatch(in: js, pattern: "https?://[A-Za-z0-9.-]+[^\"'\\s]*?/wp-json/"),
           let host = URL(string: urlString)?.host, !host.isEmpty {
            return normalizedDomain(host)
        }
        return nil
    }

    /// 某源的站点域名（读它的 JS 文件提取；提不出为 nil）。
    func siteDomain(for source: SourceRecord) -> String? {
        guard let js = jsSource(for: source) else { return nil }
        return Self.siteDomain(fromJS: js)
    }

    /// 找已存在的重复源：同模块 id，或同站点域名（读对方 JS 文件算域名）。
    /// 返回重复的那个源（没有返回 nil）。同 id 优先于同域名。
    /// 同一站点/内容池被不同域名或不同模块重复收录时，只留一个。
    func existingDuplicate(for meta: WidgetMeta, jsSource jsText: String) async -> SourceRecord? {
        let all = await MainActor.run { self.sources }
        if let sameId = all.first(where: { $0.id == meta.id }) {
            return sameId
        }
        guard let domain = Self.siteDomain(fromJS: jsText, metaSite: meta.site) else { return nil }
        for source in all {
            guard let js = jsSource(for: source),
                  Self.siteDomain(fromJS: js) == domain else { continue }
            return source
        }
        return nil
    }

    /// 正则取第一个匹配的第 1 个捕获组（没有捕获组取整个匹配）；没有返回 nil。
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        let groupIndex = match.numberOfRanges > 1 ? 1 : 0
        let range = match.range(at: groupIndex)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// 域名归一化：小写、去 www. 前缀（pornjav.tv 与 www.pornjav.tv 算同一个站）。
    private static func normalizedDomain(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    // MARK: - 删除 / 导出 / 取用

    /// 删文件 + 清单 + 该源的自检记录。文件删不掉也不报错，清单照样清。
    func delete(_ source: SourceRecord) {
        try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(source.fileName))
        let update = {
            self.sources.removeAll { $0.fileName == source.fileName }
            self.saveManifest()
            self.checkResults.removeValue(forKey: source.id)
            self.saveCheckResults()
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.sync(execute: update)
        }
    }

    /// 供分享单用：返回 Documents/Sources 下的文件 URL，文件不存在返回 nil。
    func exportURL(for source: SourceRecord) -> URL? {
        let url = sourcesDirectory.appendingPathComponent(source.fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func jsSource(for source: SourceRecord) -> String? {
        try? String(contentsOf: sourcesDirectory.appendingPathComponent(source.fileName), encoding: .utf8)
    }

    func loadHost(for source: SourceRecord) throws -> WidgetHost {
        guard let text = jsSource(for: source) else {
            throw ImportError.unreadable
        }
        return try WidgetHost(jsSource: text, fallbackTitle: source.fileName)
    }

    /// 按模块 title/description 猜国家（主页按国家分框用）。
    /// 提到 JAV / 日本 / pornjav → “日本”；提到韩国 → “韩国”；否则“其他”。
    func countryGuess(for meta: WidgetMeta) -> String {
        let text = (meta.title + " " + meta.description).lowercased()
        if text.contains("jav") || text.contains("日本") || text.contains("pornjav") || text.contains("japan") {
            return "日本"
        }
        if text.contains("韩国") || text.contains("korean") || text.contains("korea") {
            return "韩国"
        }
        if text.contains("泰国") || text.contains("thai") {
            return "泰国"
        }
        if text.contains("国产") || text.contains("中国") {
            return "中国"
        }
        return "其他"
    }

    // MARK: - 码云同步（js 分支重建后用）

    /// 从 Gitee“自用资料备份”js 分支拉 .js 源。
    /// 传空 token 时用 Keychain 里存过的；两个都没有就失败，提示先填 Token。
    /// 同步是覆盖式：同名旧源先清掉再导入，避免反复同步产生 xxx-2.js。
    /// 返回成功导入的个数；失败给人话原因。
    func syncFromGitee(token: String) async -> Result<Int, ImportError> {
        let effectiveToken = token.isEmpty ? (KeychainHelper.load(forKey: giteeTokenKey) ?? "") : token
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能同步"))
        }
        if !token.isEmpty {
            KeychainHelper.save(token, forKey: giteeTokenKey)
        }

        guard let listURL = URL(string: "https://gitee.com/api/v5/repos/individual-freedom/ziyong-ziliao-beifang/contents/?ref=js") else {
            return .failure(.network("同步地址不对"))
        }
        var listRequest = URLRequest(url: listURL)
        listRequest.setValue("token \(effectiveToken)", forHTTPHeaderField: "Authorization")
        listRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        listRequest.timeoutInterval = 30
        let listData: Data
        do {
            let (data, response) = try await URLSession.shared.data(for: listRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .failure(.network("Token 不对或没权限（HTTP \(http.statusCode)），检查一下 Token"))
                }
                return .failure(.network("码云返回 HTTP \(http.statusCode)，稍后再试"))
            }
            listData = data
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }
        guard let entries = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else {
            return .failure(.network("码云返回的数据看不懂，稍后再试"))
        }
        let jsFiles = entries.filter {
            ($0["type"] as? String) == "file" && (($0["name"] as? String)?.hasSuffix(".js") ?? false)
        }
        guard !jsFiles.isEmpty else {
            return .failure(.network("码云 js 分支里没有 .js 文件"))
        }

        var imported = 0
        var firstError: String?
        for entry in jsFiles {
            guard let name = entry["name"] as? String else { continue }
            let rawURLString = entry["download_url"] as? String
                ?? "https://gitee.com/individual-freedom/ziyong-ziliao-beifang/raw/js/\(name)"
            guard let rawURL = URL(string: rawURLString) else { continue }

            let existing = await MainActor.run { self.sources.first(where: { $0.fileName == name }) }
            if let existing {
                try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(existing.fileName))
                await MainActor.run {
                    self.sources.removeAll { $0.fileName == existing.fileName }
                    self.saveManifest()
                }
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: rawURL)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if firstError == nil { firstError = "下载 \(name) 失败（HTTP \(http.statusCode)）" }
                    continue
                }
                switch await importData(data, fileName: name, origin: "gitee") {
                case .success:
                    imported += 1
                case .failure(let error):
                    // 已存在相同源：跳过，不算失败（同步不重复加）
                    if case .duplicate = error {
                        // 什么都不做，继续下一个文件
                    } else if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            } catch {
                if firstError == nil { firstError = friendlyNetworkError(error) }
                continue
            }
        }

        if imported == 0 {
            return .failure(.network(firstError ?? "同步到的源都下载失败"))
        }
        await MainActor.run {
            let now = Date()
            self.lastSyncAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.lastSyncDefaultsKey)
        }
        return .success(imported)
    }

    /// 读 Keychain 里存过的 Gitee Token（同步表单预填 / 上传坏模块用）。
    func loadSavedGiteeToken() -> String? {
        KeychainHelper.load(forKey: giteeTokenKey)
    }

    // MARK: - 自检（固定验线探针：五步验真 + 增量 + 去重 + 让路 + 深探针）

    /// 自检结果持久化：Documents/check-results.json。
    private func loadCheckResults() {
        guard let data = try? Data(contentsOf: checkResultsURL),
              let decoded = try? JSONDecoder().decode([String: SourceCheckResult].self, from: data) else {
            self.checkResults = [:]
            return
        }
        self.checkResults = decoded
    }

    private func saveCheckResults() {
        guard let data = try? JSONEncoder().encode(checkResults) else { return }
        try? data.write(to: checkResultsURL, options: .atomic)
    }

    private func storeCheckResult(_ result: SourceCheckResult, for sourceId: String) async {
        await MainActor.run {
            self.checkResults[sourceId] = result
            self.saveCheckResults()
        }
    }

    /// JS 内容指纹（FNV-1a 64 位哈希转十六进制）：增量自检用。
    /// 内容没变指纹就不变，没动过的源跳过不重测。
    static func fingerprint(of jsSource: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in jsSource.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// 某源当前 JS 的指纹（读文件算；读不到为 nil）。
    func fingerprint(for source: SourceRecord) -> String? {
        guard let js = jsSource(for: source) else { return nil }
        return Self.fingerprint(of: js)
    }

    /// 若已取消则抛 CancellationError（不把“取消”记成失败结果，
    /// 断点续跑时这个源重测）。
    private func throwIfCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    /// 带超时的操作：超时即 throw CheckStepError.timeout。
    /// 快扫每步默认 6000ms，超时判该步失败，不让一个慢源卡住整轮。
    private func withStepTimeout<T>(_ milliseconds: Int = stepTimeoutMilliseconds, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                throw CheckStepError.timeout(milliseconds)
            }
            guard let result = try await group.next() else {
                throw CheckStepError.timeout(milliseconds)
            }
            group.cancelAll()
            return result
        }
    }

    /// 把一步的 error 翻成人话原因：超时 / HTTP 状态 / 其他。
    private func checkReason(for error: Error) -> String {
        if let stepError = error as? CheckStepError {
            switch stepError {
            case .timeout(let ms): return "\(ms)ms 超时"
            case .http(let code): return "HTTP \(code)"
            case .badURL: return "URL 非法"
            }
        }
        if error is CancellationError { return "已取消" }
        return error.localizedDescription
    }

    /// GET 一个 URL 的 HTTP 状态码（详情步用）。iPhone UA。
    private static func httpStatus(of urlString: String) async throws -> Int {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// GET 一个 URL 的全文（播单步用，取 m3u8 文本）。referer 传帖子链接（nmcorp 这类防盗链的线要它）。
    private static func httpBody(of urlString: String, referer: String? = nil) async throws -> String {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CheckStepError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Range 取一个 URL 的前 length 字节（首片步用；MP4 也用它取首字节）。
    private static func httpRangeData(of urlString: String, length: Int, referer: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) || http.statusCode == 206 else {
            throw CheckStepError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    /// m3u8 文本里第一个媒体引用（变体播单或分片 URL），按 baseURL 解析相对地址。
    /// 跳过 # 开头的行与空行；取第一个非 # 行。
    private static func firstMediaURL(in playlistText: String, baseURL: String) -> String? {
        guard let base = URL(string: baseURL) else { return nil }
        for line in playlistText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteString {
                return resolved
            }
            return trimmed
        }
        return nil
    }

    /// Data 前段是否含 "ftyp"（MP4 签名）。
    private static func dataContainsFTYP(_ data: Data) -> Bool {
        data.range(of: Data("ftyp".utf8)) != nil
    }

    /// 五步验真（对一个源）：列表→详情→解析→播单→首片，每步 6000ms 超时。
    /// 固定验线取样本；每个样本顺次跑详情→解析→播单→首片（列表步只做一次）。
    /// 全部样本走完五步才算 ok；任一样本死在某步即 failed，记死在哪步 + 原因。
    /// 返回 SourceCheckResult（steps = 决定本次结果的那个样本的五步；fingerprint = 当前 JS 指纹）。
    /// 深探针不由这里填（单独轮次，由 runDeepProbeRound 写）。
    /// 取消时抛 CancellationError（不记失败结果，断点续跑时重测）。
    private func runFiveStepCheck(host: WidgetHost, source: SourceRecord) async throws -> SourceCheckResult {
        let fingerprint = self.fingerprint(for: source)
        // 1. 列表：固定验线取样本
        let listStart = Date()
        let listElapsed = { Int(Date().timeIntervalSince(listStart) * 1000) }
        guard let probe = host.fixedProbeModule() else {
            let step = CheckStepResult(name: "列表", passed: false, reason: "这个源没有固定验线模块", milliseconds: listElapsed())
            return SourceCheckResult(status: .failed, failedLines: ["固定验线": "这个源没有固定验线模块"], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: "这个源没有固定验线模块", sourceFingerprint: fingerprint)
        }
        let samples: [VideoItem]
        do {
            samples = try await withStepTimeout { try await host.loadList(moduleId: probe.id, page: 1) }
        } catch {
            try throwIfCancelled()
            let reason = checkReason(for: error)
            let step = CheckStepResult(name: "列表", passed: false, reason: reason, milliseconds: listElapsed())
            return SourceCheckResult(status: .failed, failedLines: ["固定验线": reason], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: reason, sourceFingerprint: fingerprint)
        }
        guard !samples.isEmpty else {
            let step = CheckStepResult(name: "列表", passed: false, reason: "固定验线没有返回样本", milliseconds: listElapsed())
            return SourceCheckResult(status: .failed, failedLines: ["固定验线": "固定验线没有返回样本"], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: "固定验线没有返回样本", sourceFingerprint: fingerprint)
        }
        let listStep = CheckStepResult(name: "列表", passed: true, reason: nil, milliseconds: listElapsed())

        // 每个样本顺次跑详情→解析→播单→首片
        var failedLines: [String: String] = [:]
        var decidingSteps: [CheckStepResult] = [listStep]
        var firstFailure: (step: String, reason: String)?
        for (index, sample) in samples.enumerated() {
            try throwIfCancelled()
            let steps = try await runSampleSteps(host: host, sample: sample)
            if index == 0 { decidingSteps = [listStep] + steps }
            if let failed = steps.first(where: { !$0.passed }) {
                failedLines[sample.title] = "死在\(failed.name)步：\(failed.reason ?? "")"
                if firstFailure == nil {
                    firstFailure = (failed.name, failed.reason ?? "")
                    decidingSteps = [listStep] + steps
                }
            }
        }
        if let failure = firstFailure {
            return SourceCheckResult(status: .failed, failedLines: failedLines, checkedAt: Date(), steps: decidingSteps, failedStep: failure.step, failedReason: failure.reason, sourceFingerprint: fingerprint)
        }
        return SourceCheckResult(status: .ok, failedLines: [:], checkedAt: Date(), steps: decidingSteps, failedStep: nil, failedReason: nil, sourceFingerprint: fingerprint)
    }

    /// 一个样本的详情→解析→播单→首片（四步顺次，每步 6000ms 超时，某步失败即停）。
    /// 详情：GET 帖子链接（详情页）要 200。
    /// 解析：loadResource 解出可播 URL（.m3u8/.mp4）。
    /// 播单：m3u8 取回并含 #EXTM3U；mp4 首字节可取。
    /// 首片：m3u8 取第一个引用（变体播单或分片）并确认可取；mp4 前 64KB 含 ftyp。
    /// 取消时抛 CancellationError。
    private func runSampleSteps(host: WidgetHost, sample: VideoItem) async throws -> [CheckStepResult] {
        var steps: [CheckStepResult] = []

        // 2. 详情
        let detailStart = Date()
        do {
            let status = try await withStepTimeout { try await Self.httpStatus(of: sample.link) }
            guard status == 200 else {
                steps.append(CheckStepResult(name: "详情", passed: false, reason: "HTTP \(status)", milliseconds: Int(Date().timeIntervalSince(detailStart) * 1000)))
                return steps
            }
            steps.append(CheckStepResult(name: "详情", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(detailStart) * 1000)))
        } catch {
            try throwIfCancelled()
            steps.append(CheckStepResult(name: "详情", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(detailStart) * 1000)))
            return steps
        }

        // 3. 解析
        let parseStart = Date()
        let playableURL: String
        do {
            let lines = try await withStepTimeout { try await host.loadResource(link: sample.link, title: sample.title) }
            guard let first = lines.first(where: { line in
                let lower = line.url.lowercased()
                return lower.contains(".m3u8") || lower.contains(".mp4")
            }) else {
                steps.append(CheckStepResult(name: "解析", passed: false, reason: "解不出可播链接", milliseconds: Int(Date().timeIntervalSince(parseStart) * 1000)))
                return steps
            }
            playableURL = first.url
            steps.append(CheckStepResult(name: "解析", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(parseStart) * 1000)))
        } catch {
            try throwIfCancelled()
            steps.append(CheckStepResult(name: "解析", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(parseStart) * 1000)))
            return steps
        }

        // 4. 播单 + 5. 首片（按 URL 类型分流）
        let isM3U8 = playableURL.lowercased().contains(".m3u8")
        if isM3U8 {
            // 播单：取回 m3u8，含 #EXTM3U
            let playlistStart = Date()
            let playlistText: String
            do {
                playlistText = try await withStepTimeout { try await Self.httpBody(of: playableURL, referer: sample.link) }
                guard playlistText.contains("#EXTM3U") else {
                    steps.append(CheckStepResult(name: "播单", passed: false, reason: "不是有效的 m3u8 播单", milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
                    return steps
                }
                steps.append(CheckStepResult(name: "播单", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
            } catch {
                try throwIfCancelled()
                steps.append(CheckStepResult(name: "播单", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
                return steps
            }
            // 首片：取第一个引用（变体播单或分片）并确认可取
            let firstFrameStart = Date()
            do {
                guard let firstRef = Self.firstMediaURL(in: playlistText, baseURL: playableURL) else {
                    steps.append(CheckStepResult(name: "首片", passed: false, reason: "播单里没有分片", milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                    return steps
                }
                if firstRef.lowercased().contains(".m3u8") {
                    let variant = try await withStepTimeout { try await Self.httpBody(of: firstRef, referer: sample.link) }
                    guard variant.contains("#EXTM3U") else {
                        steps.append(CheckStepResult(name: "首片", passed: false, reason: "变体播单无效", milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                        return steps
                    }
                } else {
                    let data = try await withStepTimeout { try await Self.httpRangeData(of: firstRef, length: 32768, referer: sample.link) }
                    guard !data.isEmpty else {
                        steps.append(CheckStepResult(name: "首片", passed: false, reason: "首片分片取不到数据", milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                        return steps
                    }
                }
                steps.append(CheckStepResult(name: "首片", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
            } catch {
                try throwIfCancelled()
                steps.append(CheckStepResult(name: "首片", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                return steps
            }
        } else {
            // mp4：播单 = 首字节可取（Range 取前 1KB）；首片 = 前 64KB 含 ftyp
            let playlistStart = Date()
            do {
                let data = try await withStepTimeout { try await Self.httpRangeData(of: playableURL, length: 1024, referer: sample.link) }
                guard !data.isEmpty else {
                    steps.append(CheckStepResult(name: "播单", passed: false, reason: "MP4 首字节取不到", milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
                    return steps
                }
                steps.append(CheckStepResult(name: "播单", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
            } catch {
                try throwIfCancelled()
                steps.append(CheckStepResult(name: "播单", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(playlistStart) * 1000)))
                return steps
            }
            let firstFrameStart = Date()
            do {
                let data = try await withStepTimeout { try await Self.httpRangeData(of: playableURL, length: 65536, referer: sample.link) }
                guard Self.dataContainsFTYP(data) else {
                    steps.append(CheckStepResult(name: "首片", passed: false, reason: "MP4 首字节不是有效视频", milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                    return steps
                }
                steps.append(CheckStepResult(name: "首片", passed: true, reason: nil, milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
            } catch {
                try throwIfCancelled()
                steps.append(CheckStepResult(name: "首片", passed: false, reason: checkReason(for: error), milliseconds: Int(Date().timeIntervalSince(firstFrameStart) * 1000)))
                return steps
            }
        }
        return steps
    }

    /// 对单个源跑自检（强制跑，不论指纹；源详情页“立即自检”用）。
    /// 五步验真；结果写入 checkResults 并持久化。
    /// 深探针结果保留：指纹没变沿用旧的深探针，变了（模块更新）则清掉（等深探针轮次重测）。
    /// 取消时返回 nil（不存结果，断点续跑时重测）。
    func runCheck(for source: SourceRecord) async -> SourceCheckResult? {
        let previous = await MainActor.run { self.checkResults[source.id] }
        do {
            let host = try loadHost(for: source)
            var fiveStep = try await runFiveStepCheck(host: host, source: source)
            if Task.isCancelled { return nil }
            if fiveStep.sourceFingerprint == previous?.sourceFingerprint {
                fiveStep.deepProbe = previous?.deepProbe
            }
            await storeCheckResult(fiveStep, for: source.id)
            return fiveStep
        } catch {
            if error is CancellationError { return nil }
            if Task.isCancelled { return nil }
            let result = SourceCheckResult(
                status: .failed,
                failedLines: ["加载源": error.localizedDescription],
                checkedAt: Date(),
                failedStep: "列表",
                failedReason: error.localizedDescription,
                sourceFingerprint: fingerprint(for: source)
            )
            await storeCheckResult(result, for: source.id)
            return result
        }
    }

    /// 自检分组（去重）：按模块 id / 站点域名分组，同一组只跑一次固定验线。
    /// 并查集：同 id 或同域名（任一相同）即同一组。
    /// 返回 [[源]]，每组第一个为代表（跑自检），其余标记跳过；组按第一个源的原顺序排。
    private func checkGroups(for all: [SourceRecord]) -> [[SourceRecord]] {
        var parent: [String: String] = [:]
        for source in all { parent[source.id] = source.id }
        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            var node = x
            while let p = parent[node], p != root {
                parent[node] = root
                node = p
            }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var domainOwner: [String: String] = [:]
        for source in all {
            if let domain = siteDomain(for: source) {
                if let owner = domainOwner[domain] {
                    union(owner, source.id)
                } else {
                    domainOwner[domain] = source.id
                }
            }
        }
        var groups: [String: [SourceRecord]] = [:]
        for source in all { groups[find(source.id), default: []].append(source) }
        var ordered: [[SourceRecord]] = []
        var seenRoots = Set<String>()
        for source in all {
            let root = find(source.id)
            guard !seenRoots.contains(root) else { continue }
            seenRoots.insert(root)
            if let group = groups[root] { ordered.append(group) }
        }
        return ordered
    }

    /// 自检全部源：增量 + 去重 + 让路。
    /// - 增量：只跑新增/改过（JS 指纹变了）或没测过的源；没动过的跳过，显示上次结果。
    /// - 去重：同一组（同模块 id 或同站点域名）只跑代表一次，其余标记 skipped（与 X 重复，跳过）。
    /// - 让路：每测完一个源检查 Task.isCancelled（用户点屏/切页/播放/进后台即停）；
    ///   下次从断点接着跑（已测过且指纹没变的源跳过，不重跑）。
    /// 返回（正常数，失败数，跳过数）。取消时返回已统计到的数（未测的源下次接着跑）。
    func runCheckAll() async -> (ok: Int, failed: Int, skipped: Int) {
        var ok = 0
        var failed = 0
        var skipped = 0
        let all = await MainActor.run { self.sources }
        let groups = checkGroups(for: all)
        for group in groups {
            if Task.isCancelled { break }
            guard let representative = group.first else { continue }
            // 代表：增量——指纹没变且有上次结果（非跳过），跳过不重测（显示上次结果）
            let currentFingerprint = fingerprint(for: representative)
            let previous = await MainActor.run { self.checkResults[representative.id] }
            let needsCheck: Bool
            if let prev = previous, prev.status != .skipped {
                needsCheck = prev.sourceFingerprint != currentFingerprint
            } else {
                needsCheck = true
            }
            if needsCheck {
                guard let result = await runCheck(for: representative) else { break }
                switch result.status {
                case .ok: ok += 1
                case .failed: failed += 1
                case .skipped: skipped += 1
                }
            } else if let prev = previous {
                switch prev.status {
                case .ok: ok += 1
                case .failed: failed += 1
                case .skipped: skipped += 1
                }
            }
            // 同组其余源：标记为与代表重复，跳过
            for duplicate in group.dropFirst() {
                if Task.isCancelled { break }
                let skippedResult = SourceCheckResult(
                    status: .skipped,
                    failedLines: [:],
                    checkedAt: Date(),
                    duplicateOf: representative.id,
                    sourceFingerprint: fingerprint(for: duplicate)
                )
                await storeCheckResult(skippedResult, for: duplicate.id)
                skipped += 1
            }
        }
        return (ok, failed, skipped)
    }

    // MARK: - 深探针（第二层：静音真播到出画）

    /// 深探针轮次（第二层，单独轮次，不跟轻检同一轮跑）：
    /// 轻检通过（status .ok）的源，轮流静音真播到出画（真的起 AVPlayer、静音、确认出首帧）。
    /// 7 天一轮；深探针坏了写进该源的 deepProbe，源条目下标出来。
    /// 让路：每测完一个源检查 Task.isCancelled。
    func runDeepProbeRound() async {
        let all = await MainActor.run { self.sources }
        for source in all {
            if Task.isCancelled { break }
            let light = await MainActor.run { self.checkResults[source.id] }
            guard light?.status == .ok else { continue }
            // 7 天内做过且模块没变的不重做
            if let probe = light?.deepProbe,
               Date().timeIntervalSince(probe.checkedAt) < deepProbeInterval,
               light?.sourceFingerprint == fingerprint(for: source) {
                continue
            }
            guard let playableURL = await firstPlayableURL(for: source) else { continue }
            let probe = await Self.deepProbe(urlString: playableURL)
            await MainActor.run {
                if var current = self.checkResults[source.id] {
                    current.deepProbe = probe
                    self.checkResults[source.id] = current
                    self.saveCheckResults()
                }
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastDeepProbeDefaultsKey)
    }

    /// 取一个源第一条可播 URL（固定验线第一个样本的解析结果；深探针用）。
    /// 解析失败返回 nil（该源跳过深探针）。
    private func firstPlayableURL(for source: SourceRecord) async -> String? {
        guard let host = try? loadHost(for: source),
              let probe = host.fixedProbeModule(),
              let samples = try? await host.loadList(moduleId: probe.id, page: 1),
              let first = samples.first,
              let lines = try? await host.loadResource(link: first.link, title: first.title) else {
            return nil
        }
        return lines.first { line in
            let lower = line.url.lowercased()
            return lower.contains(".m3u8") || lower.contains(".mp4")
        }?.url
    }

    /// 深探针：静音真播到出画（真的起 AVPlayer、静音、确认出首帧画面）。
    /// 15 秒不出画即失败。返回 DeepProbeResult。
    static func deepProbe(urlString: String) async -> DeepProbeResult {
        guard let url = URL(string: urlString) else {
            return DeepProbeResult(passed: false, failedStep: "解析", reason: "URL 非法", checkedAt: Date())
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let item = AVPlayerItem(url: url)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(output)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                player.volume = 0
                // 盒子：保活 player/timer，防 continuation 多次 resume
                // 只在主队列上用（建播放器、轮询、超时都在主队列），不用 Sendable。
                final class ProbeBox {
                    var done = false
                    var player: AVPlayer?
                    var timer: DispatchSourceTimer?
                }
                let box = ProbeBox()
                box.player = player
                func finish(_ passed: Bool, _ step: String?, _ reason: String?) {
                    guard !box.done else { return }
                    box.done = true
                    box.timer?.cancel()
                    box.timer = nil
                    player.pause()
                    box.player = nil
                    continuation.resume(returning: DeepProbeResult(passed: passed, failedStep: step, reason: reason, checkedAt: Date()))
                }
                let timer = DispatchSource.makeTimerSource(queue: .main)
                box.timer = timer
                timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                timer.setEventHandler {
                    if item.status == .failed {
                        finish(false, "首片", item.error?.localizedDescription ?? "播放器失败")
                        return
                    }
                    guard item.status == .readyToPlay else { return }
                    // 有新像素帧 = 出画；或正在播且时间在前进（兜底）
                    if output.hasNewPixelBuffer(forItemTime: item.currentTime()) {
                        finish(true, nil, nil)
                        return
                    }
                    if player.timeControlStatus == .playing && item.currentTime().seconds > 0 {
                        finish(true, nil, nil)
                        return
                    }
                }
                timer.resume()
                player.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + deepProbeTimeoutSeconds) {
                    finish(false, "首片", "深探针 15s 未出画")
                }
            }
        }
    }

    // MARK: - 后台自动自检（闲置 12 小时一轮轻检，7 天一轮深探针）

    /// 闲置时自动自检（App 切回前台 / 启动时调）：12 小时一轮轻检，7 天一轮深探针，分开轮次。
    /// “仅 Wi-Fi 自动自检”开时，先确认当前是 Wi-Fi 再跑（默认关 = 任何网络都跑）。
    /// 后台跑；用户一点屏幕/切页/播放/进后台即 cancelAutoCheck() 停下，下次断点续跑。
    func maybeRunAutoCheck() {
        guard autoCheckTask == nil else { return }
        let now = Date()
        let lastLight = UserDefaults.standard.object(forKey: lastAutoCheckDefaultsKey) as? Date
        let lightDue = lastLight.map { now.timeIntervalSince($0) >= autoCheckInterval } ?? true
        let lastDeep = UserDefaults.standard.object(forKey: lastDeepProbeDefaultsKey) as? Date
        let deepDue = lastDeep.map { now.timeIntervalSince($0) >= deepProbeInterval } ?? true
        guard lightDue || deepDue else { return }
        autoCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor [weak self] in self?.autoCheckTask = nil } }
            if UserDefaults.standard.bool(forKey: Self.wifiOnlyAutoCheckDefaultsKey) {
                guard await Self.isOnWiFi() else { return }
            }
            if lightDue {
                _ = await self.runCheckAll()
                UserDefaults.standard.set(Date(), forKey: self.lastAutoCheckDefaultsKey)
            }
            if deepDue, !Task.isCancelled {
                await self.runDeepProbeRound()
            }
        }
    }

    /// 停掉正在跑的后台自动自检（用户点屏/切页/开始播放/进后台时调）。
    /// 下次自动自检从断点接着跑（增量逻辑跳过已测过的源）。
    func cancelAutoCheck() {
        autoCheckTask?.cancel()
        autoCheckTask = nil
    }

    /// 当前是否 Wi-Fi（一次性检查，供“仅 Wi-Fi 自动自检”用）。
    /// NWPathMonitor 取当前路径，最多等 2 秒；拿不到当不是 Wi-Fi（不自动跑，安全起见）。
    static func isOnWiFi() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let monitor = NWPathMonitor()
                    let queue = DispatchQueue(label: "wifi-check")
                    var resumed = false
                    monitor.pathUpdateHandler = { path in
                        guard !resumed else { return }
                        resumed = true
                        monitor.cancel()
                        continuation.resume(returning: path.status == .satisfied && path.usesInterfaceType(.wifi))
                    }
                    monitor.start(queue: queue)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: - 上传坏的模块（broken 分支）

    /// 自检失败的源：把 .js 与失败报告传到码云 broken 分支。
    /// 只动 broken 分支，绝不动 js 分支、不删除任何源。
    /// token 为空时用 Keychain 里存过的；两个都没有就失败。
    /// 返回成功上传的源个数（一个源算成功要 .js 和报告都传上去）。
    func uploadBrokenSources(token: String) async -> Result<Int, ImportError> {
        let effectiveToken = token.isEmpty ? (KeychainHelper.load(forKey: giteeTokenKey) ?? "") : token
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能上传"))
        }
        let failed = await MainActor.run {
            self.sources.filter { self.checkResults[$0.id]?.status == .failed }
        }
        guard !failed.isEmpty else {
            return .failure(.network("没有自检失败的源，不用上传"))
        }
        if case .failure(let error) = await ensureBrokenBranch(token: effectiveToken) {
            return .failure(error)
        }
        var uploaded = 0
        var firstError: String?
        for source in failed {
            guard let jsText = jsSource(for: source) else {
                if firstError == nil { firstError = "\(source.title) 的文件找不到了" }
                continue
            }
            let check = await MainActor.run { self.checkResults[source.id] }
            let report = Self.brokenReport(for: source, result: check)
            let jsResult = await uploadFileToGitee(
                token: effectiveToken,
                path: "broken/\(source.id).js",
                content: jsText,
                message: "自检失败：上传坏的模块 \(source.id)"
            )
            let reportResult = await uploadFileToGitee(
                token: effectiveToken,
                path: "broken/\(source.id).report.txt",
                content: report,
                message: "自检失败报告 \(source.id)"
            )
            switch (jsResult, reportResult) {
            case (.success, .success):
                uploaded += 1
            case (.failure(let error), _), (_, .failure(let error)):
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if uploaded == 0 {
            return .failure(.network(firstError ?? "上传失败"))
        }
        return .success(uploaded)
    }

    /// 失败报告文本：源 id、哪条线失败、错误信息、时间戳。
    private static func brokenReport(for source: SourceRecord, result: SourceCheckResult?) -> String {
        var lines: [String] = [
            "源 id：\(source.id)",
            "源标题：\(source.title)",
            "文件名：\(source.fileName)",
            "检查时间：\(reportDateString(result?.checkedAt ?? Date()))",
        ]
        if let failedLines = result?.failedLines, !failedLines.isEmpty {
            lines.append("失败的线：")
            for (sample, reason) in failedLines.sorted(by: { $0.key < $1.key }) {
                lines.append("- \(sample)：\(reason)")
            }
        } else {
            lines.append("失败原因：无自检记录")
        }
        return lines.joined(separator: "\n")
    }

    private static func reportDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    /// broken 分支不存在就建一个（从仓库默认分支拉出来）；已存在直接成功。
    private func ensureBrokenBranch(token: String) async -> Result<Void, ImportError> {
        guard let branchURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/branches/\(brokenBranch)") else {
            return .failure(.network("上传地址不对"))
        }
        var getRequest = URLRequest(url: branchURL)
        getRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        getRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        getRequest.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.data(for: getRequest)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    return .success(()) // 分支已在
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .failure(.network("Token 不对或没权限（HTTP \(http.statusCode)），检查一下 Token"))
                }
                if http.statusCode != 404 {
                    return .failure(.network("查 broken 分支失败（HTTP \(http.statusCode)），稍后再试"))
                }
                // 404：分支不存在，往下建
            }
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }

        // 查仓库默认分支（master 还是 main），从它建 broken。
        guard let repoURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)") else {
            return .failure(.network("上传地址不对"))
        }
        var repoRequest = URLRequest(url: repoURL)
        repoRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        repoRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        repoRequest.timeoutInterval = 30
        let defaultBranch: String
        do {
            let (data, response) = try await URLSession.shared.data(for: repoRequest)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let branch = json["default_branch"] as? String, !branch.isEmpty else {
                return .failure(.network("查不到仓库默认分支，没法建 broken 分支"))
            }
            defaultBranch = branch
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }

        guard let createURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/branches") else {
            return .failure(.network("上传地址不对"))
        }
        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        createRequest.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        createRequest.timeoutInterval = 30
        let body: [String: Any] = ["branch_name": brokenBranch, "refs": defaultBranch]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.network("建分支失败（请求拼不出来）"))
        }
        createRequest.httpBody = bodyData
        do {
            let (_, response) = try await URLSession.shared.data(for: createRequest)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return .success(())
            }
            // 422：并发时分支可能刚被建好，已存在也算成功
            if let http = response as? HTTPURLResponse, http.statusCode == 422 {
                return .success(())
            }
            return .failure(.network("建 broken 分支失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）"))
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }
    }

    /// 用 Gitee contents API 写一个文件到 broken 分支：
    /// 先 GET 看文件在不在（在就拿 sha 走更新，不在直接新建），内容 base64。
    /// 路径如 broken/<源id>.js，分支固定 broken。
    private func uploadFileToGitee(token: String, path: String, content: String, message: String) async -> Result<Void, ImportError> {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let fileURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/contents/\(encodedPath)?ref=\(brokenBranch)") else {
            return .failure(.network("上传地址不对"))
        }
        var existingSHA: String?
        do {
            var getRequest = URLRequest(url: fileURL)
            getRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            getRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
            getRequest.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: getRequest)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                existingSHA = json["sha"] as? String
            }
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }

        guard let putURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/contents/\(encodedPath)") else {
            return .failure(.network("上传地址不对"))
        }
        var putRequest = URLRequest(url: putURL)
        putRequest.httpMethod = "PUT"
        putRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        putRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        putRequest.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        putRequest.timeoutInterval = 30
        var body: [String: Any] = [
            "content": Data(content.utf8).base64EncodedString(),
            "message": message,
            "branch": brokenBranch
        ]
        if let sha = existingSHA { body["sha"] = sha }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.network("上传失败（请求拼不出来）"))
        }
        putRequest.httpBody = bodyData
        do {
            let (_, response) = try await URLSession.shared.data(for: putRequest)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return .success(())
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.network("Token 不对或没权限（HTTP \(http.statusCode)），检查一下 Token"))
            }
            return .failure(.network("上传 \(path) 失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）"))
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }
    }

    // MARK: - 文件名

    /// 文件名只取最后一段、补 .js 后缀、去掉非法字符；空的用模块 id + .js。
    private func sanitizedFileName(_ fileName: String, fallback: String) -> String {
        var name = (fileName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == ".js" {
            name = fallback + ".js"
        }
        if !name.hasSuffix(".js") {
            name += ".js"
        }
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        return name
    }

    /// 文件名冲突自动改名：xxx.js → xxx-2.js → xxx-3.js……
    private func uniqueFileName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = fileName
        var n = 2
        while fileManager.fileExists(atPath: sourcesDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    private func friendlyNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "下载超时（15 秒没下完）"
            case .notConnectedToInternet: return "没联网，检查一下网络"
            case .cancelled: return "下载已取消"
            case .cannotFindHost, .cannotConnectToHost: return "连不上服务器，稍后再试"
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// 五步验真里一步失败的原因（内部用，转成人话靠 checkReason）。
enum CheckStepError: Error {
    /// 超时（毫秒）
    case timeout(Int)
    /// HTTP 状态码
    case http(Int)
    /// URL 非法
    case badURL
}

// MARK: - 自检结果（单独持久化在 check-results.json，不动 SourceRecord）

/// 五步验真的一步结果。
/// 步名固定五步：列表 / 详情 / 解析 / 播单 / 首片。
struct CheckStepResult: Codable {
    /// 步名：列表 / 详情 / 解析 / 播单 / 首片
    let name: String
    let passed: Bool
    /// 失败原因（如 "HTTP 404"、"6000ms 超时"、"解不出可播链接"）；通过时 nil
    let reason: String?
    /// 耗时（毫秒）
    let milliseconds: Int
}

/// 深探针结果（第二层）：轻检（五步）通过的源，轮流静音真播到出画。
/// 单独轮次（不跟轻检同一轮跑），7 天一轮。
struct DeepProbeResult: Codable {
    let passed: Bool
    /// 死在哪步（通过时 nil，如 "首片"）
    let failedStep: String?
    let reason: String?
    let checkedAt: Date
}

/// 一次自检的结果：固定验线样本跑五步验真（列表→详情→解析→播单→首片）。
/// ok = 样本全部走完五步；failed = 至少一个样本死在某步，
/// failedStep/failedReason 写清死在哪步 + 原因（如 "解析" / "首片 6000ms 超时"）。
/// failedLines 记每条样本的失败原因（key 是样本标题，如 "JUQ-984"，旧版字段保留兼容）。
/// skipped = 去重跳过（与另一个源重复，同模块 id 或同站点域名），duplicateOf 记重复的那个源 id。
struct SourceCheckResult: Codable {
    enum Status: String, Codable {
        case ok
        case failed
        /// 去重跳过：与另一个源重复（同模块 id 或同站点域名），没跑
        case skipped
    }
    var status: Status
    var failedLines: [String: String]
    var checkedAt: Date?
    /// 跳过时：重复的那个源的 id
    var duplicateOf: String?
    /// 五步验真（决定本次结果的那个样本的五步；旧数据为 nil）
    var steps: [CheckStepResult]?
    /// 死在哪步（如 "解析"）；通过时 nil
    var failedStep: String?
    /// 失败原因（如 "首片 6000ms 超时"、"HTTP 404"）
    var failedReason: String?
    /// 深探针结果（第二层，单独轮次；轻检没过的不做）
    var deepProbe: DeepProbeResult?
    /// 导入时该源 JS 的内容指纹（增量自检用）：指纹没变说明源没改过，跳过不重测
    var sourceFingerprint: String?
}

// MARK: - 导入错误（全部中文人话）

enum ImportError: Error, LocalizedError {
    /// 文件读不出来 / 写不进去
    case unreadable
    /// 不是 ForwardWidget 模块格式（带具体原因）
    case notModule(String)
    /// 网络问题（带具体原因）
    case network(String)
    /// 已存在相同源（同模块 id 或同站点域名），不重复添加；关联值是已存在那个源的标题
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "这个文件读不出来（不是有效的文本文件）"
        case .notModule(let reason):
            return reason
        case .duplicate(let existingTitle):
            return "已存在相同源：\(existingTitle)，跳过导入"
        case .network(let reason):
            return reason
        }
    }
}

// MARK: - Keychain（只存 Gitee Token）

/// 最简单的 Keychain 存取：kSecClassGenericPassword，
/// service 固定 com.liudehen.xiaoshipin，account 就是 key。
enum KeychainHelper {
    private static let service = "com.liudehen.xiaoshipin"

    static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
