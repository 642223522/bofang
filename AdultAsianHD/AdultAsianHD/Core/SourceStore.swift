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

    private let fileManager = FileManager.default
    private let sourcesDirectory: URL
    private let manifestURL: URL

    private let giteeTokenKey = "gitee.token"
    private let lastSyncDefaultsKey = "gitee.lastSyncAt"

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.sourcesDirectory = documents.appendingPathComponent("Sources", isDirectory: true)
        self.manifestURL = documents.appendingPathComponent("sources.json")
        try? fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        if let timestamp = UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? TimeInterval {
            self.lastSyncAt = Date(timeIntervalSince1970: timestamp)
        }
        loadManifest()
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

    /// 删文件 + 清单。文件删不掉也不报错，清单照样清。
    func delete(_ source: SourceRecord) {
        try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(source.fileName))
        let update = {
            self.sources.removeAll { $0.fileName == source.fileName }
            self.saveManifest()
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
