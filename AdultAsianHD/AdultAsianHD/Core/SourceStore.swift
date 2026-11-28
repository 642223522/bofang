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
    /// 最近一次同步里被跳过的第一个错误（部分成功时也照实留着，源页在成功提示里一并报出来；无错时为 nil）。
    @Published private(set) var lastSyncError: String?
    /// 线路竞速结果：[源 id（= WidgetMeta.id）: 结果]，持久化在 Documents/race-results.json。
    /// 竞速本身仍在 WidgetHost 跑（进模块时 raceLinesIfNeeded），这里只归拢结果，
    /// 供检测 Tab 显示（哪条线胜出、各线耗时、下次重测）。
    @Published private(set) var raceResults: [String: LineRaceResult] = [:]

    private let fileManager = FileManager.default
    private let sourcesDirectory: URL
    private let manifestURL: URL
    private let raceResultsURL: URL

    private let giteeTokenKey = "gitee.token"
    private let lastSyncDefaultsKey = "gitee.lastSyncAt"
    /// 码云仓库：上传账本只动 reports 分支，绝不动 js 分支。
    private let giteeRepo = "individual-freedom/ziyong-ziliao-beifang"
    private let reportsBranch = "reports"

    /// Gitee 同步专用会话：.ephemeral（无持久化磁盘缓存）且 urlCache = nil——
    /// 带 access_token 查询参数的 URL 绝不进 URLCache/日志（P0-2）。
    /// 供全部 Gitee 链路用：syncFromGitee（列表 / contents 单文件 / raw 下载）
    /// 与上传账本链路（ensureBranch / uploadFileToGitee，P1-9：原来走
    /// URLSession.shared，会读共享缓存）。
    private static let giteeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// 导入/同步串行守卫：SourceStore 标了 @unchecked Sendable 且非 @MainActor，
    /// 标志位只在 importLock 里读写，绝不裸 var 跨线程读写。
    /// importData 与 syncFromGitee 共用这一位：双击同步 / 并发导入同一模块时，
    /// 后到的直接失败，不排队——否则两路会分别拿到 xxx.js 与 xxx-2.js、
    /// 写出重复 id 记录（P0-1）。
    private let importLock = NSLock()
    private var isImportingOrSyncing = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.sourcesDirectory = documents.appendingPathComponent("Sources", isDirectory: true)
        self.manifestURL = documents.appendingPathComponent("sources.json")
        self.raceResultsURL = documents.appendingPathComponent("race-results.json")
        try? fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        if let timestamp = UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? TimeInterval {
            self.lastSyncAt = Date(timeIntervalSince1970: timestamp)
        }
        loadManifest()
        loadRaceResults()
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

    /// 核心入口：文件 / 链接 / 同步下载到的 data 都走这里（串行守卫：
    /// 已有人在导入/同步时直接失败，不排队——双击同步/并发导入不再产生
    /// xxx-2.js 与重复 id 记录；内核见 importDataCore）。
    func importData(_ data: Data, fileName: String, origin: String) async -> Result<SourceRecord, ImportError> {
        guard tryBeginImport() else {
            return .failure(.network("正在导入或同步，请稍后再试"))
        }
        defer { endImport() }
        return await importDataCore(data, fileName: fileName, origin: origin)
    }

    /// 抢导入/同步名额：空闲时置位并返回 true；已有人在导入/同步时返回 false，
    /// 调用方直接失败（人话提示），不排队等。
    private func tryBeginImport() -> Bool {
        importLock.lock()
        defer { importLock.unlock() }
        guard !isImportingOrSyncing else { return false }
        isImportingOrSyncing = true
        return true
    }

    /// 释放导入/同步名额（与 tryBeginImport 配对，调用方用 defer 保证释放）。
    private func endImport() {
        importLock.lock()
        defer { importLock.unlock() }
        isImportingOrSyncing = false
    }

    /// importData 的无守卫内核：syncFromGitee 复用它（同步整轮已持导入名额，
    /// 不能再走带守卫的 importData，否则自锁失败）。
    /// 顺序：转 UTF-8 文本 → WidgetHost.validate 校验格式（不合格直接失败，人话原因）
    /// → 文件名冲突自动改名（xxx-2.js）→ 写文件 → 更新清单 → 主线程刷新 sources。
    private func importDataCore(_ data: Data, fileName: String, origin: String) async -> Result<SourceRecord, ImportError> {
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.unreadable)
        }
        let validation = WidgetHost.validate(jsSource: text, fallbackTitle: fileName)
        guard validation.ok, let meta = validation.meta else {
            return .failure(.notModule(validation.error ?? "这个脚本不是 ForwardWidget 模块格式"))
        }
        // 不去重（2026-11-26 用户定：源去重删了——同站不同模块也是独立的源；
        // 朋友的去重是帖子内容去重，跟源去重不是一回事）。
        // 同模块 id：原地更新（覆盖旧文件、更新记录）；否则当新源追加。
        let existing = await MainActor.run { self.sources.first(where: { $0.id == meta.id }) }
        let finalName = existing?.fileName ?? uniqueFileName(sanitizedFileName(fileName, fallback: meta.id))
        let fileURL = sourcesDirectory.appendingPathComponent(finalName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return .failure(.unreadable)
        }
        let record = SourceRecord(
            id: meta.id,
            title: NodeRequiredModules.displayTitle(for: meta),
            fileName: finalName,
            origin: origin,
            country: existing?.country ?? countryGuess(for: meta),
            version: meta.version,
            importedAt: Date()
        )
        await MainActor.run {
            // 源唯一身份只认 id：按 id 匹配替换，同一 meta.id 绝不追加第二条记录。
            if let idx = self.sources.firstIndex(where: { $0.id == record.id }) {
                self.sources[idx] = record
            } else {
                self.sources.append(record)
            }
            self.saveManifest()
        }
        // 旧记录换了文件名时清掉旧文件（现逻辑里既有记录沿用旧文件名，
        // 正常走不到这里；留作防卫，避免孤儿 .js 攒在 Sources 里）。
        if let oldFileName = existing?.fileName, oldFileName != finalName {
            try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(oldFileName))
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
        defer { session.finishTasksAndInvalidate() }
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

    /// 删文件 + 清单 + 该源的竞速记录。文件删不掉也不报错，清单照样清。
    /// 本会话竞速状态（已竞标记 + 首选线）也一并清掉，否则删了重装同 id
    /// 的源会沿用旧会话的首选线、且不再自动竞速（P1-9）。
    func delete(_ source: SourceRecord) {
        try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(source.fileName))
        let update = {
            self.sources.removeAll { $0.fileName == source.fileName }
            self.saveManifest()
            self.raceResults.removeValue(forKey: source.id)
            self.saveRaceResults()
            self.clearSessionRaceState(for: source.id)
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

    /// JS 内容指纹（FNV-1a 64 位哈希转十六进制）：当作 WidgetHost 的
    /// sourceGeneration——内容变了宿主就知道要重建 host。
    static func fingerprint(of jsSource: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in jsSource.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    func loadHost(for source: SourceRecord) throws -> WidgetHost {
        guard let text = jsSource(for: source) else {
            throw ImportError.unreadable
        }
        // P1-2：SourceRecord.id 就是可信的模块 id，build 之前预填，
        // 模块顶层代码调 storage 不再经过空串前缀。
        return try WidgetHost(jsSource: text, fallbackTitle: source.fileName, sourceGeneration: Self.fingerprint(of: text), preknownModuleID: source.id)
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
    /// 同步是覆盖式：同 meta.id 的旧源原地更新（写盘+清单都走 importDataCore），
    /// 不再按文件名找旧源，避免反复同步产生 xxx-2.js 与重复 id 记录。
    /// 返回成功导入的个数；失败给人话原因。
    func syncFromGitee(token: String) async -> Result<Int, ImportError> {
        let effectiveToken = resolveGiteeToken(token)
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能同步"))
        }
        guard tryBeginImport() else {
            return .failure(.network("正在同步或导入，请稍后再试"))
        }
        defer { endImport() }

        guard let listURL = URL(string: "https://gitee.com/api/v5/repos/individual-freedom/ziyong-ziliao-beifang/contents/?ref=js") else {
            return .failure(.network("同步地址不对"))
        }
        var listRequest = URLRequest(url: listURL)
        listRequest.setValue("token \(effectiveToken)", forHTTPHeaderField: "Authorization")
        listRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        listRequest.timeoutInterval = 30
        let listData: Data
        do {
            let (data, response) = try await Self.giteeSession.data(for: listRequest)
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
        // 列表请求返回 2xx = Token 已鉴权通过，在这里才写 Keychain：
        // 输错 Token 时上面已在 401/403 处返回，原来可用的 Token 不会被覆盖（P0-2）。
        KeychainHelper.save(effectiveToken, forKey: giteeTokenKey)
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

            do {
                // 1. 先下载到内存，绝不提前删本地旧源
                let data: Data
                if let contentsData = await fetchGiteeContentsFile(name: name, token: effectiveToken) {
                    data = contentsData
                } else {
                    // contents API 失败才构造 raw URL（P0-2）：access_token 只在
                    // 必要时才进 URL；download_url 必须是通过校验的 gitee 地址，
                    // 否则用自行拼出的 gitee raw 地址兜底。
                    // 下载也要带 Token：仓库是私有的，裸 GET 拉 raw 文件会被码云 403 拦。
                    // 两处都带：Authorization 头（直连时用）+ access_token 查询参数
                    // （URLSession 跨域重定向会丢 Authorization 头，查询参数能活下来）。
                    // 兜底 raw 路径里的文件名先百分号编码（含中文/空格的文件名
                    // 不编码会让 URLComponents 拼不出 URL）；拼不出时记 firstError，
                    // 不再静默跳过（P1-9）。
                    let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
                    let rawURLString = Self.validatedGiteeDownloadURL(from: entry)
                        ?? "https://gitee.com/individual-freedom/ziyong-ziliao-beifang/raw/js/\(encodedName)"
                    var rawComponents = URLComponents(string: rawURLString)
                    var rawQueryItems = rawComponents?.queryItems ?? []
                    rawQueryItems.removeAll { $0.name == "access_token" }
                    rawQueryItems.append(URLQueryItem(name: "access_token", value: effectiveToken))
                    rawComponents?.queryItems = rawQueryItems
                    guard let rawURL = rawComponents?.url else {
                        if firstError == nil { firstError = "下载 \(name) 失败（地址拼不出来）" }
                        continue
                    }
                    var downloadRequest = URLRequest(url: rawURL)
                    downloadRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    downloadRequest.setValue("token \(effectiveToken)", forHTTPHeaderField: "Authorization")
                    downloadRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
                    downloadRequest.timeoutInterval = 30
                    let (rawData, response) = try await Self.giteeSession.data(for: downloadRequest)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        if firstError == nil { firstError = "下载 \(name) 失败（HTTP \(http.statusCode)）" }
                        continue
                    }
                    data = rawData
                }

                // 2. 下载到的 data 直接走 importDataCore 写盘+更新清单；
                // 校验（文本有效 + WidgetHost.validate）在 importDataCore
                // 里做，不在这里再验一次（P2-6：同一段文本验两遍是重复，
                // 结果一致；校验失败时 importDataCore 的 .failure 照样记
                // firstError，旧源不动）。
                // （源唯一身份只认 meta.id；不去重：同站不同模块也是独立的源）。
                switch await importDataCore(data, fileName: name, origin: "gitee") {
                case .success:
                    imported += 1
                case .failure(let error):
                    if firstError == nil { firstError = error.localizedDescription }
                    continue
                }
            } catch {
                if firstError == nil { firstError = friendlyNetworkError(error) }
                continue
            }
        }

        if imported == 0 {
            await MainActor.run { self.lastSyncError = firstError }
            return .failure(.network(firstError ?? "同步到的源都下载失败"))
        }
        await MainActor.run {
            let now = Date()
            self.lastSyncAt = now
            self.lastSyncError = firstError
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: self.lastSyncDefaultsKey)
        }
        return .success(imported)
    }

    /// download_url 强校验：只接受 https + gitee.com（或其子域，如 raw 子域）的地址；
    /// 校验失败返回 nil，调用方改用自行拼出的 gitee raw 地址。
    /// 代码里实际用到的 gitee host 只有 gitee.com（API / 下载 / raw 全是它），
    /// raw.githubusercontent 不在此列——绝不把带 access_token 的 URL 发往第三方。
    private static func validatedGiteeDownloadURL(from entry: [String: Any]) -> String? {
        guard let rawString = entry["download_url"] as? String,
              let url = URL(string: rawString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "gitee.com" || host.hasSuffix(".gitee.com") else { return nil }
        return rawString
    }

    /// 用 Gitee contents API 单文件接口拿一个 .js 文件的内容。
    /// GET /api/v5/repos/<repo>/contents/<文件名>?ref=js，带 Authorization 头；
    /// 返回 JSON 里 `content` 是 base64（可能含换行，先去掉空白字符再解），
    /// `encoding` 应为 base64。contents API 是带 Token 的 JSON 接口，不经过
    /// raw 链接重定向，鉴权不会丢——raw 下载在 #43 里带了 Authorization 头 +
    /// access_token 参数仍失败，contents API 更稳妥。
    /// 任何一步失败（非 2xx、JSON 解析失败、encoding 不对、base64 解不开）
    /// 都返回 nil，由调用方 fallback 到 raw 下载。
    private func fetchGiteeContentsFile(name: String, token: String) async -> Data? {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://gitee.com/api/v5/repos/individual-freedom/ziyong-ziliao-beifang/contents/\(encodedName)?ref=js") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        guard let (data, response) = try? await Self.giteeSession.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? String else {
            return nil
        }
        if let encoding = json["encoding"] as? String, encoding.lowercased() != "base64" {
            return nil
        }
        // content 是 base64，可能含换行，先去掉所有空白字符再解。
        let cleaned = content.filter { !$0.isWhitespace }
        return Data(base64Encoded: cleaned)
    }

    /// 读 Keychain 里存过的 Gitee Token（同步表单预填 / 上传账本用）。
    func loadSavedGiteeToken() -> String? {
        KeychainHelper.load(forKey: giteeTokenKey)
    }


    // MARK: - 线路竞速结果（归拢，不跑竞速）

    /// 竞速结果持久化：Documents/race-results.json（单独文件，与 sources.json 同一套路）。
    private func loadRaceResults() {
        guard let data = try? Data(contentsOf: raceResultsURL),
              let decoded = try? JSONDecoder().decode([String: LineRaceResult].self, from: data) else {
            self.raceResults = [:]
            return
        }
        self.raceResults = decoded
    }

    private func saveRaceResults() {
        guard let data = try? JSONEncoder().encode(raceResults) else { return }
        try? data.write(to: raceResultsURL, options: .atomic)
    }

    /// WidgetHost 跑完竞速后调这里记一笔（进模块时 raceLinesIfNeeded → 记结果）。
    /// 竞速算法本身不动，这里只收结果：胜出线、各线耗时、时间。
    func recordRaceResult(_ result: LineRaceResult, for sourceId: String) async {
        await MainActor.run {
            self.raceResults[sourceId] = result
            self.saveRaceResults()
        }
    }

    // MARK: - 本会话竞速去重（内存里，不持久化；关软件即清零）

    /// 本会话已开过竞速的源 id（自动竞速或手动重竞，开始即记）。
    /// 只放内存、不写磁盘：下次打开软件（新会话）进模块重新竞速。
    /// 注意别拿 raceResults（持久化到 race-results.json）来去重，那样关软件
    /// 重开也不会再竞速。锁保护：WidgetHost 的竞速在后台 Task 写、主线程读。
    private let sessionRaceLock = NSLock()
    private var racedThisSession: Set<String> = []
    /// 本会话各源定下的首选线（竞速跑完记一笔；没分出胜负时不记）。
    /// 新 host 不重竞时，preferredLine 的兜底读这里。
    private var sessionPreferredLines: [String: PreferredLine] = [:]

    /// 本会话这个源开过竞速没有（开始即算，不管结果出没出）。
    func hasRacedThisSession(_ sourceId: String) -> Bool {
        sessionRaceLock.lock()
        defer { sessionRaceLock.unlock() }
        return racedThisSession.contains(sourceId)
    }

    /// 本会话这个源定下的首选线（还没竞完 / 没分出胜负时 nil）。
    func sessionPreferredLine(for sourceId: String) -> PreferredLine? {
        sessionRaceLock.lock()
        defer { sessionRaceLock.unlock() }
        return sessionPreferredLines[sourceId]
    }

    /// 竞速开始时记一笔（同步记：重入瞬间两个 host 不会都开竞）。
    func markRaceStarted(for sourceId: String) {
        sessionRaceLock.lock()
        defer { sessionRaceLock.unlock() }
        racedThisSession.insert(sourceId)
    }

    /// 竞速跑完记一笔：首选线进会话缓存（分出胜负才记；nil 不记）。
    func markRaceFinished(for sourceId: String, preferredLine: PreferredLine?) {
        guard let preferredLine else { return }
        sessionRaceLock.lock()
        defer { sessionRaceLock.unlock() }
        sessionPreferredLines[sourceId] = preferredLine
    }

    /// 删源时清掉该源的本会话竞速状态（已竞标记 + 首选线）：
    /// 删了重装同 id 的源，本会话要能重新自动竞速、不用旧首选线。
    private func clearSessionRaceState(for sourceId: String) {
        sessionRaceLock.lock()
        defer { sessionRaceLock.unlock() }
        racedThisSession.remove(sourceId)
        sessionPreferredLines.removeValue(forKey: sourceId)
    }

    // MARK: - 上传播放账本（reports 分支）

    /// 归一化 Token：去首尾空白与换行；传入非空返回传入值，传入为空则读 Keychain。
    /// 只读不写——写 Keychain 只在 Gitee API 返回 2xx 的调用点做
    /// （syncFromGitee 列表请求成功后、uploadLedger 上传成功后）：
    /// 输错一个字符拿到 401 时，原来可用的 Token 不会被覆盖（P0-2）。
    private func resolveGiteeToken(_ rawToken: String) -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return (KeychainHelper.load(forKey: giteeTokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 Gitee 错误响应体提取人话信息（优先 JSON["message"]，否则取前 120 字符）。
    private static func giteeErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return String(raw.prefix(120))
    }

    /// 播放账本快照传到码云 reports 分支（一天一个文件：ledger-YYYY-MM-DD.json，就地更新）。
    /// 放 reports 分支，Muse 每天读报告时一起读到——真机上没开节点失败的站，
    /// 账本里 network=direct、stage/verdict 写明死在哪步，不用靠录屏猜。
    /// token 为空时用 Keychain 里存过的；两个都没有就失败。成功返回文件名。
    func uploadLedger(token: String) async -> Result<String, ImportError> {
        let effectiveToken = resolveGiteeToken(token)
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能上传"))
        }
        let snapshot = await MainActor.run { PlaybackLedger.shared.snapshotJSON() }
        guard snapshot != "{}" else {
            return .failure(.network("账本是空的，不用上传"))
        }
        if case .failure(let error) = await ensureBranch(reportsBranch, token: effectiveToken) {
            return .failure(error)
        }
        let day = String(Self.reportDateString(Date()).prefix(10))
        let fileName = "ledger-\(day).json"
        let result = await uploadFileToGitee(
            token: effectiveToken,
            path: fileName,
            content: snapshot,
            message: "播放账本快照 \(day)",
            branch: reportsBranch
        )
        switch result {
        case .success:
            // 上传返回 2xx = Token 已鉴权通过，在这里才写 Keychain（P0-2）。
            KeychainHelper.save(effectiveToken, forKey: giteeTokenKey)
            return .success(fileName)
        case .failure(let error):
            return .failure(error)
        }
    }


    /// 固定公历 + POSIX，避免佛历/民国历等非公历系统设置把文件名年份算错。
    private static func reportDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 指定分支不存在就建一个（从仓库默认分支拉出来）；已存在直接成功。
    private func ensureBranch(_ branch: String, token: String) async -> Result<Void, ImportError> {
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        guard let branchURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/branches/\(encodedBranch)") else {
            return .failure(.network("上传地址不对"))
        }
        var getRequest = URLRequest(url: branchURL)
        getRequest.cachePolicy = .reloadIgnoringLocalCacheData
        getRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        getRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        getRequest.timeoutInterval = 30
        do {
            let (data, response) = try await Self.giteeSession.data(for: getRequest)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    return .success(()) // 分支已在
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                    return .failure(.network("Token 不对或没权限（HTTP \(http.statusCode)\(detail)），检查一下 Token"))
                }
                if http.statusCode != 404 {
                    let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                    return .failure(.network("查 \(branch) 分支失败（HTTP \(http.statusCode)\(detail)），稍后再试"))
                }
                // 404：分支不存在，往下建
            }
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }

        // 查仓库默认分支（master 还是 main），从它建目标分支。
        guard let repoURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)") else {
            return .failure(.network("上传地址不对"))
        }
        var repoRequest = URLRequest(url: repoURL)
        repoRequest.cachePolicy = .reloadIgnoringLocalCacheData
        repoRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        repoRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        repoRequest.timeoutInterval = 30
        let defaultBranch: String
        do {
            let (data, response) = try await Self.giteeSession.data(for: repoRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("Token 不对或没权限（HTTP \(status)\(detail)），检查一下 Token"))
            }
            guard (200...299).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resolvedDefault = json["default_branch"] as? String, !resolvedDefault.isEmpty else {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("查不到仓库默认分支（HTTP \(status)\(detail)），没法建 \(branch) 分支"))
            }
            defaultBranch = resolvedDefault
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
        let body: [String: Any] = [
            "access_token": token,
            "branch_name": branch,
            "refs": defaultBranch
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.network("建分支失败（请求拼不出来）"))
        }
        createRequest.httpBody = bodyData
        do {
            let (data, response) = try await Self.giteeSession.data(for: createRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                return .success(())
            }
            if status == 401 || status == 403 {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("Token 没建分支权限（HTTP \(status)\(detail)）"))
            }
            // 422：只有重新 GET 确认分支真的存在，才按并发已建好放行；否则把码云报错原样透出。
            if status == 422 {
                if let (_, recheck) = try? await Self.giteeSession.data(for: getRequest),
                   let recheckHTTP = recheck as? HTTPURLResponse,
                   (200...299).contains(recheckHTTP.statusCode) {
                    return .success(())
                }
            }
            let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
            return .failure(.network("建 \(branch) 分支失败（HTTP \(status)\(detail)）"))
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }
    }

    /// 用 Gitee contents API 写一个文件到指定分支（默认 broken）：
    /// 1) 禁缓存 GET 查文件是否已存在：
    ///    - Gitee 文件不存在时常返回 200 [] 或 404 → existingSHA = nil；
    ///    - 已存在返回 200 {"sha": "..."} → existingSHA = sha；
    ///    - 其他错误（401/403/5xx）直接失败，不再误判为新建。
    /// 2) Gitee v5 规范：新建文件必须用 POST（不带 sha），更新已有文件必须用 PUT（必带 sha）。
    /// 3) 若遇 400/409 SHA 冲突或“已存在”，自动重查 SHA 重试一次。
    private func uploadFileToGitee(
        token: String,
        path: String,
        content: String,
        message: String,
        branch: String = "broken",
        allowConflictRetry: Bool = true
    ) async -> Result<Void, ImportError> {
        let encodedPath = path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        guard let fileURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/contents/\(encodedPath)?ref=\(encodedBranch)"),
              let writeURL = URL(string: "https://gitee.com/api/v5/repos/\(giteeRepo)/contents/\(encodedPath)") else {
            return .failure(.network("上传地址不对"))
        }

        // 1. 查文件是否存在并取最新 sha（禁止读本地旧缓存，防止同日二次上传 SHA 冲突）
        var existingSHA: String?
        do {
            var getRequest = URLRequest(url: fileURL)
            getRequest.cachePolicy = .reloadIgnoringLocalCacheData
            getRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            getRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
            getRequest.timeoutInterval = 30
            let (data, response) = try await Self.giteeSession.data(for: getRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("Token 不对或没权限（HTTP \(status)\(detail)），检查一下 Token"))
            }
            if (200...299).contains(status) {
                // Gitee 对不存在的文件常返回 HTTP 200 + "[]"，只有字典且带非空 sha 才算文件已存在
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sha = json["sha"] as? String, !sha.isEmpty {
                    existingSHA = sha
                }
            } else if status != 404 {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("查询 \(path) 状态失败（HTTP \(status)\(detail)）"))
            }
        } catch {
            return .failure(.network("连不上码云：\(friendlyNetworkError(error))"))
        }

        // 2. 新建用 POST（无 sha），更新用 PUT（带 sha）
        let isUpdate = (existingSHA != nil)
        var writeRequest = URLRequest(url: writeURL)
        writeRequest.httpMethod = isUpdate ? "PUT" : "POST"
        writeRequest.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        writeRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        writeRequest.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        writeRequest.timeoutInterval = 30
        var body: [String: Any] = [
            "access_token": token,
            "content": Data(content.utf8).base64EncodedString(),
            "message": message,
            "branch": branch
        ]
        if let sha = existingSHA {
            body["sha"] = sha
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.network("上传失败（请求拼不出来）"))
        }
        writeRequest.httpBody = bodyData

        do {
            let (data, response) = try await Self.giteeSession.data(for: writeRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                return .success(())
            }
            if status == 401 || status == 403 {
                let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
                return .failure(.network("Token 不对或没权限（HTTP \(status)\(detail)），检查一下 Token"))
            }
            // 并发冲突或文件刚被创建：重查一次最新 SHA 重试一次
            if allowConflictRetry && (status == 400 || status == 409) {
                return await uploadFileToGitee(
                    token: token,
                    path: path,
                    content: content,
                    message: message,
                    branch: branch,
                    allowConflictRetry: false
                )
            }
            let detail = Self.giteeErrorMessage(from: data).map { "：\($0)" } ?? ""
            return .failure(.network("上传 \(path) 失败（\(isUpdate ? "PUT" : "POST") HTTP \(status)\(detail)）"))
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
            case .timedOut: return "请求超时，稍后再试"
            case .notConnectedToInternet: return "没联网，检查一下网络"
            case .cancelled: return "请求已取消"
            case .cannotFindHost, .cannotConnectToHost: return "连不上服务器，稍后再试"
            default: break
            }
        }
        return error.localizedDescription
    }
}

