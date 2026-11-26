import Foundation
import Network
import Security

/// 无节点 DNS 污染兜底客户端（如 huangguoai.com 系统 DNS 污染到 66.220.147.11）：
/// 1) 阿里 DoH（223.5.5.5 / 223.6.6.6，直连 IP 字面量 + SNI=dns.alidns.com，
///    证书按 dns.alidns.com 校验，不走 URLSession）解析真实 A 记录并按 TTL 缓存；
/// 2) NWConnection 直连解析出的 IP，显式设置 TLS SNI = 原域名 + SecPolicyCreateSSL 真验证证书；
/// 3) 发送 HTTP/1.1（Host: 原域名, Accept-Encoding: identity, Connection: close），支持 chunked 解码与 3xx 跟随；
/// 4) 一旦某 host 走 DoH 成功即记入偏好表（切网自动清空），后续请求 0 等待直连 DoH IP。
final class DoHFallbackClient: @unchecked Sendable {
    static let shared = DoHFallbackClient()

    private struct CachedIPs {
        let ips: [String]
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var ipCache: [String: CachedIPs] = [:]
    private var preferredHosts: Set<String> = []

    private init() {}

    func resetForNetworkChange() {
        lock.lock()
        ipCache.removeAll()
        preferredHosts.removeAll()
        lock.unlock()
    }

    func isDoHPreferred(for host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return preferredHosts.contains(host)
    }

    func markDoHPreferred(host: String) {
        lock.lock()
        preferredHosts.insert(host.lowercased())
        lock.unlock()
    }

    /// 走阿里 DoH 解析并直连 IP 发 HTTPS 请求（最多跟随 5 次重定向）。
    func perform(
        request rawRequest: URLRequest,
        preservedHeaders: [String: String],
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse, remoteIP: String) {
        var currentReq = rawRequest
        let originURL = rawRequest.url
        for _ in 0..<6 {
            guard let url = currentReq.url,
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else {
                throw URLError(.badURL)
            }
            let ips = await resolveIPs(host: host)
            guard !ips.isEmpty else { throw URLError(.cannotFindHost) }

            var lastError: Error = URLError(.cannotConnectToHost)
            var succeeded: (Data, HTTPURLResponse, String)?
            for ip in ips.prefix(4) {
                if Task.isCancelled { throw CancellationError() }
                do {
                    let perIPTimeout = min(max(timeout / 2, 4), 10)
                    let res = try await fetchSingleHop(
                        url: url,
                        host: host,
                        ip: ip,
                        request: currentReq,
                        timeout: perIPTimeout
                    )
                    succeeded = (res.0, res.1, ip)
                    markDoHPreferred(host: host)
                    break
                } catch {
                    lastError = error
                    continue
                }
            }
            guard let (data, http, ip) = succeeded else { throw lastError }

            // 处理 301/302/303/307/308 重定向
            if [301, 302, 303, 307, 308].contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location"),
               let nextURL = URL(string: location, relativeTo: url)?.absoluteURL {
                // 只有 303 强制转 GET；301/302 保持原方法（RFC 7231：301/302 的
                // 方法保留是允许的，POST 301/302 转 GET 是历史遗留行为，
                // 对签名 POST（如黄果现铸）转 GET 会丢 body 导致失败）。
                var nextReq = URLRequest(url: nextURL)
                nextReq.httpMethod = (http.statusCode == 303) ? "GET" : (currentReq.httpMethod ?? "GET")
                if nextReq.httpMethod != "GET" { nextReq.httpBody = currentReq.httpBody }
                let sameOrigin = NetConstants.isSameOrigin(originURL, nextURL)
                for (k, v) in preservedHeaders {
                    let lower = k.lowercased()
                    if !sameOrigin && NetConstants.isSensitiveHeader(k) { continue }
                    if lower == "host" || lower == "content-length" { continue }
                    nextReq.setValue(v, forHTTPHeaderField: k)
                }
                currentReq = nextReq
                continue
            }
            return (data, http, ip)
        }
        throw URLError(.httpTooManyRedirects)
    }

    // MARK: - 阿里 DoH 解析（223.5.5.5 优先，223.6.6.6 兜底）

