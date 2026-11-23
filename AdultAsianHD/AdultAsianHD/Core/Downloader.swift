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
        do {
            let playlistURL = try await resolveMediaPlaylist(from: url)
            let (segments, initURL) = try await parsePlaylist(playlistURL)
            guard !segments.isEmpty else {
                throw DownloadError.emptyPlaylist
            }
            let isFMP4 = segments.first?.pathExtension.lowercased() == "m4s"
            let ext = isFMP4 ? "mp4" : "ts"
            let destURL = uniqueFileURL(for: title, ext: ext)
            _ = fileManager.createFile(atPath: destURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destURL)
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
        }
    }

    /// 如果给的是 master 播单（含 #EXT-X-STREAM-INF），跟一层 variant（取最大码率），
    /// 拿到真正的媒体播单；本身就是媒体播单的直接返回。
    private func resolveMediaPlaylist(from url: URL) async throws -> URL {
        let text = try await fetchText(from: url)
        guard text.contains("#EXTM3U") else { throw DownloadError.notPlaylist }
        let variants = parseVariants(text, base: url)
        guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
            return url
        }
        return best.url
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
    /// AES-128 加密的播单直接 throw（下不了，明说，不硬拼）。
    private func parsePlaylist(_ url: URL) async throws -> (segments: [URL], initURL: URL?) {
        let text = try await fetchText(from: url)
        guard text.contains("#EXTM3U") else { throw DownloadError.notPlaylist }
        if text.contains("#EXT-X-KEY") && text.contains("METHOD=AES-128") {
            throw DownloadError.encrypted
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
            let tempURL = try await downloadFileWithResume(from: url, taskId: id)
            try? fileManager.removeItem(at: destURL)
            try fileManager.moveItem(at: tempURL, to: destURL)
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
        }
    }

    private func downloadFileWithResume(from url: URL, taskId: UUID) async throws -> URL {
        var resumeData: Data?
        var lastError: Error?
        for _ in 0..<2 { // 最多下两次：第一次 + 一次 resume 重试
            do {
                return try await downloadOnce(from: url, resumeData: resumeData, taskId: taskId)
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

    /// 一次 downloadTask。进度用 Timer 每 0.3 秒读 task.progress 轮询
    /// （downloadTask 的 completionHandler 不带进度回调）。
    private func downloadOnce(from url: URL, resumeData: Data?, taskId: UUID) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var timer: Timer? = nil
            let finish: (URL?, URLResponse?, Error?) -> Void = { location, response, error in
                if let timer {
                    DispatchQueue.main.async { timer.invalidate() }
                }
                Self.finishDownload(location: location, response: response, error: error, continuation: continuation)
            }
            let task: URLSessionDownloadTask
            if let resumeData {
                task = URLSession.shared.downloadTask(withResumeData: resumeData, completionHandler: finish)
            } else {
                task = URLSession.shared.downloadTask(with: url, completionHandler: finish)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                let fraction = task.progress.fractionCompleted
                Task { @MainActor in
                    self?.updateTask(id: taskId) { $0.progress = fraction }
                }
            }
            task.resume()
        }
    }

    private static func finishDownload(location: URL?, response: URLResponse?, error: Error?, continuation: CheckedContinuation<URL, Error>) {
        if let error {
            // 失败时 URLSession 会在 userInfo 里给 resumeData（能续传时）
            if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                continuation.resume(throwing: ResumeFailure(resumeData: resumeData, underlying: error))
            } else {
                continuation.resume(throwing: DownloadError.network(error.localizedDescription))
            }
            return
        }
        // downloadTask 的 HTTP 错误不走 error，得自己看 statusCode
        //（404 也会“成功”返回一个装着错误页的临时文件）。
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation.resume(throwing: DownloadError.httpStatus(http.statusCode))
            return
        }
        guard let location else {
            continuation.resume(throwing: DownloadError.network("下载完成但没拿到文件"))
            return
        }
        continuation.resume(returning: location)
    }

    // MARK: - 小工具

    private func fetchText(from url: URL) async throws -> String {
        let data = try await fetchData(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.badResponse
        }
        return text
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DownloadError.httpStatus(http.statusCode)
            }
            return data
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

    /// delete 是 removeTask 的别名（界面层 MyView 调 downloader.delete(task)）。
    func delete(_ task: DownloadTask) {
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
    case badResponse
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notPlaylist: return "这个链接不是 m3u8 播单，下不了"
        case .emptyPlaylist: return "播单里没有分片，下不了"
        case .encrypted: return "这个视频加密了（AES-128），暂不支持下载"
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
