import Foundation

/// 下载任务状态
enum DownloadState: String {
    case downloading
    case completed
    case failed
}

/// 一条下载任务
struct DownloadTask: Identifiable {
    let id: UUID
    let title: String
    var progress: Double
    var state: DownloadState
    var fileURL: URL?
    var errorMessage: String?

    /// 界面层用的中文状态文案（MyView 直接读 task.status）。
    var status: String {
        switch state {
        case .downloading: return "下载中"
        case .completed: return "已完成"
        case .failed: return errorMessage ?? "下载失败"
        }
    }
}

/// HLS / MP4 下载到 Documents/Downloads/。
/// 不限 Wi-Fi（不设 allowsCellularAccess = false，移动数据也能下）；
/// 能下就做、不能下就不做、不强求——失败留中文错误信息。
@MainActor
final class Downloader: ObservableObject {

    @Published private(set) var tasks: [DownloadTask] = []

    private let fileManager = FileManager.default

    private var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - HLS：抓 m3u8，分片逐个下载拼成单个文件

    /// 抓 m3u8，解析分片 URL（相对转绝对），逐个下载拼成单个 .ts（或 .mp4）存到
    /// Documents/Downloads/。进度按已下载分片数算；失败留错误信息。
    /// fMP4（分片是 .m4s）要先写 #EXT-X-MAP 的 init.mp4，再拼分片，拼出来是可播的 .mp4；
    /// .ts 分片直接拼成 .ts。
    func downloadHLS(_ url: URL, title: String) async {
        let id = UUID()
        tasks.append(DownloadTask(id: id, title: title, progress: 0, state: .downloading, fileURL: nil, errorMessage: nil))
        // destURL 放 do 外面：失败时 catch 里要删残文件（P1-8）。
        var destURL: URL?
        do {
            let (playlistURL, playlistText) = try await resolveMediaPlaylist(from: url)
            let (segments, initURL) = try parsePlaylist(playlistURL, text: playlistText)
            guard !segments.isEmpty else {
                throw DownloadError.emptyPlaylist
            }
            let isFMP4 = segments.first?.pathExtension.lowercased() == "m4s"
            let ext = isFMP4 ? "mp4" : "ts"
            let dest = uniqueFileURL(for: title, ext: ext)
            destURL = dest
            _ = fileManager.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }
            var done = 0
            if let initURL {
                let initData = try await fetchData(from: initURL)
                try handle.write(contentsOf: initData)
            }
            for segment in segments {
                let data = try await fetchData(from: segment)
                try handle.write(contentsOf: data)
                done += 1
                updateTask(id: id) { $0.progress = Double(done) / Double(segments.count) }
            }
            updateTask(id: id) {
                $0.progress = 1
                $0.state = .completed
                $0.fileURL = destURL
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateTask(id: id) {
                $0.state = .failed
                $0.errorMessage = message
            }
            // 失败不留残文件（P1-8）：分片已拼了一半的 destURL 删掉。
            // （defer 已先关了 FileHandle，删文件是安全的。）
            if let destURL {
                try? fileManager.removeItem(at: destURL)
            }
        }
    }

