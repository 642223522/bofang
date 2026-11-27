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
    /// 自检结果：[源 id: 结果]，持久化在 Documents/check-results.json
    /// （与 sources.json 分开，不动 SourceRecord）。
    @Published private(set) var checkResults: [String: SourceCheckResult] = [:]
    /// 线路竞速结果：[源 id（= WidgetMeta.id）: 结果]，持久化在 Documents/race-results.json。
    /// 竞速本身仍在 WidgetHost 跑（进模块时 raceLinesIfNeeded），这里只归拢结果，
    /// 供检测 Tab 显示（哪条线胜出、各线耗时、下次重测）。
    @Published private(set) var raceResults: [String: LineRaceResult] = [:]

    private let fileManager = FileManager.default
    private let sourcesDirectory: URL
    private let manifestURL: URL
    private let checkResultsURL: URL
    private let raceResultsURL: URL

    private let giteeTokenKey = "gitee.token"
    private let lastSyncDefaultsKey = "gitee.lastSyncAt"
    /// 码云仓库与坏模块分支：上传只动 broken 分支，绝不动 js 分支。
    private let giteeRepo = "individual-freedom/ziyong-ziliao-beifang"
    private let brokenBranch = "broken"
    private let reportsBranch = "reports"

    // MARK: - 自检后台任务（让路 + 断点续跑）

    /// 正在跑的后台自动自检 Task（轻检或深探针）。用户一点屏幕/切页/开始播放，
    /// 或 App 进后台，立刻 cancel；下次从断点接着跑（增量逻辑跳过已测过的）。
    private var autoCheckTask: Task<Void, Never>?
    /// runCheckAll 共享并发守卫（防 .refreshable、手动“自检全部”与后台自动自检并发重入）
    private let checkAllLock = NSLock()
    private var isCheckAllRunning = false
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
        self.raceResultsURL = documents.appendingPathComponent("race-results.json")
        try? fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        if let timestamp = UserDefaults.standard.object(forKey: lastSyncDefaultsKey) as? TimeInterval {
            self.lastSyncAt = Date(timeIntervalSince1970: timestamp)
        }
        loadManifest()
        loadCheckResults()
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
            title: meta.title,
            fileName: finalName,
            origin: origin,
            country: existing?.country ?? countryGuess(for: meta),
            version: meta.version,
            importedAt: Date()
        )
        await MainActor.run {
            if let idx = self.sources.firstIndex(where: { $0.fileName == finalName }) {
                self.sources[idx] = record
            } else {
                self.sources.append(record)
            }
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

    /// 删文件 + 清单 + 该源的自检记录。文件删不掉也不报错，清单照样清。
    func delete(_ source: SourceRecord) {
        try? fileManager.removeItem(at: sourcesDirectory.appendingPathComponent(source.fileName))
        let update = {
            self.sources.removeAll { $0.fileName == source.fileName }
            self.saveManifest()
            self.checkResults.removeValue(forKey: source.id)
            self.saveCheckResults()
            self.raceResults.removeValue(forKey: source.id)
            self.saveRaceResults()
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
        return try WidgetHost(jsSource: text, fallbackTitle: source.fileName, sourceGeneration: Self.fingerprint(of: text))
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
        let effectiveToken = resolveGiteeToken(token)
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能同步"))
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
            // 下载也要带 Token：仓库是私有的，裸 GET 拉 raw 文件会被码云 403 拦
            // （列表请求带了 Token 所以能列出文件，下载没带所以 403）。
            // 两处都带：Authorization 头（直连时用）+ access_token 查询参数
            // （URLSession 跨域重定向会丢 Authorization 头，查询参数能活下来）。
            var rawComponents = URLComponents(string: rawURLString)
            var rawQueryItems = rawComponents?.queryItems ?? []
            rawQueryItems.removeAll { $0.name == "access_token" }
            rawQueryItems.append(URLQueryItem(name: "access_token", value: effectiveToken))
            rawComponents?.queryItems = rawQueryItems
            guard let rawURL = rawComponents?.url else { continue }

            do {
                // 1. 先下载到内存，绝不提前删本地旧源
                let data: Data
                if let contentsData = await fetchGiteeContentsFile(name: name, token: effectiveToken) {
                    data = contentsData
                } else {
                    var downloadRequest = URLRequest(url: rawURL)
                    downloadRequest.cachePolicy = .reloadIgnoringLocalCacheData
                    downloadRequest.setValue("token \(effectiveToken)", forHTTPHeaderField: "Authorization")
                    downloadRequest.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
                    downloadRequest.timeoutInterval = 30
                    let (rawData, response) = try await URLSession.shared.data(for: downloadRequest)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        if firstError == nil { firstError = "下载 \(name) 失败（HTTP \(http.statusCode)）" }
                        continue
                    }
                    data = rawData
                }

                // 2. 先校验新文件合法性，校验不通过保留旧源不动
                guard let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if firstError == nil { firstError = "\(name) 不是有效文本文件" }
                    continue
                }
                let validation = WidgetHost.validate(jsSource: text, fallbackTitle: name)
                guard validation.ok, let meta = validation.meta else {
                    if firstError == nil { firstError = validation.error ?? "\(name) 不是有效模块" }
                    continue
                }

                // 3. 确认下载+校验全部通过，再原子替换同名/同 id 旧源（不去重：同站不同模块也是独立的源）
                let sanitized = sanitizedFileName(name, fallback: meta.id)
                let existing = await MainActor.run {
                    self.sources.first(where: { $0.fileName == sanitized || $0.id == meta.id })
                }
                let finalName = existing?.fileName ?? uniqueFileName(sanitized)
                let targetURL = sourcesDirectory.appendingPathComponent(finalName)
                do {
                    try data.write(to: targetURL, options: .atomic)
                } catch {
                    if firstError == nil { firstError = "写入 \(finalName) 失败" }
                    continue
                }
                let record = SourceRecord(
                    id: meta.id,
                    title: meta.title,
                    fileName: finalName,
                    origin: "gitee",
                    country: existing?.country ?? countryGuess(for: meta),
                    version: meta.version,
                    importedAt: Date()
                )
                await MainActor.run {
                    if let idx = self.sources.firstIndex(where: { $0.fileName == finalName }) {
                        self.sources[idx] = record
                    } else {
                        self.sources.append(record)
                    }
                    self.saveManifest()
                }
                imported += 1
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
        guard let (data, response) = try? await URLSession.shared.data(for: request),
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

    // MARK: - 线路竞速结果（归拢，不跑竞速）

    /// 竞速结果持久化：Documents/race-results.json（与 check-results.json 同一套路）。
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

    /// 后台自动自检的轮次说明（检测页“同步与健康”区显示用）：
    /// 轻检 12 小时一轮，深探针 7 天一轮（直接读现有的轮次常量，不另写死数字）。
    var autoCheckCycleDescription: String {
        let lightHours = Int(autoCheckInterval / 3600)
        let deepDays = Int(deepProbeInterval / (24 * 3600))
        return "轻检 \(lightHours) 小时一轮，深探针 \(deepDays) 天一轮"
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

    // MARK: - 自检失败分类（真失败 vs 没测成）

    /// 本轮开始前的 captive.apple.com 探针结果（只作事后归因，不短路整轮）。
    private enum ConnectivityState {
        case online
        case offline
        case unknown
    }

    /// 本轮的 captive 探针结果（runCheckAll 开始时探一次；单源自检重置为 .unknown，
    /// 避免用上一轮的旧值误判）。
    private var roundConnectivity: ConnectivityState = .unknown

    /// captive.apple.com 轻探针：200 + 正文含 Success → online；明确无网络（-1009）→ offline；
    /// 其余（超时、DNS 异常、被重定向、被拦截）→ unknown。3 秒预算，每轮最多一次。
    private func probeConnectivity() async -> ConnectivityState {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return .unknown }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (data, response) = try await DiagnosticHTTPClient.shared.data(for: request, source: "selfcheck-connectivity", timeout: 3)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .unknown }
            let body = String(decoding: data, as: UTF8.self)
            return body.contains("Success") ? .online : .unknown
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == URLError.Code.notConnectedToInternet.rawValue {
                return .offline
            }
            return .unknown
        }
    }

    /// 失败分类：真失败（.failed）还是没测成（.transient）。
    /// 原则：只有证据充分指向源本身损坏才记真失败；超时/传输失败/服务器临时异常
    /// /模块未解出线路都记没测成（本次没法判定，不计失败、不上传坏模块）。
    /// route 用 NetworkState.inspect() 的当前值（direct/proxy），不另发探测请求。
    private func classifyFailure(step: String, reason: String, error: Error?) -> (status: SourceCheckResult.Status, reason: String) {
        let route = NetworkState.inspect().networkClass
        let isProxy = route == "proxy"
        // 1. 超时：一定是没测成（挂起也好、快失败也好，本次都没拿到结论）
        if let stepError = error as? CheckStepError, case .timeout(let ms) = stepError {
            if isProxy {
                return (.transient, "代理环境请求超时（\(step) \(ms)ms），原因未确定")
            }
            return (.transient, "疑需节点：\(step) \(ms)ms 超时")
        }
        // 2. 传输层阻断（桥接还原的 .transport，或直连的 URLError）
        if let code = transportErrorCode(from: error) {
            if code == URLError.Code.secureConnectionFailed.rawValue {
                return (.transient, "TLS 失败（\(step)），不是节点问题")
            }
            if isProxy {
                return (.transient, "代理环境请求超时（\(step)），原因未确定")
            }
            if roundConnectivity == .offline {
                return (.transient, "本机无网（\(step)）")
            }
            return (.transient, "疑需节点：\(step) 网络阻断")
        }
        // 3. HTTP 状态码
        if let stepError = error as? CheckStepError, case .http(let code) = stepError {
            switch code {
            case 404, 410:
                return (.failed, reason)
            case 500, 502:
                return (.transient, "服务器暂时异常（HTTP \(code)，\(step)）")
            case 403, 429:
                return (.transient, "访问受限/限流（HTTP \(code)，\(step)），可能与 IP 或节点有关")
            default:
                return (.failed, reason)
            }
        }
        // 4. 原因字符串判定（无 error 的逻辑失败）
        if reason == "详情未回内容" {
            if isProxy {
                return (.transient, "代理环境下详情未回内容")
            }
            return (.transient, "疑需节点：详情未回内容")
        }
        if reason == "模块未解出线路" {
            if isProxy {
                return (.transient, "代理环境下模块未解出线路")
            }
            return (.transient, "疑需节点：模块未解出线路")
        }
        // 5. 其余一律真失败（unsupported URL、JS 异常、functionMissing、解不出可播链接、
        //    无效播单、嵌页死链、首片非媒体等）
        return (.failed, reason)
    }

    /// 从 error 里提取传输层错误码：桥接还原的 .transport，或 NSError 的 NSURLErrorDomain 码。
    /// 只认阻断类码（超时/找不到主机/连不上/连接断/DNS 失败/TLS 失败），其余返回 nil。
    private func transportErrorCode(from error: Error?) -> Int? {
        guard let error else { return nil }
        let blockCodes: Set<Int> = [
            URLError.Code.timedOut.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue,
            URLError.Code.secureConnectionFailed.rawValue
        ]
        if case let WidgetHost.WidgetHostError.transport(code, _) = error {
            return blockCodes.contains(code) ? code : nil
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, blockCodes.contains(nsError.code) {
            return nsError.code
        }
        return nil
    }

    /// MP4 前缀校验的失败原因（供 Step 5 区分“响应是 HTML → 回退嵌页探活”与真失败）。
    private enum PrefixCheckError: Error, LocalizedError, Equatable {
        case httpStatus(Int)
        case htmlResponse
        case invalidMedia(String)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "HTTP \(code)"
            case .htmlResponse: return "返回 HTML（不是视频）"
            case .invalidMedia(let message): return message
            }
        }
    }

    /// 限流前缀抓取结果：状态码 / 终态 URL / Content-Type / 响应头（key 已小写）/ 已读前缀。
    private struct PrefixFetchResult: Sendable {
        let statusCode: Int
        let finalURL: URL?
        let contentType: String
        let headers: [String: String]
        let data: Data

        /// 显式 init（不依赖编译器合成的 memberwise init，Xcode 27.2 上合成行为不可靠）。
        init(statusCode: Int, finalURL: URL?, contentType: String, headers: [String: String], data: Data) {
            self.statusCode = statusCode
            self.finalURL = finalURL
            self.contentType = contentType
            self.headers = headers
            self.data = data
        }
    }

    /// 限流前缀抓取器：只读前 maxBytes 就取消，绝不把整个响应读进内存。
    /// （MP4 直链若无视 Range 头返回 1GB 全量包，data(for:) 会直接 OOM；嵌页探活同理。）
    /// 用法：ChunkedPrefixFetcher.fetch(request:maxBytes:)；总超时由调用方的 withStepTimeout 控。
    private final class ChunkedPrefixFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let maxBytes: Int
        private var task: URLSessionDataTask?
        private var session: URLSession?
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<PrefixFetchResult, Error>?
        private var finished = false
        private var truncatedIntentionally = false

        private init(maxBytes: Int) {
            self.maxBytes = maxBytes
            super.init()
        }

        static func fetch(request: URLRequest, maxBytes: Int) async throws -> PrefixFetchResult {
            let fetcher = ChunkedPrefixFetcher(maxBytes: maxBytes)
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 12
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: fetcher, delegateQueue: nil)
            fetcher.session = session
            let task = session.dataTask(with: request)
            fetcher.task = task
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PrefixFetchResult, Error>) in
                    fetcher.lock.lock()
                    fetcher.continuation = continuation
                    fetcher.lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
                session.invalidateAndCancel()
            }
        }

        private func finish(with result: Result<PrefixFetchResult, Error>, session: URLSession? = nil) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(with: result)
            session?.invalidateAndCancel()
        }

        private func finishWithCurrentBuffer(session: URLSession?) {
            lock.lock()
            let dataCopy = buffer
            lock.unlock()
            let status = response?.statusCode ?? 0
            var headers: [String: String] = [:]
            if let allHeaders = response?.allHeaderFields {
                for (key, value) in allHeaders {
                    headers["\(key)".lowercased()] = "\(value)"
                }
            }
            let contentType = headers["content-type"] ?? ""
            finish(with: .success(PrefixFetchResult(
                statusCode: status,
                finalURL: response?.url,
                contentType: contentType,
                headers: headers,
                data: dataCopy
            )), session: session)
        }

        // MARK: URLSessionDataDelegate

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let httpResponse = response as? HTTPURLResponse {
                self.response = httpResponse
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let remaining = maxBytes - buffer.count
            if remaining <= 0 {
                lock.unlock()
                dataTask.cancel()
                return
            }
            buffer.append(data.prefix(remaining))
            let reached = buffer.count >= maxBytes
            lock.unlock()
            if reached {
                truncatedIntentionally = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error as NSError?, error.domain == NSURLErrorDomain, error.code == URLError.Code.cancelled.rawValue {
                if truncatedIntentionally {
                    finishWithCurrentBuffer(session: session)
                } else {
                    finish(with: .failure(error), session: session)
                }
                return
            }
            if let error = error {
                finish(with: .failure(error), session: session)
                return
            }
            finishWithCurrentBuffer(session: session)
        }
    }

    /// 带超时的操作：超时即 throw CheckStepError.timeout。
    /// 每步超时按模块声明（WidgetMetadata.checkTimeouts，stepTimeout 按步解析分步默认值）。
    /// 超时判该步失败，不让一个慢源卡住整轮。
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

    /// 模块声明的自检步超时（毫秒）：按步查分步默认值（见 CheckTimeouts.effectiveMs），
    /// 声明值优先，钳制到 1000...60000ms，防止模块写错数字（1ms 或 10 分钟）把自检卡住或拖垮。
    private func stepTimeout(_ kind: CheckStepKind, declared: Int?) -> Int {
        CheckTimeouts.effectiveMs(for: kind, declared: declared)
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
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let (_, response) = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "selfcheck",
            preservedHeaders: ["User-Agent": NetConstants.iPhoneUserAgent],
            timeout: 12
        )
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// GET 一个 URL 的全文（播单步用，取 m3u8 文本）。referer 传帖子链接（nmcorp 这类防盗链的线要它）。
    private static func httpBody(of urlString: String, referer: String? = nil) async throws -> String {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.timeoutInterval = 12
        var preservedHeaders: [String: String] = ["User-Agent": NetConstants.iPhoneUserAgent]
        if let referer { preservedHeaders["Referer"] = referer }
        let (data, response) = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "selfcheck",
            preservedHeaders: preservedHeaders,
            timeout: 12
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CheckStepError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Range 取一个 URL 的前 length 字节（首片步用；MP4 也用它取首字节）。
    private static func httpRangeData(of urlString: String, length: Int, referer: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        var preservedHeaders: [String: String] = ["User-Agent": NetConstants.iPhoneUserAgent]
        if let referer { preservedHeaders["Referer"] = referer }
        let (data, response) = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "selfcheck",
            preservedHeaders: preservedHeaders,
            timeout: 12
        )
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

    /// 五步验真（对一个源）：列表→详情→解析→播单→首片，每步超时按模块声明
    /// （WidgetMetadata.checkTimeouts，没声明的步用分步默认值）。
    /// 固定验线取样本；每个样本顺次跑详情→解析→播单→首片（列表步只做一次）。
    /// 全部样本走完五步才算 ok；任一样本死在某步即按失败分类记结果
    /// （真失败 .failed / 没测成 .transient，见 classifyFailure）。
    /// 返回 SourceCheckResult（steps = 决定本次结果的那个样本的五步；fingerprint = 当前 JS 指纹）。
    /// 深探针不由这里填（单独轮次，由 runDeepProbeRound 写）。
    /// 取消时抛 CancellationError（不记失败结果，断点续跑时重测）。
    private func runFiveStepCheck(host: WidgetHost, source: SourceRecord) async throws -> SourceCheckResult {
        let fingerprint = self.fingerprint(for: source)
        // 模块声明的自检步超时（没声明的步用分步默认值，见 CheckTimeouts.effectiveMs）。
        let checkTimeouts = host.meta.checkTimeouts
        // 1. 列表：固定验线取样本
        let listStart = Date()
        let listElapsed = { Int(Date().timeIntervalSince(listStart) * 1000) }
        guard let probe = host.fixedProbeModule() else {
            let step = CheckStepResult(name: "列表", passed: false, reason: "这个源没有固定验线模块", milliseconds: listElapsed())
            return SourceCheckResult(status: .failed, failedLines: ["固定验线": "这个源没有固定验线模块"], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: "这个源没有固定验线模块", sourceFingerprint: fingerprint)
        }
        let samples: [VideoItem]
        do {
            samples = try await withStepTimeout(stepTimeout(.list, declared: checkTimeouts.listMs)) { try await host.loadList(moduleId: probe.id, page: 1) }
        } catch {
            try throwIfCancelled()
            let reason = checkReason(for: error)
            let step = CheckStepResult(name: "列表", passed: false, reason: reason, milliseconds: listElapsed())
            let (status, diagnosis) = classifyFailure(step: "列表", reason: reason, error: error)
            return SourceCheckResult(status: status, failedLines: ["固定验线": diagnosis], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: diagnosis, sourceFingerprint: fingerprint)
        }
        guard !samples.isEmpty else {
            let step = CheckStepResult(name: "列表", passed: false, reason: "固定验线没有返回样本", milliseconds: listElapsed())
            return SourceCheckResult(status: .failed, failedLines: ["固定验线": "固定验线没有返回样本"], checkedAt: Date(), steps: [step], failedStep: "列表", failedReason: "固定验线没有返回样本", sourceFingerprint: fingerprint)
        }
        let listStep = CheckStepResult(name: "列表", passed: true, reason: nil, milliseconds: listElapsed())

        // 每个样本顺次跑详情→解析→播单→首片
        var failedLines: [String: String] = [:]
        var decidingSteps: [CheckStepResult] = [listStep]
        var firstFailure: (step: String, reason: String, error: Error?)?
        for (index, sample) in samples.enumerated() {
            try throwIfCancelled()
            let (steps, failureError) = try await runSampleSteps(host: host, sample: sample)
            if index == 0 { decidingSteps = [listStep] + steps }
            if let failed = steps.first(where: { !$0.passed }) {
                let diagnosis = classifyFailure(step: failed.name, reason: failed.reason ?? "", error: failureError).reason
                failedLines[sample.title] = "死在\(failed.name)步：\(diagnosis)"
                if firstFailure == nil {
                    firstFailure = (failed.name, failed.reason ?? "", failureError)
                    decidingSteps = [listStep] + steps
                }
            }
        }
        if let failure = firstFailure {
            let (status, diagnosis) = classifyFailure(step: failure.step, reason: failure.reason, error: failure.error)
            return SourceCheckResult(status: status, failedLines: failedLines, checkedAt: Date(), steps: decidingSteps, failedStep: failure.step, failedReason: diagnosis, sourceFingerprint: fingerprint)
        }
        return SourceCheckResult(status: .ok, failedLines: [:], checkedAt: Date(), steps: decidingSteps, failedStep: nil, failedReason: nil, sourceFingerprint: fingerprint)
    }

    /// 一个样本的详情→解析→播单→首片（四步顺次，每步超时按模块声明，
    /// 没声明的步用分步默认值，某步失败即停）。
    /// 详情：优先调模块 loadDetail（启动预热，解析步消费）；模块没有 loadDetail 时，
    /// http(s) 链接回退裸 GET，自定义 scheme 跳过本步。
    /// 解析：loadResource 解出可播线路（统一分类器 hls/directFile/embed），按播放顺序排，
    /// 最多验 2 条候选；只返回空 URL 占位行 → “模块未解出线路”（没测成方向），
    /// 一条线都没有 → “解不出可播链接”（真失败）。
    /// 播单/首片：按线种分流——hls 验 m3u8 + 首片；directFile 跳过播单、验 64KB 前缀；
    /// embed 轻量四重探活、首片跳过。
    /// 返回（四步结果，首个失败步的原始 error——分类用；逻辑失败时为 nil）。
    /// 取消时抛 CancellationError。
    private func runSampleSteps(host: WidgetHost, sample: VideoItem) async throws -> (steps: [CheckStepResult], failureError: Error?) {
        var steps: [CheckStepResult] = []
        // 模块声明的自检步超时（没声明的步用分步默认值，见 CheckTimeouts.effectiveMs）。
        let checkTimeouts = host.meta.checkTimeouts

        // 2. 详情
        let detailStart = Date()
        let detailElapsed = { Int(Date().timeIntervalSince(detailStart) * 1000) }
        do {
            let detail = try await withStepTimeout(stepTimeout(.detail, declared: checkTimeouts.detailMs)) {
                try await host.loadDetail(link: sample.link)
            }
            if detail.episodes.isEmpty && detail.videoURL == nil {
                steps.append(CheckStepResult(name: "详情", passed: false, reason: "详情未回内容", milliseconds: detailElapsed()))
                return (steps, nil)
            }
            steps.append(CheckStepResult(name: "详情", passed: true, reason: nil, milliseconds: detailElapsed()))
        } catch {
            try throwIfCancelled()
            if let hostError = error as? WidgetHost.WidgetHostError, case .functionMissing = hostError {
                // 模块没有 loadDetail：http(s) 回退裸 GET；自定义 scheme 跳过本步
                if let url = URL(string: sample.link), url.scheme == "http" || url.scheme == "https" {
                    do {
                        let status = try await withStepTimeout(stepTimeout(.detail, declared: checkTimeouts.detailMs)) { try await Self.httpStatus(of: sample.link) }
                        guard status == 200 else {
                            steps.append(CheckStepResult(name: "详情", passed: false, reason: "HTTP \(status)", milliseconds: detailElapsed()))
                            return (steps, CheckStepError.http(status))
                        }
                        steps.append(CheckStepResult(name: "详情", passed: true, reason: nil, milliseconds: detailElapsed()))
                    } catch {
                        try throwIfCancelled()
                        steps.append(CheckStepResult(name: "详情", passed: false, reason: checkReason(for: error), milliseconds: detailElapsed()))
                        return (steps, error)
                    }
                } else {
                    steps.append(CheckStepResult(name: "详情", passed: true, reason: "跳过：自定义链接由模块解析", milliseconds: detailElapsed(), skipped: true))
                }
            } else {
                steps.append(CheckStepResult(name: "详情", passed: false, reason: checkReason(for: error), milliseconds: detailElapsed()))
                return (steps, error)
            }
        }

        // 3. 解析
        let parseStart = Date()
        let parseElapsed = { Int(Date().timeIntervalSince(parseStart) * 1000) }
        let candidates: [(line: PlayLine, kind: PlaybackEngine.PlayableLineKind)]
        do {
            let lines = try await withStepTimeout(stepTimeout(.parse, declared: checkTimeouts.parseMs)) { try await host.loadResource(link: sample.link, title: sample.title) }
            let classified = PlaybackEngine.orderPlayableLines(lines, preferredKind: host.preferredLine)
                .compactMap { line -> (PlayLine, PlaybackEngine.PlayableLineKind)? in
                    guard !line.url.isEmpty, let kind = PlaybackEngine.classifyPlayableLine(line) else { return nil }
                    return (line, kind)
                }
            if classified.isEmpty {
                // 区分：一条线都没有（真失败）vs 只有空 URL 占位行（模块未解出线路，没测成方向）
                let hasPlaceholder = lines.contains { $0.url.isEmpty }
                if hasPlaceholder {
                    steps.append(CheckStepResult(name: "解析", passed: false, reason: "模块未解出线路", milliseconds: parseElapsed()))
                } else {
                    steps.append(CheckStepResult(name: "解析", passed: false, reason: "解不出可播链接", milliseconds: parseElapsed()))
                }
                return (steps, nil)
            }
            candidates = Array(classified.prefix(2))
            steps.append(CheckStepResult(name: "解析", passed: true, reason: nil, milliseconds: parseElapsed()))
        } catch {
            try throwIfCancelled()
            steps.append(CheckStepResult(name: "解析", passed: false, reason: checkReason(for: error), milliseconds: parseElapsed()))
            return (steps, error)
        }

        // 4. 播单 + 5. 首片（按线种分流；验首选，失败则验下一条，最多 2 条；
        //    全部失败时记走得最远的那次尝试的两步）
        var bestSteps: [CheckStepResult] = []
        var bestScore = -1
        var bestError: Error?
        for candidate in candidates {
            let (playlistStep, firstFrameStep, candidateError) = try await verifyCandidate(candidate, sample: sample, checkTimeouts: checkTimeouts)
            let score = (playlistStep.passed ? 1 : 0) + (firstFrameStep.passed ? 1 : 0)
            if score > bestScore {
                bestScore = score
                bestSteps = [playlistStep, firstFrameStep]
                bestError = candidateError
            }
            if score == 2 {
                steps.append(contentsOf: bestSteps)
                return (steps, nil)
            }
        }
        steps.append(contentsOf: bestSteps)
        return (steps, bestError)
    }

    /// 验一条候选线（播单 + 首片），返回两步结果与首个失败的原始 error（分类用；逻辑失败为 nil）。
    /// 取消时抛 CancellationError（不记失败结果）。
    private func verifyCandidate(_ candidate: (line: PlayLine, kind: PlaybackEngine.PlayableLineKind), sample: VideoItem, checkTimeouts: CheckTimeouts) async throws -> (playlist: CheckStepResult, firstFrame: CheckStepResult, error: Error?) {
        let line = candidate.line
        switch candidate.kind {
        case .hls:
            // 播单：取回 m3u8，含 #EXTM3U
            let playlistStart = Date()
            let playlistElapsed = { Int(Date().timeIntervalSince(playlistStart) * 1000) }
            let playlistText: String
            do {
                playlistText = try await withStepTimeout(stepTimeout(.playlist, declared: checkTimeouts.playlistMs)) { try await Self.httpBody(of: line.url, referer: sample.link) }
                guard playlistText.contains("#EXTM3U") else {
                    let playlistStep = CheckStepResult(name: "播单", passed: false, reason: "不是有效的 m3u8 播单", milliseconds: playlistElapsed())
                    let firstFrameStep = CheckStepResult(name: "首片", passed: false, reason: "播单无效", milliseconds: 0)
                    return (playlistStep, firstFrameStep, nil)
                }
            } catch {
                try throwIfCancelled()
                let playlistStep = CheckStepResult(name: "播单", passed: false, reason: checkReason(for: error), milliseconds: playlistElapsed())
                let firstFrameStep = CheckStepResult(name: "首片", passed: false, reason: "播单无效", milliseconds: 0)
                return (playlistStep, firstFrameStep, error)
            }
            let playlistStep = CheckStepResult(name: "播单", passed: true, reason: nil, milliseconds: playlistElapsed())
            // 首片：取第一个引用（变体播单或分片）并确认可取
            let firstFrameStart = Date()
            let firstFrameElapsed = { Int(Date().timeIntervalSince(firstFrameStart) * 1000) }
            do {
                guard let firstRef = Self.firstMediaURL(in: playlistText, baseURL: line.url) else {
                    return (playlistStep, CheckStepResult(name: "首片", passed: false, reason: "播单里没有分片", milliseconds: firstFrameElapsed()), nil)
                }
                if firstRef.lowercased().contains(".m3u8") {
                    let variant = try await withStepTimeout(stepTimeout(.firstFrame, declared: checkTimeouts.firstFrameMs)) { try await Self.httpBody(of: firstRef, referer: sample.link) }
                    guard variant.contains("#EXTM3U") else {
                        return (playlistStep, CheckStepResult(name: "首片", passed: false, reason: "变体播单无效", milliseconds: firstFrameElapsed()), nil)
                    }
                } else {
                    let data = try await withStepTimeout(stepTimeout(.firstFrame, declared: checkTimeouts.firstFrameMs)) { try await Self.httpRangeData(of: firstRef, length: 32768, referer: sample.link) }
                    guard !data.isEmpty else {
                        return (playlistStep, CheckStepResult(name: "首片", passed: false, reason: "首片分片取不到数据", milliseconds: firstFrameElapsed()), nil)
                    }
                }
                return (playlistStep, CheckStepResult(name: "首片", passed: true, reason: nil, milliseconds: firstFrameElapsed()), nil)
            } catch {
                try throwIfCancelled()
                return (playlistStep, CheckStepResult(name: "首片", passed: false, reason: checkReason(for: error), milliseconds: firstFrameElapsed()), error)
            }
        case .directFile:
            // 播单步不适用（MP4 直链无播单）；首片验 64KB 前缀
            let playlistStep = CheckStepResult(name: "播单", passed: true, reason: "跳过：MP4 直链无播单", milliseconds: 0, skipped: true)
            let firstFrameStart = Date()
            let firstFrameElapsed = { Int(Date().timeIntervalSince(firstFrameStart) * 1000) }
            do {
                try await withStepTimeout(stepTimeout(.firstFrame, declared: checkTimeouts.firstFrameMs)) { try await self.verifyMP4Prefix(urlString: line.url, headers: line.headers, referer: sample.link) }
                return (playlistStep, CheckStepResult(name: "首片", passed: true, reason: nil, milliseconds: firstFrameElapsed()), nil)
            } catch {
                try throwIfCancelled()
                // 响应是 HTML：可能是一条伪装成直链的嵌页，回退按嵌页重验
                if let prefixError = error as? PrefixCheckError, prefixError == .htmlResponse {
                    return try await verifyEmbedFallback(line: line, sample: sample, checkTimeouts: checkTimeouts, start: firstFrameStart)
                }
                return (playlistStep, CheckStepResult(name: "首片", passed: false, reason: checkReason(for: error), milliseconds: firstFrameElapsed()), error)
            }
        case .embed:
            // 播单步：升级版嵌页四重探活；首片步不适用（不伪造首片成功）
            let playlistStart = Date()
            let playlistElapsed = { Int(Date().timeIntervalSince(playlistStart) * 1000) }
            do {
                let probe = try await withStepTimeout(stepTimeout(.playlist, declared: checkTimeouts.playlistMs)) { try await self.probeEmbedPage(urlString: line.url, headers: line.headers, fallbackReferer: sample.link) }
                guard probe.passed else {
                    let playlistStep = CheckStepResult(name: "播单", passed: false, reason: probe.note, milliseconds: playlistElapsed())
                    let firstFrameStep = CheckStepResult(name: "首片", passed: false, reason: "嵌页不可达", milliseconds: 0)
                    return (playlistStep, firstFrameStep, nil)
                }
                let playlistStep = CheckStepResult(name: "播单", passed: true, reason: nil, milliseconds: playlistElapsed())
                let firstFrameStep = CheckStepResult(name: "首片", passed: true, reason: "跳过：嵌页未验实际起播", milliseconds: 0, skipped: true)
                return (playlistStep, firstFrameStep, nil)
            } catch {
                try throwIfCancelled()
                let playlistStep = CheckStepResult(name: "播单", passed: false, reason: checkReason(for: error), milliseconds: playlistElapsed())
                let firstFrameStep = CheckStepResult(name: "首片", passed: false, reason: "嵌页不可达", milliseconds: 0)
                return (playlistStep, firstFrameStep, error)
            }
        }
    }

    /// 直链校验拿到 HTML 时的回退：把这条线当嵌页重验（探活通过则播单步通过、首片跳过）。
    private func verifyEmbedFallback(line: PlayLine, sample: VideoItem, checkTimeouts: CheckTimeouts, start: Date) async throws -> (playlist: CheckStepResult, firstFrame: CheckStepResult, error: Error?) {
        let elapsed = { Int(Date().timeIntervalSince(start) * 1000) }
        do {
            let probe = try await withStepTimeout(stepTimeout(.playlist, declared: checkTimeouts.playlistMs)) { try await self.probeEmbedPage(urlString: line.url, headers: line.headers, fallbackReferer: sample.link) }
            guard probe.passed else {
                return (CheckStepResult(name: "播单", passed: false, reason: probe.note, milliseconds: elapsed()), CheckStepResult(name: "首片", passed: false, reason: "嵌页不可达", milliseconds: 0), nil)
            }
            return (CheckStepResult(name: "播单", passed: true, reason: nil, milliseconds: elapsed()), CheckStepResult(name: "首片", passed: true, reason: "跳过：嵌页未验实际起播", milliseconds: 0, skipped: true), nil)
        } catch {
            try throwIfCancelled()
            return (CheckStepResult(name: "播单", passed: false, reason: checkReason(for: error), milliseconds: elapsed()), CheckStepResult(name: "首片", passed: false, reason: "嵌页不可达", milliseconds: 0), error)
        }
    }

    /// MP4 直链首片校验：Range 取前 64KB（限流，服务端无视 Range 返回全量包也不灌内存），
    /// 强制 200/206 + 非 html/xml/json + 前 64KB 含 MP4 Box 魔数。
    /// 响应是 HTML 时抛 PrefixCheckError.htmlResponse（调用方回退按嵌页重验）。
    /// 总超时由调用方的 withStepTimeout 控。
    private func verifyMP4Prefix(urlString: String, headers: [String: String]?, referer: String?) async throws {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        request.timeoutInterval = 12
        let result = try await ChunkedPrefixFetcher.fetch(request: request, maxBytes: 65_536)
        guard result.statusCode == 200 || result.statusCode == 206 else {
            throw PrefixCheckError.httpStatus(result.statusCode)
        }
        let contentType = result.contentType.lowercased()
        let badTypes = ["text/html", "application/xml", "text/xml", "application/json", "text/plain"]
        if badTypes.contains(where: { contentType.contains($0) }) {
            throw PrefixCheckError.htmlResponse
        }
        // Content-Type 没写时再看内容：HTML 开头直接判 htmlResponse
        if contentType.isEmpty, result.data.starts(with: Data("<".utf8)) {
            throw PrefixCheckError.htmlResponse
        }
        guard result.data.count >= 12, Self.hasMP4BoxHeader(result.data) else {
            throw PrefixCheckError.invalidMedia("前 64KB 未检测到 MP4 容器头")
        }
    }

    /// Data 前 8 字节的 fourCC 是否为 MP4 容器头（offset 4..7）。
    private static func hasMP4BoxHeader(_ data: Data) -> Bool {
        let validFourCC: Set<String> = ["ftyp", "moov", "mdat", "wide", "free", "styp"]
        guard data.count >= 8 else { return false }
        let tag = String(decoding: data[4..<8], as: UTF8.self)
        return validFourCC.contains(tag)
    }

    /// 嵌页四重结构探活（零 WebView）：终态 URL 跳回首页拦截 + 多语言死链词 +
    /// 正向播放器结构指纹 + CF 盾识别。64KB 限流前缀读取，UTF-8 安全解码。
    /// 返回（是否通过，备注）。CF 盾（403/503 + 挑战特征）算通过，备注“嵌页需 WebView 过盾”。
    /// 总超时由调用方的 withStepTimeout 控。
    private func probeEmbedPage(urlString: String, headers: [String: String]?, fallbackReferer: String?) async throws -> (passed: Bool, note: String) {
        guard let url = URL(string: urlString) else { throw CheckStepError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let fallbackReferer,
           headers?["Referer"] == nil, headers?["referer"] == nil,
           let fallbackURL = URL(string: fallbackReferer),
           let scheme = fallbackURL.scheme, let host = fallbackURL.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.timeoutInterval = 12
        let result = try await ChunkedPrefixFetcher.fetch(request: request, maxBytes: 65_536)
        let bodyLower = String(decoding: result.data, as: UTF8.self).lowercased()
        let cfMitigated = result.headers["cf-mitigated"]?.lowercased() ?? ""
        let serverHeader = result.headers["server"]?.lowercased() ?? ""
        let isCFChallenge = cfMitigated.contains("challenge") ||
            (serverHeader.contains("cloudflare") && (
                bodyLower.contains("just a moment") ||
                bodyLower.contains("cf_chl") ||
                bodyLower.contains("challenge-platform") ||
                bodyLower.contains("cf-turnstile")
            ))
        if (result.statusCode == 403 || result.statusCode == 503) && isCFChallenge {
            return (true, "嵌页需 WebView 过盾 (CF \(result.statusCode))")
        }
        guard (200...299).contains(result.statusCode) else {
            return (false, "嵌页不可达 (HTTP \(result.statusCode))")
        }
        // 1. 终态 URL 跳回首页/错误页拦截
        if url.path.count > 1, let finalPath = result.finalURL?.path.lowercased() {
            let badPaths: Set<String> = ["", "/", "/index.html", "/index.php", "/404", "/deleted", "/error"]
            if badPaths.contains(finalPath) {
                return (false, "嵌页已跳转至首页/失效页 (\(finalPath))")
            }
        }
        // 2. 死链词（英 + 印尼语）
        let deadMarkers = ["file was deleted", "video not found", "has been removed", "file not found", "no longer available", "video was deleted", "expired", "dmca", "tidak ditemukan", "video dihapus", "konten tidak tersedia"]
        if let hit = deadMarkers.first(where: { bodyLower.contains($0) }) {
            return (false, "嵌页提示失效 (\(hit))")
        }
        // 3. 正向播放器结构指纹（至少命中一个才算活）
        let playerSignals = ["<video", "<iframe", "jwplayer", "hls.js", "hls.min.js", "new hls(", "videojs", "plyr", "clappr", "sources:", "\"sources\"", ".m3u8", ".mp4", "eval(function(p,a,c,k,e,d)"]
        guard playerSignals.contains(where: { bodyLower.contains($0) }) else {
            return (false, "嵌页 HTTP \(result.statusCode) 但未发现播放器结构")
        }
        return (true, "嵌页结构可达 (HTTP \(result.statusCode))")
    }

    /// 对单个源跑自检（强制跑，不论指纹；源详情页“立即自检”用）。
    /// 五步验真；结果写入 checkResults 并持久化。
    /// 深探针结果保留：指纹没变沿用旧的深探针，变了（模块更新）则清掉（等深探针轮次重测）。
    /// 取消时返回 nil（不存结果，断点续跑时重测）。
    func runCheck(for source: SourceRecord) async -> SourceCheckResult? {
        // 单源自检不探 captive：重置为 unknown，避免用上一轮的旧值误判
        roundConnectivity = .unknown
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
            let (status, diagnosis) = classifyFailure(step: "列表", reason: error.localizedDescription, error: error)
            let result = SourceCheckResult(
                status: status,
                failedLines: ["加载源": diagnosis],
                checkedAt: Date(),
                failedStep: "列表",
                failedReason: diagnosis,
                sourceFingerprint: fingerprint(for: source)
            )
            await storeCheckResult(result, for: source.id)
            return result
        }
    }

    /// 自检分组（去重）：按模块 id / 站点域名分组，同一组只跑一次固定验线。
    /// 并查集：同 id 或同域名（任一相同）即同一组。
    /// 自检全部源：增量 + 让路（不去重：每个源都单独跑，同站不同模块也是独立的源）。
    /// - 增量：只跑新增/改过（JS 指纹变了）或没测过的源；没动过的跳过，显示上次结果。
    /// - 让路：每测完一个源检查 Task.isCancelled（用户点屏/切页/播放/进后台即停）；
    ///   下次从断点接着跑（已测过且指纹没变的源跳过，不重跑）。
    /// 返回（正常数，失败数，跳过数）。取消时返回已统计到的数（未测的源下次接着跑）。
    func runCheckAll() async -> (ok: Int, failed: Int, transient: Int, skipped: Int) {
        checkAllLock.lock()
        if isCheckAllRunning {
            checkAllLock.unlock()
            // 已在跑：不重入，直接返回当前已统计数（上次结果里的计数）。
            return await MainActor.run {
                let ok = self.checkResults.values.filter { $0.status == .ok }.count
                let failed = self.checkResults.values.filter { $0.status == .failed }.count
                let transient = self.checkResults.values.filter { $0.status == .transient }.count
                let skipped = self.checkResults.values.filter { $0.status == .skipped }.count
                return (ok, failed, transient, skipped)
            }
        }
        isCheckAllRunning = true
        checkAllLock.unlock()
        defer {
            checkAllLock.lock()
            isCheckAllRunning = false
            checkAllLock.unlock()
        }
        var ok = 0
        var failed = 0
        var transient = 0
        var skipped = 0
        // 每轮一次的 captive 探针（只作事后归因：传输失败时区分“本机无网”与“疑需节点”；
        // 超时/DNS/重定向 → unknown，不判 offline，更不短路整轮）。
        roundConnectivity = await probeConnectivity()
        let all = await MainActor.run { self.sources }
        for source in all {
            if Task.isCancelled { break }
            // 增量——指纹没变且有上次结果（非跳过），跳过不重测（显示上次结果）
            let currentFingerprint = fingerprint(for: source)
            let previous = await MainActor.run { self.checkResults[source.id] }
            let needsCheck: Bool
            if let prev = previous, prev.status != .skipped {
                needsCheck = prev.sourceFingerprint != currentFingerprint
            } else {
                needsCheck = true
            }
            if needsCheck {
                guard let result = await runCheck(for: source) else { break }
                switch result.status {
                case .ok: ok += 1
                case .failed: failed += 1
                case .transient: transient += 1
                case .skipped: skipped += 1
                }
            } else if let prev = previous {
                switch prev.status {
                case .ok: ok += 1
                case .failed: failed += 1
                case .transient: transient += 1
                case .skipped: skipped += 1
                }
            }
        }
        return (ok, failed, transient, skipped)
    }

    // MARK: - 深探针（第二层：静音真播到出画）

    /// 深探针轮次（第二层，单独轮次，不跟轻检同一轮跑）：
    /// 轻检通过（status .ok）的源，轮流静音真播到出画（真的起 AVPlayer、静音、确认出首帧）。
    /// 7 天一轮；深探针坏了写进该源的 deepProbe，源条目下标出来。
    /// 让路：每测完一个源检查 Task.isCancelled。
    func runDeepProbeRound() async {
        let all = await MainActor.run { self.sources }
        // 整轮跑完才写时间戳：中途被取消（用户点屏/切页/进后台）就不写，
        // 下次还要跑完剩下的源（旧逻辑取消也写时间戳，等于谎报“这轮已检完”）。
        var completed = true
        for source in all {
            if Task.isCancelled { completed = false; break }
            let light = await MainActor.run { self.checkResults[source.id] }
            guard light?.status == .ok else { continue }
            // 7 天内做过且模块没变的不重做
            if let probe = light?.deepProbe,
               Date().timeIntervalSince(probe.checkedAt) < deepProbeInterval,
               light?.sourceFingerprint == fingerprint(for: source) {
                continue
            }
            guard let candidate = await firstPlayableLine(for: source) else { continue }
            let probe = await Self.deepProbe(line: candidate.line, fallbackReferer: candidate.pageLink)
            // 探针中途被取消：结果不写（取消不算失败，下次断点续跑重测这个源）。
            if Task.isCancelled { completed = false; break }
            await MainActor.run {
                if var current = self.checkResults[source.id] {
                    current.deepProbe = probe
                    self.checkResults[source.id] = current
                    self.saveCheckResults()
                }
            }
        }
        if completed {
            UserDefaults.standard.set(Date(), forKey: lastDeepProbeDefaultsKey)
        }
    }

    /// 取一个源第一条可播线路（固定验线第一个样本的解析结果；深探针用）。
    /// 解析失败返回 nil（该源跳过深探针）。
    /// 返回整条 PlayLine，不只 URL：深探针要用线路的真实请求身份
    /// （模块头/Referer/Cookie），裸 URL 播会把好的源判成坏的。
    private func firstPlayableLine(for source: SourceRecord) async -> (line: PlayLine, pageLink: String)? {
        guard let host = try? loadHost(for: source),
              let probe = host.fixedProbeModule(),
              let samples = try? await host.loadList(moduleId: probe.id, page: 1),
              let first = samples.first,
              let lines = try? await host.loadResource(link: first.link, title: first.title),
              let playable = lines.first(where: {
                  guard !$0.url.isEmpty, let kind = PlaybackEngine.classifyPlayableLine($0) else { return false }
                  // 深探针是真起 AVPlayer：只取直链（hls/directFile），嵌页线播不了，不进深探针
                  return kind == .hls || kind == .directFile
              }) else {
            return nil
        }
        // pageLink（帖子链接）一起带回去：深探针用它当 Referer 兜底
        //（nmcorp 这类防盗链的线，line.referer 是 nil，没它就 403 误判坏源）。
        return (playable, first.link)
    }

    /// 深探针：静音真播到出画（真的起 AVPlayer、静音、确认出首帧画面）。
    /// 15 秒不出画即失败。返回 DeepProbeResult。
    /// 用线路的真实请求身份（模块头/Referer/Cookie + iPhone UA）建 AVURLAsset，
    /// 不用裸 AVPlayerItem(url:)——有的站没 Referer/没模块头就 403，
    /// 裸播会把好的源判成坏的（头拼法与 CustomPlayerView 的 headers 分支同款）。
    /// 取消：withTaskCancellationHandler + CancelBox。取消时停播放器、停 timer、
    /// 只 resume 一次，绝不写结果（runDeepProbeRound 在探针返回后还会再查一次
    /// Task.isCancelled）。CancelBox 建在 continuation 外面：onCancel 可能在
    /// 主队列 setup 块跑之前就触发，那时 player/timer 还没建——盒子先记下
    /// “已取消”，setup 块一进来就直接收尾，不建播放器。
    static func deepProbe(line: PlayLine, fallbackReferer: String? = nil) async -> DeepProbeResult {
        guard let url = URL(string: line.url) else {
            return DeepProbeResult(passed: false, failedStep: "解析", reason: "URL 非法", checkedAt: Date())
        }
        // 头按大小写不敏感合并（mergeHeaders 已做这件事）：模块头里小写的
        // user-agent/referer/cookie 不会再和大写键并存、把自定义 UA 顶掉。
        // 不再混入 defaultBrowserHeaders 的 Accept: application/json——那是给
        // 列表 API 的头，不该进视频请求。
        var base: [String: String] = ["User-Agent": NetConstants.iPhoneUserAgent]
        if let referer = line.referer, !referer.isEmpty {
            base["Referer"] = referer
        } else if let fallbackReferer, !fallbackReferer.isEmpty {
            base["Referer"] = fallbackReferer
        }
        var headers = NetConstants.mergeHeaders(base: base, overrides: line.headers ?? [:])
        if let cookie = line.cookie, !cookie.isEmpty {
            headers = NetConstants.mergeHeaders(base: headers, overrides: ["Cookie": cookie])
        }
        let userAgent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? NetConstants.iPhoneUserAgent

        final class CancelBox: @unchecked Sendable {
            var cancelled = false
            var finish: ((Bool, String?, String?) -> Void)?
        }
        let cancelBox = CancelBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DeepProbeResult, Never>) in
                DispatchQueue.main.async {
                    // 盒子：保活 player/timer，防 continuation 多次 resume
                    // 只在主队列上用（建播放器、轮询、超时都在主队列），不用 Sendable。
                    final class ProbeBox {
                        var done = false
                        var player: AVPlayer?
                        var timer: DispatchSourceTimer?
                    }
                    let box = ProbeBox()
                    func finish(_ passed: Bool, _ step: String?, _ reason: String?) {
                        guard !box.done else { return }
                        box.done = true
                        box.timer?.cancel()
                        box.timer = nil
                        box.player?.pause()
                        box.player?.replaceCurrentItem(with: nil)
                        box.player = nil
                        continuation.resume(returning: DeepProbeResult(passed: passed, failedStep: step, reason: reason, checkedAt: Date()))
                    }
                    // 取消已经先到了（onCancel 在 setup 块之前跑）：直接按取消收尾，不建播放器。
                    if cancelBox.cancelled {
                        finish(false, "取消", "深探针已取消")
                        return
                    }
                    cancelBox.finish = finish
                    let asset = AVURLAsset(url: url, options: [
                        "AVURLAssetHTTPHeaderFieldsKey": headers,
                        "AVURLAssetHTTPUserAgentKey": userAgent,
                    ])
                    let item = AVPlayerItem(asset: asset)
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                    item.add(output)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    player.volume = 0
                    box.player = player
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
        } onCancel: {
            // 主队列上置位 + 收尾（finish 有 done 锁，只 resume 一次；
            // setup 块还没跑时 finish 是 nil，只记 cancelled，setup 块进来自己收尾）。
            DispatchQueue.main.async {
                cancelBox.cancelled = true
                cancelBox.finish?(false, "取消", "深探针已取消")
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
                // 取消了就不写时间戳：这一轮没跑完，下次还要跑（旧逻辑取消也写，等于谎报“已检完”）。
                if !Task.isCancelled {
                    UserDefaults.standard.set(Date(), forKey: self.lastAutoCheckDefaultsKey)
                }
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
        let effectiveToken = resolveGiteeToken(token)
        guard !effectiveToken.isEmpty else {
            return .failure(.network("请先在源页面填写 Gitee Token，才能上传"))
        }
        let failed = await MainActor.run {
            self.sources.filter { self.checkResults[$0.id]?.status == .failed }
        }
        guard !failed.isEmpty else {
            return .failure(.network("没有自检失败的源，不用上传"))
        }
        if case .failure(let error) = await ensureBranch(brokenBranch, token: effectiveToken) {
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

    // MARK: - 上传播放账本（reports 分支）

    /// 归一化 Token：去首尾空白与换行；传入非空则顺手存入 Keychain，传入为空则读 Keychain。
    private func resolveGiteeToken(_ rawToken: String) -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            KeychainHelper.save(trimmed, forKey: giteeTokenKey)
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
    /// 和自检报告放同一个分支，Muse 每天读报告时一起读到——真机上没开节点失败的站，
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
            return .success(fileName)
        case .failure(let error):
            return .failure(error)
        }
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
            let (data, response) = try await URLSession.shared.data(for: getRequest)
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
            let (data, response) = try await URLSession.shared.data(for: repoRequest)
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
            let (data, response) = try await URLSession.shared.data(for: createRequest)
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
                if let (_, recheck) = try? await URLSession.shared.data(for: getRequest),
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
            let (data, response) = try await URLSession.shared.data(for: getRequest)
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
            let (data, response) = try await URLSession.shared.data(for: writeRequest)
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

/// 五步验真里一步失败的原因（内部用，转成人话靠 checkReason）。
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
    /// 跳过（本步不适用，如嵌页的播单/首片、自定义 scheme 的详情）：passed 为 true，
    /// 但 UI 显示“跳过”而不是“通过”。旧数据缺失时默认 false。
    let skipped: Bool

    /// 显式 init（不依赖编译器合成的 memberwise init，Xcode 27.2 上合成行为不可靠）。
    init(name: String, passed: Bool, reason: String?, milliseconds: Int, skipped: Bool = false) {
        self.name = name
        self.passed = passed
        self.reason = reason
        self.milliseconds = milliseconds
        self.skipped = skipped
    }

    /// 旧数据没有 skipped 字段时默认 false（decodeIfPresent），新数据正常解码。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        passed = try container.decode(Bool.self, forKey: .passed)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        milliseconds = try container.decode(Int.self, forKey: .milliseconds)
        skipped = try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }
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
/// skipped = 旧版去重跳过（2026-11-26 已删，不再产生；字段保留只为解码旧存数据）。
struct SourceCheckResult: Codable {
    enum Status: String, Codable {
        case ok
        case failed
        /// 没测成（超时/传输失败/疑需节点等）：本次没法判定源是好是坏，不计失败、不上传坏模块
        case transient
        /// 旧版去重跳过（已删，不再产生；保留只为解码旧存数据）
        case skipped
    }
    var status: Status
    var failedLines: [String: String]
    var checkedAt: Date?
    /// 旧版跳过时重复的那个源的 id（已删，不再产生；保留只为解码旧存数据）
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