    func resolveIPs(host: String) async -> [String] {
        let key = host.lowercased()
        lock.lock()
        if let cached = ipCache[key], cached.expiresAt > Date() {
            lock.unlock()
            return cached.ips
        }
        lock.unlock()

        for ip in ["223.5.5.5", "223.6.6.6"] {
            if let (ips, ttl) = await queryAliDoH(ip: ip, host: host), !ips.isEmpty {
                let clampedTTL = TimeInterval(min(max(ttl, 5), 300))
                lock.lock()
                ipCache[key] = CachedIPs(ips: ips, expiresAt: Date().addingTimeInterval(clampedTTL))
                lock.unlock()
                return ips
            }
        }
        return []
    }

    /// 阿里 DoH 查询：不用 URLSession——直连 DoH 服务商的 IP 字面量
    ///（223.5.5.5:443 / 223.6.6.6:443），SNI=dns.alidns.com，
    /// 证书按 dns.alidns.com 校验（URLSession 对 IP 字面量 URL 的证书校验
    /// 不可控；DoH 查询本身走系统 DNS 解析的话也会被污染）。
    private func queryAliDoH(ip: String, host: String) async -> ([String], Int)? {
        guard var comps = URLComponents(string: "https://dns.alidns.com/resolve") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, http) = try? await fetchSingleHop(url: url, host: "dns.alidns.com", ip: ip, request: req, timeout: 4),
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["Answer"] as? [[String: Any]] else {
            return nil
        }
        var ips: [String] = []
        var minTTL = 180
        for a in answers where (a["type"] as? Int) == 1 {
            if let ip = a["data"] as? String, !ip.isEmpty, !ips.contains(ip) {
                ips.append(ip)
            }
            if let ttl = a["TTL"] as? Int, ttl > 0 {
                minTTL = min(minTTL, ttl)
            }
        }
        return ips.isEmpty ? nil : (ips, minTTL)
    }

    // MARK: - NWConnection + TLS SNI + 真证书校验 + HTTP/1.1