    /// 如果给的是 master 播单（含 #EXT-X-STREAM-INF），跟一层 variant（取最大码率），
    /// 拿到真正的媒体播单；本身就是媒体播单的直接返回。
    /// 返回媒体播单最终 URL + 已取到的播单文本：媒体播单只 GET 一次（P1-8），
    /// 文本直接复用，不再由 parsePlaylist 重取一次；相对地址一律按重定向后
    /// 的最终 URL 解析，不按原始 URL。
    private func resolveMediaPlaylist(from url: URL) async throws -> (url: URL, text: String) {
        let (finalURL, text) = try await fetchTextAndFinalURL(from: url)
        guard text.contains("#EXTM3U") else { throw DownloadError.notPlaylist }
        let variants = parseVariants(text, base: finalURL)
        guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
            return (finalURL, text)
        }
        return try await fetchTextAndFinalURL(from: best.url)
    }

    private func parseVariants(_ text: String, base: URL) -> [(bandwidth: Int, url: URL)] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [(bandwidth: Int, url: URL)] = []
        var pendingBandwidth = 0
        var pending = false
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = bandwidth(from: line)
                pending = true
            } else if pending, !line.isEmpty, !line.hasPrefix("#") {
                if let resolved = URL(string: line, relativeTo: base)?.absoluteURL {
                    out.append((bandwidth: pendingBandwidth, url: resolved))
                }
                pending = false
            }
        }
        return out
    }

    private func bandwidth(from line: String) -> Int {
        guard let range = line.range(of: "BANDWIDTH=") else { return 0 }
        let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    /// 解析媒体播单：#EXT-X-MAP 的 init 地址 + 所有分片地址（相对转绝对）。
    /// AES-128 / SAMPLE-AES 加密的播单直接 throw（下不了，明说，不硬拼）。
    /// #EXT-X-BYTERANGE 的播单也 throw：分片是同一文件的字节范围，
    /// 不能按“每行一个独立分片 URL”逐个全量下载拼合。
    /// 文本由调用方一次取好传进来，不再自己重取（P1-8：媒体播单双 GET）；
    /// 相对地址按传入的最终 URL（已跟完重定向）解析。
    private func parsePlaylist(_ url: URL, text: String) throws -> (segments: [URL], initURL: URL?) {
        guard text.contains("#EXTM3U") else { throw DownloadError.notPlaylist }
        if text.contains("#EXT-X-KEY")
            && (text.contains("METHOD=AES-128") || text.contains("METHOD=SAMPLE-AES")) {
            throw DownloadError.encrypted
        }
        if text.contains("#EXT-X-BYTERANGE") {
            throw DownloadError.unsupported("这个播单用了分片字节范围（BYTERANGE），暂不支持下载")
        }
        var initURL: URL?
        var segments: [URL] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = quotedURI(from: line),
                   let resolved = URL(string: uri, relativeTo: url)?.absoluteURL {
                    initURL = resolved
                }
            } else if !line.isEmpty, !line.hasPrefix("#") {
                if let resolved = URL(string: line, relativeTo: url)?.absoluteURL {
                    segments.append(resolved)
                }
            }
        }
        return (segments, initURL)
    }

    private func quotedURI(from line: String) -> String? {
        guard let start = line.range(of: "URI=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // MARK: - MP4：直接下载，系统级断点续传

    /// URLSession 直接下载到 Documents/Downloads/。
    /// 断点续传靠系统：下载失败时 URLSession 会在 error 里给 resumeData，
    /// 用它重试一次（Range 续传）；重试也失败就报失败。
    func downloadMP4(_ url: URL, title: String) async {
        let id = UUID()
        tasks.append(DownloadTask(id: id, title: title, progress: 0, state: .downloading, fileURL: nil, errorMessage: nil))
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let destURL = uniqueFileURL(for: title, ext: ext)
        do {
            // P0-4：落盘已在 downloadOnce 的 completion handler 返回前同步完成
            //（见 finishDownload），这里拿到的就是最终地址，不再 await 返回后
            // 才 moveItem——临时文件那时可能已被系统删掉。
            let finalURL = try await downloadFileWithResume(from: url, taskId: id, destURL: destURL)
            updateTask(id: id) {
                $0.progress = 1
                $0.state = .completed
                $0.fileURL = finalURL
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updateTask(id: id) {
                $0.state = .failed
                $0.errorMessage = message
            }
        }
    }

    private func downloadFileWithResume(from url: URL, taskId: UUID, destURL: URL) async throws -> URL {
        var resumeData: Data?
        var lastError: Error?
        for _ in 0..<2 { // 最多下两次：第一次 + 一次 resume 重试
            do {
                return try await downloadOnce(from: url, resumeData: resumeData, taskId: taskId, destURL: destURL)
            } catch let failure as ResumeFailure {
                if let data = failure.resumeData {
                    resumeData = data
                    lastError = failure.underlying
                    continue
                }
                throw failure.underlying
            }
        }
        throw lastError ?? DownloadError.network("下载失败")
    }

    /// 一次 downloadTask。进度用 task.progress 的 KVO（fractionCompleted），
    /// 观察者由完成盒持有、完成/取消时释放；取消经 withTaskCancellationHandler
    /// 同步取消底层任务（P0-5：旧实现用可变 var timer，被 @Sendable 的完成回调
    /// 捕获并跨线程读写，是数据竞争 + Swift 6 硬编译错，且取消停不掉任务）。
    private func downloadOnce(from url: URL, resumeData: Data?, taskId: UUID, destURL: URL) async throws -> URL {
        let box = DownloadRaceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                // 父任务在进 continuation 前已被取消时 onCancel 先跑、盒子已 finish，
                // installContinuation 返回 false 并已把 pending 结果补恢复——
                // 直接返回，什么都不创建（同 NetworkDiagnostics.URLSessionRaceBox 的 F25）。
                guard box.installContinuation(continuation) else { return }
                let finish: (URL?, URLResponse?, Error?) -> Void = { location, response, error in
                    Self.finishDownload(location: location, response: response, error: error, destURL: destURL, box: box)
                }
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = URLSession.shared.downloadTask(withResumeData: resumeData, completionHandler: finish)
                } else {
                    // MP4 直下也带 iPhone UA（P1-8；与 fetchData 同款）：
                    // 部分 CDN 拒默认 UA。Referer/Cookie 要按线传，
                    // downloadMP4 入口只有 URL+title、无 headers 入口，
                    // 改接口留下一轮，这里不发明新参数。
                    var request = URLRequest(url: url)
                    request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
                    task = URLSession.shared.downloadTask(with: request, completionHandler: finish)
                }
                box.installTask(task)
                let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self?.updateTask(id: taskId) { $0.progress = fraction }
                    }
                }
                box.installObservation(observation)
                task.resume()
            }
        } onCancel: {
            box.finish(.failure(CancellationError()), cancelTask: true)
        }
    }

    /// completion handler 内同步落盘：临时 location 只在 handler 返回前有效，
    /// moveItem 必须在这里做，不能等 continuation 恢复后再由调用方移
    ///（P0-4：MP4 下载 100% 落盘时 No such file）。落盘失败直接报失败，
    /// 绝不把已失效的临时 location 交回去。
    /// nonisolated（ChatGPT P1-3）：Downloader 是 @MainActor，但本方法在
    /// URLSession completion handler（后台线程可执行）里调；体内只操作
    /// FileManager 与 DownloadRaceBox，不碰 Downloader 的主线程状态。
    nonisolated private static func finishDownload(location: URL?, response: URLResponse?, error: Error?, destURL: URL, box: DownloadRaceBox) {
        let result: Result<URL, Error>
        if let error {
            // 失败时 URLSession 会在 userInfo 里给 resumeData（能续传时）
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                result = .failure(ResumeFailure(resumeData: resumeData, underlying: error))
            } else {
                result = .failure(DownloadError.network(error.localizedDescription))
            }
        } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // downloadTask 的 HTTP 错误不走 error，得自己看 statusCode
            //（404 也会“成功”返回一个装着错误页的临时文件）。
            result = .failure(DownloadError.httpStatus(http.statusCode))
        } else if let location {
            // 已终结（取消路径已先抢到完成权）时不落盘：迟到的 completion
            // 再 moveItem 会删掉/覆盖后来同名新建的下载文件。
            guard !box.isFinished else { return }
            do {
                // 目标已存在（同名残留）先清掉：moveItem 不覆盖已存在文件。
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: location, to: destURL)
                result = .success(destURL)
            } catch {
                result = .failure(DownloadError.network("下载完成但保存失败：\(error.localizedDescription)"))
            }
        } else {
            result = .failure(DownloadError.network("下载完成但没拿到文件"))
        }
        // 取消与完成竞态（ChatGPT P2-2 = Gemini P2-5）：box.finish 返回
        // false 表示取消路径已先抢到完成权——文件虽已落盘，UI 却显示取消，
        // 把刚落盘的 destURL 删掉，不留孤儿文件。
        let wonRace = box.finish(result, cancelTask: false)
        if !wonRace, case .success = result {
            try? FileManager.default.removeItem(at: destURL)
        }
    }

    // MARK: - 小工具

    /// 取播单文本 + 重定向后的最终 URL（P1-8：相对地址按最终 URL 解析）。
    private func fetchTextAndFinalURL(from url: URL) async throws -> (url: URL, text: String) {
        let (data, response) = try await fetchDataWithResponse(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.badResponse
        }
        return (response.url ?? url, text)
    }

    private func fetchData(from url: URL) async throws -> Data {
        try await fetchDataWithResponse(from: url).data
    }

    private func fetchDataWithResponse(from url: URL) async throws -> (data: Data, response: URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DownloadError.httpStatus(http.statusCode)
            }
            return (data, response)
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.network(error.localizedDescription)
        }
    }

    private func updateTask(id: UUID, _ change: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// 从列表里去掉一条任务（UI 清理用，不删文件）。
    func removeTask(_ task: DownloadTask) {
        tasks.removeAll { $0.id == task.id }
    }

    /// delete 是 removeTask 的别名（界面层 MyView 调 downloader.delete(task)，
    /// 左滑 destructive“删除”）。
    /// （P1-8：已落盘的文件一起删掉，不留孤儿文件；正在下（fileURL 为 nil）
    /// 的任务这里停不掉——downloadOnce/downloadHLS 的底层任务句柄没存下来，
    /// 取消在途下载要改接口存 Task 句柄，留下一轮。）
    func delete(_ task: DownloadTask) {
        if let fileURL = task.fileURL {
            try? fileManager.removeItem(at: fileURL)
        }
        removeTask(task)
    }

    private func uniqueFileURL(for title: String, ext: String) -> URL {
        let base = sanitizedTitle(title)
        var candidate = downloadsDirectory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = downloadsDirectory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func sanitizedTitle(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        var name = title.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "未命名视频" }
        if name.count > 100 { name = String(name.prefix(100)) }
        return name
    }
}

