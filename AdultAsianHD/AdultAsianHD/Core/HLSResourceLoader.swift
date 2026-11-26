import AVFoundation
import Foundation

/// HLS 资源加载拦截器（Fix A3）：AVAssetResourceLoaderDelegate。
///
/// 关键修正（Claude + ChatGPT 两轮证据）：AVPlayer 只把 playlist（m3u8）和 key
/// 的请求交给 AVAssetResourceLoaderDelegate，.ts 分片请求不经过 delegate、
/// 直接由 AVPlayer 发起。所以本拦截器只负责 playlist + key，不要写成能拦分片的样子：
/// 播单改写时 key URI 改 scheme（走拦截器），分片/init 行一律改成绝对 https
/// （AVPlayer 直接拉）；分片也需要头时拦截器覆盖不了，会报 -12881，
/// 由上层检测到后回退 hls.js，再往后是回环代理（LoopbackProxyServer，
/// 梯子 D → P → J 里的一级，见 Playback.markFailed）。
/// 探针已证实三站的分片不要头（黄果 .ts 无头也 206），所以黄果仍可用拦截器。
///
/// 拦截器不“解密”：只负责把 key 字节喂给 AVPlayer（重写 EXT-X-KEY URI、
/// 用 URLSession 取回密钥字节），解密是 AVPlayer 自己做的。
/// 密钥缓存按 key URI 计：同一 URI 只拉一次；密钥轮换即换新 URI，旧缓存自然失效。
/// AVContentKeySession 只针对 FairPlay，不适用于普通 AES-128；
/// 遇到 skd://（FairPlay）直接明确报错，不要硬上。SAMPLE-AES 与 FairPlay 不走同一路径。
///
/// 把要播的 m3u8 URL 的 scheme 换成 hlsloader://（http 则换成 hlsloader-http://）
/// 建 AVURLAsset，delegate 里换回 https/http，用 URLSession 代发播单/密钥，
/// 带 iPhone UA + Referer + Cookie + 模块自定义头。
/// - 302 跨域重定向：代发请求走 DiagnosticHTTPClient，它的 PerRequestDelegate
///   在重定向请求上把自定义头补回去（同源才保留凭据头）。
/// - 相对路径 key URI：按播单所在 URL 解析成绝对路径并改 scheme；相对路径分片 URI：
///   同样解析成绝对路径，但保持 https（见上）。
/// - 密钥 403/401：先重拉一次播单（签名可能已刷新），用刷新后播单里的新 key URI
///   再拉一次密钥；仍失败再调 onKeyAuthFailed 触发一次 loadResource 重铸，
///   重铸也失败才由上层报失败切线，不循环。
/// - 预检（PlaybackPreflight）：拦截器第一次拉 playlist 的结果本身就是预检
///   （直接用、不丢弃；一次性 URL 不做额外 GET，额外 GET 会消费一次性 token），
///   见 preflightPlaylistStatusCode / preflightPlaylistIsM3U8；
///   另用 errorLog/accessLog 被动诊断（CustomPlayerController 的采样）。
/// - DEBUG 下只记密钥 URL 的 host、状态码、字节数，不记完整签名值。
final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let loaderScheme = "hlsloader"
    static let loaderSchemeHTTP = "hlsloader-http"

    /// https/http → 自定义 scheme（建 AVURLAsset 用）。
    static func loaderURL(for url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if comps?.scheme == "https" {
            comps?.scheme = loaderScheme
        } else if comps?.scheme == "http" {
            comps?.scheme = loaderSchemeHTTP
        }
        return comps?.url ?? url
    }

    /// 自定义 scheme → 原 https/http（代发请求用）。
    static func originalURL(for url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if comps?.scheme == loaderScheme {
            comps?.scheme = "https"
        } else if comps?.scheme == loaderSchemeHTTP {
            comps?.scheme = "http"
        }
        return comps?.url ?? url
    }

    /// 密钥 403/401 且播单重拉+重铸都失败后，上层触发一次 loadResource 重铸；
    /// 返回 true 表示已开始重铸（本请求按失败收尾，等新线路接手），false 表示无重铸可用。
    var onKeyAuthFailed: (@Sendable () async -> Bool)?

    /// 播单里见到了 skd://（FairPlay）：拦截器处理不了，上层据此报明确错误。
    private(set) var encounteredFairPlay = false

    /// delegate 回调跑的队列（AVAssetResourceLoader.setDelegate 用）。
    let delegateQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.hlsloader", qos: .userInitiated)

    private let allHeaders: [String: String]

    private let stateLock = NSLock()
    private var keyCache: [String: Data] = [:]
    private var knownKeyURLs: Set<String> = []
    private var playlistURL: URL?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// 本次拦截器实际代发的请求账本（播单/密钥/分片）：(URL, 上游状态码, 种类)。
    /// 终局时由 ViewModel 取快照、合并进账本（期望 vs 实际对账用）。
    /// 只记 URL 与状态码；账本只存 host + 路径模板哈希，不记 token/Cookie（见 PlaybackLedger）。
    private var requestBook: [(url: String, statusCode: Int?, kind: String)] = []

    /// 本次实际代发的请求快照（线程安全）。终局时由 ViewModel 取。
    func requestBookSnapshot() -> [(url: String, statusCode: Int?, kind: String)] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestBook
    }

    /// 播单里见过的密钥 URL 快照（线程安全）：期望账本用——
    /// 这些 URL 是宿主改写过、指望 AVPlayer 经拦截器取的；errorLog 若指向其中之一，
    /// 即 AVPlayer 直接取了原始 https 地址（被绕过）。
    func knownKeyURLStrings() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(knownKeyURLs)
    }

    private func appendRequestBook(url: URL, statusCode: Int?) {
        let kind: String
        if isKeyURL(url) {
            kind = "key"
        } else if url.pathExtension.lowercased() == "m3u8" {
            kind = "playlist"
        } else {
            kind = "segment"
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        requestBook.append((url: url.absoluteString, statusCode: statusCode, kind: kind))
    }

    /// 预检结果：拦截器第一次拉 playlist 的结果本身就是预检（直接用、不丢弃；
    /// 一次性 URL 不做额外 GET，额外 GET 会消费一次性 token）。
    /// 首次播单请求的 HTTP 状态码；nil = 还没拉过播单。
    private(set) var preflightPlaylistStatusCode: Int?
    /// 首次播单响应体是不是 M3U8。
    private(set) var preflightPlaylistIsM3U8: Bool?
    /// 最近一次失败的分层与状态码（供 markFailed 组分层错误上报，Fix C 的自检复用）。
    private(set) var lastFailureStage: PlaybackFailureStage?
    private(set) var lastFailureStatusCode: Int?
    /// 播单里见过的 #EXT-X-TARGETDURATION（秒）：seek 容差/看门狗预算的
    /// 分片时长来源 1（最准）。rewritePlaylist 逐行改写时顺带记录；
    /// 变体播单与媒体播单都可能带它，取最后一次见到的值。
    private(set) var targetDurationSeconds: Double?

    /// headers：已合并好的子请求头（iPhone UA + Referer + 模块自定义头 + Cookie）。
    init(headers: [String: String], cookie: String?) {
        var overrides = headers
        if let cookie, !cookie.isEmpty {
            overrides["Cookie"] = cookie
        }
        let merged = NetConstants.mergeHeaders(
            base: NetConstants.defaultBrowserHeaders,
            overrides: overrides
        )
        self.allHeaders = merged
        super.init()
    }

    deinit {
        // 代发请求走 DiagnosticHTTPClient（自带会话），本类不再持有 URLSession；
        // 释放时只取消还在途的 loadingRequest 任务。
        stateLock.lock()
        let pending = Array(tasks.values)
        stateLock.unlock()
        for task in pending { task.cancel() }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url else { return false }
        // skd://（FairPlay）：拦截器处理不了，直接明确报错，不硬上。
        if requestURL.scheme == "skd" || requestURL.scheme == "skds" {
            setFairPlayFlag()
            loadingRequest.finishLoading(with: Self.fairPlayError())
            return true
        }
        let original = Self.originalURL(for: requestURL)
        guard original.scheme == "http" || original.scheme == "https" else { return false }
        let task = Task { [weak self] in
            await self?.handle(loadingRequest: loadingRequest, originalURL: original)
            self?.removeTask(for: loadingRequest)
        }
        storeTask(task, for: loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        task(for: loadingRequest)?.cancel()
        removeTask(for: loadingRequest)
    }

    // MARK: - 子请求处理

    private func handle(loadingRequest: AVAssetResourceLoadingRequest, originalURL: URL) async {
        if Task.isCancelled { return }
        let isKey = isKeyURL(originalURL)
        let isPlaylistURL = originalURL.pathExtension.lowercased() == "m3u8"
        // 密钥缓存：同一 key URI 只拉一次（轮换即换新 URI，旧缓存自然失效）。
        if isKey, let cached = cachedKey(originalURL) {
            finish(loadingRequest, data: cached, contentType: "public.data", byteRangeAccessSupported: false, totalLength: cached.count)
            return
        }
        let range = requestedRange(from: loadingRequest.dataRequest)
        do {
            let (data, response) = try await fetch(url: originalURL, range: range)
            guard let http = response as? HTTPURLResponse else {
                recordFailure(stage: isKey ? .keyFetch : (isPlaylistURL ? .playlistFetch : .segmentFetch), statusCode: nil)
                loadingRequest.finishLoading(with: Self.httpError(status: -1))
                return
            }
            if Task.isCancelled { return }
            // 密钥 403/401：不直接判死刑。先重拉一次播单（签名可能已刷新），
            // 用新 key URI 再拉一次；仍失败再触发一次重铸，才报失败切线。
            if isKey, (http.statusCode == 401 || http.statusCode == 403) {
                if let keyData = await retryKeyAfterPlaylistRefresh(failedKeyURL: originalURL) {
                    finish(loadingRequest, data: keyData, contentType: "public.data", byteRangeAccessSupported: false, totalLength: keyData.count)
                    return
                }
                recordFailure(stage: .keyFetch, statusCode: http.statusCode)
                _ = await onKeyAuthFailed?()
                loadingRequest.finishLoading(with: Self.keyAuthError(status: http.statusCode))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                // 分层记录：播单非 2xx / 密钥非 2xx / 分片非 2xx 各记各的层。
                recordFailure(stage: isKey ? .keyFetch : (isPlaylistURL ? .playlistFetch : .segmentFetch), statusCode: http.statusCode)
                loadingRequest.finishLoading(with: Self.httpError(status: http.statusCode))
                return
            }
            // 预检：第一次拉 playlist 的结果本身就是预检（直接用、不丢弃）。
            if isPlaylistURL {
                recordPreflight(statusCode: http.statusCode, isM3U8: isPlaylist(data: data, url: originalURL, response: http))
            }
            // 播单：改写 key URI（改 scheme，走拦截器）与分片 URI（改绝对 https，
            // AVPlayer 直接拉），交给 AVPlayer。
            // 相对 URI 按最终重定向落点解析（http.url），不是原始 originalURL——
            // 重定向后的播单若按旧基址解析，相对 URI 会指向错误的 host/路径，100% 404。
            if isPlaylist(data: data, url: originalURL, response: http) {
                let text = String(decoding: data, as: UTF8.self)
                let finalURL = http.url ?? originalURL
                setPlaylistURL(finalURL)
                let rewritten = rewritePlaylist(text, baseURL: finalURL)
                let out = Data(rewritten.utf8)
                finish(loadingRequest, data: out, contentType: nil, byteRangeAccessSupported: false, totalLength: out.count)
                return
            }
            // .m3u8 地址拉回来的却不是 M3U8 体（挑战页/报错页）：预检失败，
            // 分层记播单层，不要把挑战页当播单喂给 AVPlayer。
            if isPlaylistURL {
                recordFailure(stage: .playlistFetch, statusCode: http.statusCode)
                loadingRequest.finishLoading(with: Self.httpError(status: http.statusCode, detail: "播单拉取失败：响应不是 M3U8"))
                return
            }
            // 密钥/单文件：按 Range 切片回填。
            // 分片正常不经过 delegate（AVPlayer 直接拉）；这里只作兜底——万一某路
            // 分片走了自定义 scheme 进来，照样按 Range 回填，不当场拒掉。
            let (outData, total) = sliceForRange(data: data, response: http, range: range)
            if isKey {
                logKey(host: originalURL.host, status: http.statusCode, bytes: outData.count)
                cacheKey(originalURL, data: outData)
                finish(loadingRequest, data: outData, contentType: "public.data", byteRangeAccessSupported: false, totalLength: outData.count)
            } else {
                finish(
                    loadingRequest,
                    data: outData,
                    contentType: contentType(for: originalURL),
                    byteRangeAccessSupported: supportsRange(response: http),
                    totalLength: total
                )
            }
        } catch {
            if Task.isCancelled { return }
            // 传输层就失败了（无响应）：记一条状态 nil 的实际账本，终局时分层记 .segmentFetch/.keyFetch。
            appendRequestBook(url: originalURL, statusCode: nil)
            recordFailure(stage: isKey ? .keyFetch : (isPlaylistURL ? .playlistFetch : .segmentFetch), statusCode: nil)
            loadingRequest.finishLoading(with: error)
        }
    }

    // MARK: - 代发请求（带头；走 DiagnosticHTTPClient，重定向由它补头）

    private struct RequestedRange {
        let offset: Int
        /// nil = 拉到文件尾。
        let length: Int?
    }

    private func requestedRange(from dataRequest: AVAssetResourceLoadingDataRequest?) -> RequestedRange? {
        guard let dataRequest else { return nil }
        let offset = Int(dataRequest.requestedOffset)
        if dataRequest.requestsAllDataToEndOfResource {
            return offset > 0 ? RequestedRange(offset: offset, length: nil) : nil
        }
        let length = Int(dataRequest.requestedLength)
        guard length > 0 else { return nil }
        return RequestedRange(offset: offset, length: length)
    }

    private func fetch(url: URL, range: RequestedRange?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.assumesHTTP3Capable = false
        request.timeoutInterval = 12
        for (key, value) in allHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            if let length = range.length {
                request.setValue("bytes=\(range.offset)-\(range.offset + length - 1)", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(range.offset)-", forHTTPHeaderField: "Range")
            }
        }
        let result = try await DiagnosticHTTPClient.shared.data(
            for: request,
            source: "hlsloader",
            preservedHeaders: allHeaders,
            timeout: 12
        )
        // 记实际账本：每一次代发请求都记（成功/非 2xx 都记；抛错的由 handle 的 catch 记 nil）。
        appendRequestBook(url: url, statusCode: (result.1 as? HTTPURLResponse)?.statusCode)
        return result
    }

    /// 密钥 403/401 后的挽救：重拉一次播单，用刷新后播单里的新 key URI 再拉一次密钥。
    /// 注意基址：播单那次 fetch 可能经过重定向，相对 key URI 必须按重定向后的
    /// 最终 URL（http.url）解析，按旧基址解析会指向错误 host/路径、100% 404。
    private func retryKeyAfterPlaylistRefresh(failedKeyURL: URL) async -> Data? {
        guard let playlist = currentPlaylistURL() else { return nil }
        guard let (data, response) = try? await fetch(url: playlist, range: nil),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        let finalPlaylistURL = http.url ?? playlist
        let text = String(decoding: data, as: UTF8.self)
        let keyURI = extractKeyURI(from: text, baseURL: finalPlaylistURL) ?? failedKeyURL.absoluteString
        guard let keyURL = URL(string: keyURI) else { return nil }
        guard let (keyData, keyResponse) = try? await fetch(url: keyURL, range: nil),
              let keyHTTP = keyResponse as? HTTPURLResponse,
              (200...299).contains(keyHTTP.statusCode) else { return nil }
        cacheKey(keyURL, data: keyData)
        return keyData
    }

    // MARK: - 播单改写

    /// 播单判定（后缀 + 正文双重判定）：后缀 .m3u8 或 MIME 含 mpegurl 只是候选，
    /// 正文首行必须是 #EXTM3U（去 UTF-8 BOM 与前导空白）才算播单——
    /// CF 挑战页挂在 .m3u8 地址上时，按旧逻辑会被当成播单喂给 AVPlayer。
    private func isPlaylist(data: Data, url: URL, response: HTTPURLResponse) -> Bool {
        let hasPlaylistMarker = url.pathExtension.lowercased() == "m3u8"
            || (response.mimeType?.lowercased().contains("mpegurl") ?? false)
        guard hasPlaylistMarker else { return false }
        var text = String(decoding: data.prefix(64), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    /// 播单逐行改写：key URI 解析成绝对路径并改 scheme（走拦截器）；
    /// 变体播单行同样改 scheme（仍是播单，走拦截器）；
    /// MAP/init 与分片行只解析成绝对 https（AVPlayer 直接拉，不经过 delegate，
    /// 改了 scheme 只会 404 或报 -12881）。
    /// 相对路径必须重写为绝对路径，否则改 scheme 后 404 或 -12881（key 和分片都一样）。
    /// TODO(备选)：key 可内联成 data: URI（多 key 轮换时需内联多个），本轮不实现。
    private func rewritePlaylist(_ text: String, baseURL: URL) -> String {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            // 分片时长：seek 容差/看门狗预算用（见 CustomPlayerView.seekSegmentDurationSeconds）。
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let value = line.dropFirst("#EXT-X-TARGETDURATION:".count)
                    .trimmingCharacters(in: .whitespaces)
                if let seconds = Double(value), seconds > 0 {
                    targetDurationSeconds = seconds
                }
            }
            if line.hasPrefix("#EXT-X-KEY"), let uri = extractURIValue(from: line) {
                let absolute = absoluteURL(uri, base: baseURL)
                if absolute.scheme == "skd" || absolute.scheme == "skds" {
                    setFairPlayFlag()
                    out.append(line)
                } else {
                    markKeyURL(absolute)
                    out.append(line.replacingOccurrences(of: uri, with: Self.loaderURL(for: absolute).absoluteString))
                }
            } else if line.hasPrefix("#EXT-X-MAP:"), let uri = extractURIValue(from: line) {
                // init 分片：AVPlayer 直接拉，只改绝对 https，不改 scheme。
                let absolute = absoluteURL(uri, base: baseURL)
                out.append(line.replacingOccurrences(of: uri, with: absolute.absoluteString))
            } else if !line.hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let absolute = absoluteURL(trimmed, base: baseURL)
                if absolute.pathExtension.lowercased() == "m3u8" || trimmed.lowercased().contains(".m3u8") {
                    // 变体播单行：仍是播单，走拦截器（改 scheme）。
                    out.append(Self.loaderURL(for: absolute).absoluteString)
                } else {
                    // 分片行：AVPlayer 直接拉，只改绝对 https，不改 scheme。
                    // 分片需头时拦截器覆盖不了（-12881），由上层回退 hls.js。
                    out.append(absolute.absoluteString)
                }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// URI="..."（有引号优先，无引号兜底）。
    private func extractURIValue(from line: String) -> String? {
        if let start = line.range(of: "URI=\"") {
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let range = line.range(of: "URI=") else { return nil }
        let rest = line[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == "," || $0 == " " }) ?? rest.endIndex
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// 播单里第一条 #EXT-X-KEY 的 URI（绝对路径字符串；重拉播单后找新签名用）。
    private func extractKeyURI(from text: String, baseURL: URL) -> String? {
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-KEY") {
            guard let uri = extractURIValue(from: line) else { continue }
            return absoluteURL(uri, base: baseURL).absoluteString
        }
        return nil
    }

    /// 相对路径按播单所在 URL 解析成绝对路径；已是绝对路径原样返回。
    private func absoluteURL(_ raw: String, base: URL) -> URL {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL ?? base
    }

    // MARK: - 回填

    private func finish(_ loadingRequest: AVAssetResourceLoadingRequest, data: Data, contentType: String?, byteRangeAccessSupported: Bool, totalLength: Int?) {
        if let info = loadingRequest.contentInformationRequest {
            if let contentType {
                info.contentType = contentType
            }
            if let totalLength {
                info.contentLength = Int64(totalLength)
            }
            info.isByteRangeAccessSupported = byteRangeAccessSupported
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    /// 206：服务端已按 Range 切好，total 从 Content-Range 取；
    /// 200：服务端没理 Range，自己按请求的 Range 切一片出来。
    private func sliceForRange(data: Data, response: HTTPURLResponse, range: RequestedRange?) -> (Data, Int?) {
        guard let range else { return (data, data.count) }
        if response.statusCode == 206 {
            let total = totalLength(from: response) ?? (range.offset + data.count)
            return (data, total)
        }
        let start = min(range.offset, data.count)
        let end: Int
        if let length = range.length {
            end = min(start + length, data.count)
        } else {
            end = data.count
        }
        return (data.subdata(in: start..<end), data.count)
    }

    private func totalLength(from response: HTTPURLResponse) -> Int? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        // "bytes 0-99/1000" → 1000
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int(String(contentRange[contentRange.index(after: slash)...]))
    }

    private func supportsRange(response: HTTPURLResponse) -> Bool {
        if response.statusCode == 206 { return true }
        return response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
    }

    /// contentType 要填 UTI（不是 MIME）：按扩展名映射，认不出的留 nil 让 AVFoundation 嗅探。
    private func contentType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4s", "m4v":
            return "public.mpeg-4"
        case "ts":
            return "public.mpeg-2-transport-stream"
        case "key":
            return "public.data"
        default:
            return nil
        }
    }

    // MARK: - 密钥判定与缓存

    private func isKeyURL(_ url: URL) -> Bool {
        if snapshotKnownKeyURLs().contains(url.absoluteString) { return true }
        if url.pathExtension.lowercased() == "key" { return true }
        return url.absoluteString.lowercased().contains("crypt.key")
    }

    private func cachedKey(_ url: URL) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return keyCache[url.absoluteString]
    }

    private func cacheKey(_ url: URL, data: Data) {
        stateLock.lock()
        defer { stateLock.unlock() }
        keyCache[url.absoluteString] = data
    }

    private func snapshotKnownKeyURLs() -> Set<String> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return knownKeyURLs
    }

    private func markKeyURL(_ url: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        knownKeyURLs.insert(url.absoluteString)
    }

    private func currentPlaylistURL() -> URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return playlistURL
    }

    private func setPlaylistURL(_ url: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        playlistURL = url
    }

    private func setFairPlayFlag() {
        stateLock.lock()
        defer { stateLock.unlock() }
        encounteredFairPlay = true
    }

    /// 分层失败记录（供 markFailed 组分层错误上报，Fix C 的自检复用）。
    private func recordFailure(stage: PlaybackFailureStage, statusCode: Int?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        lastFailureStage = stage
        lastFailureStatusCode = statusCode
    }

    /// 预检记录：只记第一次拉 playlist 的结果（直接用、不丢弃）。
    private func recordPreflight(statusCode: Int, isM3U8: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if preflightPlaylistStatusCode == nil {
            preflightPlaylistStatusCode = statusCode
            preflightPlaylistIsM3U8 = isM3U8
        }
    }

    // MARK: - 任务管理

    private func storeTask(_ task: Task<Void, Never>, for loadingRequest: AVAssetResourceLoadingRequest) {
        stateLock.lock()
        defer { stateLock.unlock() }
        tasks[ObjectIdentifier(loadingRequest)] = task
    }

    private func task(for loadingRequest: AVAssetResourceLoadingRequest) -> Task<Void, Never>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tasks[ObjectIdentifier(loadingRequest)]
    }

    private func removeTask(for loadingRequest: AVAssetResourceLoadingRequest) {
        stateLock.lock()
        defer { stateLock.unlock() }
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
    }

    // MARK: - 日志与错误

    /// DEBUG 只记密钥 host、状态码、字节数，不记完整签名值。
    private func logKey(host: String?, status: Int, bytes: Int) {
#if DEBUG
        print("[HLSResourceLoader] key host=\(host ?? "-") status=\(status) bytes=\(bytes)")
#endif
    }

    private static func httpError(status: Int, detail: String? = nil) -> NSError {
        let message = detail ?? "播放资源请求失败（HTTP \(status)）"
        return NSError(domain: "HLSResourceLoader", code: status, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func keyAuthError(status: Int) -> NSError {
        NSError(domain: "HLSResourceLoader", code: status, userInfo: [NSLocalizedDescriptionKey: "密钥请求被拒（HTTP \(status)），签名可能已过期"])
    }

    private static func fairPlayError() -> NSError {
        NSError(domain: "HLSResourceLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "这条线路用了 FairPlay 加密（skd://），当前播放器不支持"])
    }
}