    private func fetchSingleHop(
        url: URL,
        host: String,
        ip: String,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let portNum = UInt16(url.port ?? 443)
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            throw URLError(.badURL)
        }
        let wireData = buildHTTP11Request(url: url, host: host, request: request)
        let queue = DispatchQueue(label: "com.liudehen.xiaoshipin.doh.conn.\(UUID().uuidString)")

        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tlsOpts.securityProtocolOptions, "http/1.1")
        // 按目标真实域名校验证书（而非 IP 字面量）
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, policy)
            let ok = SecTrustEvaluateWithError(trust, nil)
            complete(ok)
        }, queue)

        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)

        final class ConnBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<Data, Error>?
            private var done = false
            var connection: NWConnection?
            var buffer = Data()

            func set(_ c: CheckedContinuation<Data, Error>) {
                lock.lock(); defer { lock.unlock() }
                cont = c
            }
            func finish(_ result: Result<Data, Error>) {
                lock.lock()
                guard !done else { lock.unlock(); return }
                done = true
                let c = cont; cont = nil
                let cn = connection; connection = nil
                lock.unlock()
                cn?.cancel()
                switch result {
                case .success(let d): c?.resume(returning: d)
                case .failure(let e): c?.resume(throwing: e)
                }
            }
        }

        let box = ConnBox()
        box.connection = conn

        let rawResponse: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.set(cont)
                if Task.isCancelled {
                    box.finish(.failure(CancellationError()))
                    return
                }
                func receiveLoop() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            box.buffer.append(data)
                        }
                        if isComplete {
                            box.finish(.success(box.buffer))
                            return
                        }
                        if let error {
                            if !box.buffer.isEmpty {
                                box.finish(.success(box.buffer))
                            } else {
                                box.finish(.failure(error))
                            }
                            return
                        }
                        receiveLoop()
                    }
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: wireData, completion: .contentProcessed { sendErr in
                            if let sendErr {
                                box.finish(.failure(sendErr))
                                return
                            }
                            receiveLoop()
                        })
                    case .failed(let err):
                        box.finish(.failure(err))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    // 先 cancel 再 finish：不然连接还挂着继续收，超时后
                    // 迟到的数据还会进 buffer（ConnBox.finish 已断开连接，
                    // 这里显式 cancel 是双保险，防底层 socket 泄漏）。
                    conn.cancel()
                    box.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }

        return try parseHTTP11Response(rawResponse, url: url)
    }

    private func buildHTTP11Request(url: URL, host: String, request: URLRequest) -> Data {
        let method = request.httpMethod ?? "GET"
        var pathAndQuery = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { pathAndQuery += "?\(q)" }
        let hostHeader = url.port.map { "\($0 == 443 ? host : "\(host):\($0)")" } ?? host

        var lines: [String] = [
            "\(method) \(pathAndQuery) HTTP/1.1",
            "Host: \(hostHeader)",
            "Connection: close",
            "Accept-Encoding: identity"
        ]
        var seen = Set(["host", "connection", "accept-encoding", "content-length", "transfer-encoding"])
        if let fields = request.allHTTPHeaderFields {
            for (k, v) in fields {
                let lower = k.lowercased()
                guard !seen.contains(lower) else { continue }
                seen.insert(lower)
                lines.append("\(k): \(v)")
            }
        }
        let body = request.httpBody
        // 请求自带 Transfer-Encoding（分块）时不补 Content-Length：两个头
        // 同时出现时服务端行为未定义，常见是 400。
        if let body, request.value(forHTTPHeaderField: "Transfer-Encoding") == nil {
            lines.append("Content-Length: \(body.count)")
        }
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { out.append(body) }
        return out
    }

    private func parseHTTP11Response(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let sep = Data("\r\n\r\n".utf8)
        // 1xx 中间响应（100 Continue / 103 Early Hints）会先发一组头：
        // 循环跳过它们，只解析最后一组（真正的最终响应）头。
        var searchFrom = raw.startIndex
        var range: Range<Data.Index>?
        var statusCode = 0
        while let found = raw.range(of: sep, in: searchFrom..<raw.endIndex) {
            guard let headStr = String(data: raw[searchFrom..<found.lowerBound], encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            let firstLine = headStr.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else {
                throw URLError(.cannotParseResponse)
            }
            if (100...199).contains(code) {
                searchFrom = found.upperBound
                continue
            }
            range = found
            statusCode = code
            break
        }
        guard let range,
              let headStr = String(data: raw[searchFrom..<range.lowerBound], encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        let headerLines = headStr.components(separatedBy: "\r\n")
        guard headerLines.first != nil else { throw URLError(.cannotParseResponse) }
        var headerFields: [String: String] = [:]
        var isChunked = false
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k.lowercased() == "transfer-encoding" && v.lowercased().contains("chunked") {
                isChunked = true
            }
            headerFields[k] = v
        }
        let rawBody = Data(raw[range.upperBound...])
        let body = isChunked ? try decodeChunked(rawBody) : rawBody
        guard let httpResp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headerFields) else {
            throw URLError(.cannotParseResponse)
        }
        return (body, httpResp)
    }

    /// chunked 解码：任何截断（缺尺寸行、尺寸不是十六进制、块体不够长、
    /// 块后缺 CRLF）都 throw，不再悄悄返回半截数据（半截 m3u8/JSON
    /// 下游解析会出怪错，不如直接报解析失败走重试/换线）。
    private func decodeChunked(_ data: Data) throws -> Data {
        var out = Data()
        var idx = data.startIndex
        let crlf = Data("\r\n".utf8)
        while idx < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: idx..<data.endIndex) else {
                throw URLError(.cannotParseResponse)
            }
            let sizeStr = String(decoding: data[idx..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeStr, radix: 16) else {
                throw URLError(.cannotParseResponse)
            }
            if size == 0 {
                // 终结块：后面只有 trailer + CRLF，直接收尾。
                break
            }
            let bodyStart = lineEnd.upperBound
            guard let bodyEnd = data.index(bodyStart, offsetBy: size, limitedBy: data.endIndex) else {
                throw URLError(.cannotParseResponse)
            }
            out.append(data[bodyStart..<bodyEnd])
            // 块体后必须跟 CRLF；不够长或不是 CRLF 就是截断。
            guard let afterChunk = data.index(bodyEnd, offsetBy: 2, limitedBy: data.endIndex),
                  data[bodyEnd..<afterChunk] == crlf else {
                throw URLError(.cannotParseResponse)
            }
            idx = afterChunk
        }
        return out
    }
}