// MARK: - 下载错误（全部中文人话）

enum DownloadError: Error, LocalizedError {
    case notPlaylist
    case emptyPlaylist
    case encrypted
    case unsupported(String)
    case badResponse
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notPlaylist: return "这个链接不是 m3u8 播单，下不了"
        case .emptyPlaylist: return "播单里没有分片，下不了"
        case .encrypted: return "这个视频加密了，暂不支持下载"
        case .unsupported(let reason): return reason
        case .badResponse: return "服务器返回的数据看不懂"
        case .httpStatus(let code): return "下载失败（服务器返回 HTTP \(code)）"
        case .network(let reason): return "下载失败：\(reason)"
        }
    }
}

/// downloadTask 失败时带的 resumeData + 原始错误（供重试一次用）。
private struct ResumeFailure: Error {
    let resumeData: Data?
    let underlying: Error
}

/// downloadOnce 的一次性完成盒（与 NetworkDiagnostics.URLSessionRaceBox
/// 同款 pending 设计）：完成回调 / 父取消两路抢一个 continuation，只恢复一次；
/// 先到的结果在 continuation 还没装好时暂存 pending，装好立刻补恢复。
/// 锁保护全部状态；进度 KVO 观察者也由盒子持有，完成/取消时释放。
private final class DownloadRaceBox: @unchecked Sendable {
    typealias Completion = CheckedContinuation<URL, Error>

