import Foundation
import Security

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
    @Published private(set) var checkResults: [String: SourceCheckResult] = []

    private let fileManager = FileManager.default
    private let sourcesDirectory: URL
    private let manifestURL: URL
    private let checkResultsURL: URL

    private let giteeTokenKey = "gitee.token"
    private let lastSyncDefaultsKey = "gitee.lastSyncAt"
    /// 码云仓库与坏模块分支：上传只动 broken 分支，绝不动 js 分支。
    private let giteeRepo = "individual-freedom/ziyong-ziliao-beifang"
    private let brokenBranch = "broken"

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
        let validation = WidgetHost.validate(jsSource: text)
        guard validation.ok, let meta = validation.meta else {
            return .failure(.notModule(validation.error ?? "这个脚本不是 ForwardWidget 模块格式"))
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
        return try WidgetHost(jsSource: text)
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
                    if firstError == nil { firstError = error.localizedDescription }
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

    // MARK: - 自检（固定验线探针）

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

    /// 固定验线模块：params 里 kind 常量为 "fixed" 的那个；
    /// 兜底：id 或标题含 "fixed" / "固定验线"。
    /// pornjav.js 里就是 id "pornjav-fixed"、kind 常量 "fixed"，
    /// 返回两个固定样本 JUQ-984（nmcorp 线）＋ ATID-686（memojav 线）。
    private func fixedProbeModule(in host: WidgetHost) -> ModuleDescriptor? {
        host.modules.first { module in
            module.params.contains { param in
                (param["name"] as? String) == "kind"
                && (param["type"] as? String) == "constant"
                && (param["value"] as? String) == "fixed"
            }
        } ?? host.modules.first { module in
            module.id.lowercased().contains("fixed")
            || module.title.contains("固定验线")
        }
    }

    /// 对单个源跑自检：固定验线取样本，各调 loadResource 看能否解出可播 URL
    /// （.m3u8 或 .mp4）。结果写入 checkResults 并持久化。
    func runCheck(for source: SourceRecord) async -> SourceCheckResult {
        let result: SourceCheckResult
        do {
            let host = try loadHost(for: source)
            guard let probe = fixedProbeModule(in: host) else {
                result = SourceCheckResult(
                    status: .failed,
                    failedLines: ["固定验线": "这个源没有固定验线模块"],
                    checkedAt: Date()
                )
                await storeCheckResult(result, for: source.id)
                return result
            }
            let samples = try await host.loadList(moduleId: probe.id, page: 1)
            guard !samples.isEmpty else {
                result = SourceCheckResult(
                    status: .failed,
                    failedLines: ["固定验线": "固定验线没有返回样本"],
                    checkedAt: Date()
                )
                await storeCheckResult(result, for: source.id)
                return result
            }
            var failedLines: [String: String] = [:]
            for item in samples {
                do {
                    let lines = try await host.loadResource(link: item.link, title: item.title)
                    let playable = lines.contains { line in
                        let lower = line.url.lowercased()
                        return lower.contains(".m3u8") || lower.contains(".mp4")
                    }
                    if !playable {
                        failedLines[item.title] = "没解出可播地址"
                    }
                } catch {
                    failedLines[item.title] = error.localizedDescription
                }
            }
            result = SourceCheckResult(
                status: failedLines.isEmpty ? .ok : .failed,
                failedLines: failedLines,
                checkedAt: Date()
            )
        } catch {
            result = SourceCheckResult(
                status: .failed,
                failedLines: ["加载源": error.localizedDescription],
                checkedAt: Date()
            )
        }
        await storeCheckResult(result, for: source.id)
        return result
    }

    /// 逐个自检全部源（串行：JSContext 与网络都怕并发冲；
    /// 单个源最慢约两条线各 30 秒超时）。返回（正常数，失败数）。
    func runCheckAll() async -> (ok: Int, failed: Int) {
        var ok = 0
        var failed = 0
        let all = await MainActor.run { self.sources }
        for source in all {
            let result = await runCheck(for: source)
            if result.status == .ok { ok += 1 } else { failed += 1 }
        }
        return (ok, failed)
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

// MARK: - 自检结果（单独持久化在 check-results.json，不动 SourceRecord）

/// 一次自检的结果：固定验线两条线各解没解出可播 URL。
/// ok = 样本全部解出可播 URL；failed = 至少一条线失败，
/// failedLines 记每条样本的失败原因（key 是样本标题，如 "JUQ-984"）。
struct SourceCheckResult: Codable {
    enum Status: String, Codable {
        case ok
        case failed
    }
    var status: Status
    var failedLines: [String: String]
    var checkedAt: Date?
}

// MARK: - 导入错误（全部中文人话）

enum ImportError: Error, LocalizedError {
    /// 文件读不出来 / 写不进去
    case unreadable
    /// 不是 ForwardWidget 模块格式（带具体原因）
    case notModule(String)
    /// 这个源已经导入过了（预留；目前文件名冲突走自动改名，一般不返回这个）
    case duplicate
    /// 网络问题（带具体原因）
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "这个文件读不出来（不是有效的文本文件）"
        case .notModule(let reason):
            return reason
        case .duplicate:
            return "这个源已经导入过了"
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