/// 竞速解线超时的内部错误：timeout 由 WidgetHost.loadResourceWithTimeout
/// 抛（竞速解析步超时兜底）；http / badURL 备用。
enum CheckStepError: Error {
    /// 超时（毫秒）
    case timeout(Int)
    /// HTTP 状态码
    case http(Int)
    /// URL 非法
    case badURL
}

/// 一次线路竞速里某条线的耗时（kind 是显示名，如 "MemoJav" / "NMCorp"）。
struct LineTiming: Codable {
    let kind: String
    /// 该线解出可播链接的耗时（毫秒）
    let milliseconds: Int
}

/// 一次线路竞速的结果（WidgetHost 进模块时 raceLinesIfNeeded 跑完记一笔）。
/// winnerLabel 为 nil = 没分出胜负（note 写清原因，如“两条线都解不出”）。
/// 下次重测：本会话再进模块不再自动重跑（每模块每会话只竞一次）；
/// 检测页“重新竞速”点一次强制重测一次。
struct LineRaceResult: Codable {
    /// 胜出的线（显示名，如 "MemoJav"）；没分出胜负时 nil
    var winnerLabel: String?
    /// 各线耗时（每种线取最快的一次）
    var timings: [LineTiming]
    /// 竞速时间
    var racedAt: Date
    /// 没分出胜负时的原因（如“没有固定验线”、“样本都解不出可播线路”）；分出胜负时 nil
    var note: String?
}

// MARK: - 导入错误（全部中文人话）

enum ImportError: Error, LocalizedError {
    /// 文件读不出来 / 写不进去
    case unreadable
    /// 不是 ForwardWidget 模块格式（带具体原因）
    case notModule(String)
    /// 网络问题（带具体原因）
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "这个文件读不出来（不是有效的文本文件）"
        case .notModule(let reason):
            return reason
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