    private let lock = NSLock()
    private var continuation: Completion?
    private var pending: Result<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var finished = false

    /// 是否已终结（finish 已被调用过一次，取消或完成任一路径抢到完成权）。
    /// finishDownload 落盘前用它拦迟到的已取消下载。
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// 装 continuation；已 finish 时返回 false（调用方什么都不创建直接返回）。
    /// false 时 pending 里的结果已在这里补恢复，continuation 不会悬空。
    @discardableResult
    func installContinuation(_ value: Completion) -> Bool {
        lock.lock()
        if finished {
            let result = pending
            lock.unlock()
            if let result {
                value.resume(with: result)
            } else {
                // 防御：finished 但 pending 为空不应发生（finish 总是把结果
                // 写进 pending）；真发生了也别让 continuation 永久挂住。
                value.resume(throwing: CancellationError())
            }
            return false
        }
        continuation = value
        lock.unlock()
        return true
    }

    /// 存 downloadTask；已 finish 时立即取消它（调用方在 install 后 resume，
    /// 已取消的任务 resume 后会立刻以 -999 完成，completion 里 finish 是 no-op）。
    func installTask(_ value: URLSessionDownloadTask) {
        lock.lock()
        let cancel = finished
        if !cancel {
            task = value
        }
        lock.unlock()
        if cancel {
            value.cancel()
        }
    }

    /// 存进度 KVO 观察者；已 finish 时立即释放它（不再收进度回调）。
    func installObservation(_ value: NSKeyValueObservation) {
        lock.lock()
        let invalidate = finished
        if !invalidate {
            observation = value
        }
        lock.unlock()
        if invalidate {
            value.invalidate()
        }
    }

    /// 完成：取消时 cancelTask == true，同步取消底层 downloadTask。
    /// 返回是否抢到完成权（true = 本次调用的结果被采纳；false = 已有别的
    /// 结果先完成，本次结果被丢弃——调用方据此决定要不要清理已落盘文件）。
    @discardableResult
    func finish(_ result: Result<URL, Error>, cancelTask: Bool) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        let observation = self.observation
        self.observation = nil
        if continuation == nil {
            pending = result
        }
        lock.unlock()
        observation?.invalidate()
        if cancelTask {
            task?.cancel()
        }
        continuation?.resume(with: result)
        return true
    }
}
