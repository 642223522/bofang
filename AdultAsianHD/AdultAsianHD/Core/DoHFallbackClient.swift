import Foundation
import Network
import Security

/// 无节点 DNS 污染兜底客户端（如 huangguoai.com 系统 DNS 污染到 66.220.147.11）：
/// 1) DoH 解析商链（`resolvers` 表，顺序可配）：Google 8.8.8.8/8.8.4.4 →
///    Cloudflare 1.1.1.1/1.0.0.1 → Ali 223.5.5.5/223.6.6.6 → DNSPod 119.29.29.29，
///    逐家问、每家 4 秒预算、第一家给有效答案即停；每家直连 IP 字面量 + SNI +
///    证书按端点域名校验，不走 URLSession、不走系统 DNS；
///    每家答案先过污染过滤：命中 Meta（Facebook）段即拒掉、记进诊断、问下一家
///    （DoH 只加密“手机→解析商”一段，解析商上游被污染时 DoH 照样返回假 IP）；
///    干净 IP 按 TTL 缓存；
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

    /// DoH 解析商表（顺序 = 询问顺序）：每家一个 JSON API 端点 + 直连 IP 字面量。
    /// endpointHost 同时是 TLS SNI 与 HTTP Host；path 是 JSON API 路径。
    /// 顺序说明：Google 放第一——沙箱实测它对 huangguoai.com 返回干净的
    /// CloudFront IP；Cloudflare 第二（作对照）；Ali 第三（国内可达、但上游
    /// 可能被污染，污染答案会被拒掉）；DNSPod 第四。
    /// 解析商主机名↔IP 的映射写死在表里，绝不走系统 DNS 解析（会被污染）。
    private struct DoHResolver {
        let name: String
        let endpointHost: String
        let path: String
        let ips: [String]
    }
    private static let resolvers: [DoHResolver] = [
        DoHResolver(name: "Google", endpointHost: "dns.google", path: "/resolve", ips: ["8.8.8.8", "8.8.4.4"]),
        DoHResolver(name: "Cloudflare", endpointHost: "cloudflare-dns.com", path: "/dns-query", ips: ["1.1.1.1", "1.0.0.1"]),
        DoHResolver(name: "Ali", endpointHost: "dns.alidns.com", path: "/resolve", ips: ["223.5.5.5", "223.6.6.6"]),
        DoHResolver(name: "DNSPod", endpointHost: "doh.pub", path: "/dns-query", ips: ["119.29.29.29"]),
    ]
    /// 每家 4 秒预算：同一家里的多个 IP 共用这 4 秒（先问的 IP 超时就把
    /// 剩余时间让给下一个 IP），整条链最坏 16 秒。超过预算即换下一家。
    private static let resolverTimeoutSeconds: TimeInterval = 4

    /// 污染 IP 段（Meta/Facebook）：系统 DNS 与 AliDoH 在手机网络上都返回过
    /// 这些段的假 IP（192.133.77.191、157.240.17.35、66.220.147.11），
    /// TCP 连过去直接黑洞。DoH 答案命中即拒。
    private static func isPoisonedIP(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower.contains(":") {
            // IPv6：2a03:2880::/32（Facebook 段）。
            return lower.hasPrefix("2a03:2880:")
        }
        let parts = lower.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return false }
        if a == 31 && b == 13 { return true }   // 31.13.0.0/16
        if a == 66 && b == 220 { return true }  // 66.220.0.0/16
        if a == 157 && b == 240 { return true } // 157.240.0.0/16
        if a == 192 && b == 133 && c == 77 { return true } // 192.133.77.0/24
        return false
    }

    /// 被拒的污染答案记录（诊断用：哪家解析商对哪个 host 给了污染 IP）。
    struct PoisonRejection: Sendable {
        let resolver: String
        let host: String
        let ip: String
        let date: Date
    }
    private var poisonRejections: [PoisonRejection] = []

    /// 被拒污染答案的快照（诊断/检测 Tab 用；最多保留最近 50 条）。
    func poisonRejectionsSnapshot() -> [PoisonRejection] {
        lock.lock()
        defer { lock.unlock() }
        return poisonRejections
    }

    private func recordPoisonRejection(resolver: String, host: String, ip: String) {
        lock.lock()
        poisonRejections.append(PoisonRejection(resolver: resolver, host: host, ip: ip, date: Date()))
        if poisonRejections.count > 50 { poisonRejections.removeFirst(poisonRejections.count - 50) }
        lock.unlock()
        #if DEBUG
        print("[DoH] poisoned IP rejected: \(ip) for \(host) from \(resolver)")
        #endif
    }

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

    /// 走 DoH 解析商链解析并直连 IP 发 HTTPS 请求（最多跟随 5 次重定向）。
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

    // MARK: - DoH 解析商链（Google → Cloudflare → Ali → DNSPod，逐家问，第一家给有效答案即停）

    /// 解析 host 的 A 记录：先读 TTL 内的缓存；没有就按 `resolvers` 表逐家问，
    /// 每家 4 秒预算、第一家给有效答案即停。
    /// 每家返回的 IP 先过污染过滤：命中 Meta 段的答案拒掉（只留干净的；
    /// 全污染则问下一家），被拒的记进诊断（`poisonRejectionsSnapshot`）。
    /// 干净 IP 按答案 TTL 缓存（钳制 [5, 300] 秒，与旧逻辑一致）。
    func resolveIPs(host: String) async -> [String] {
        let key = host.lowercased()
        lock.lock()
        if let cached = ipCache[key], cached.expiresAt > Date() {
            lock.unlock()
            return cached.ips
        }
        lock.unlock()

        for resolver in Self.resolvers {
            let houseDeadline = Date().addingTimeInterval(Self.resolverTimeoutSeconds)
            var houseIPs: [String] = []
            var houseMinTTL = 180
            for ip in resolver.ips {
                let remaining = houseDeadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                let timeout = min(Self.resolverTimeoutSeconds, remaining)
                guard let (ips, ttl) = await queryDoH(resolver: resolver, ip: ip, host: host, timeout: timeout),
                      !ips.isEmpty else { continue }
                houseIPs.append(contentsOf: ips)
                houseMinTTL = min(houseMinTTL, ttl)
                break
            }
            guard !houseIPs.isEmpty else { continue }
            // 污染过滤：拒掉 Meta 段，只留干净的；全污染则问下一家。
            var cleanIPs: [String] = []
            for ip in houseIPs {
                if Self.isPoisonedIP(ip) {
                    recordPoisonRejection(resolver: resolver.name, host: host, ip: ip)
                } else if !cleanIPs.contains(ip) {
                    cleanIPs.append(ip)
                }
            }
            guard !cleanIPs.isEmpty else { continue }
            let clampedTTL = TimeInterval(min(max(houseMinTTL, 5), 300))
            lock.lock()
            ipCache[key] = CachedIPs(ips: cleanIPs, expiresAt: Date().addingTimeInterval(clampedTTL))
            lock.unlock()
            return cleanIPs
        }
        return []
    }

    /// 对一家解析商做一次 JSON API 查询：不用 URLSession——直连该解析商的
    /// IP 字面量（`ip`:443），SNI = `resolver.endpointHost`，证书按端点域名校验
    ///（URLSession 对 IP 字面量 URL 的证书校验不可控；DoH 查询本身走系统 DNS
    /// 解析的话也会被污染）。
    /// 注意：JSON API 的查询参数是 name/type；Cloudflare/DNSPod 的 /dns-query
    /// 同样支持 `?name=&type=` + `Accept: application/dns-json`。
    /// 只取 A 记录（type == 1），与旧 queryAliDoH 一致——AAAA 未开通，
    /// 业务侧 perform() 只连 A 记录解析出的 IPv4。
    private func queryDoH(resolver: DoHResolver, ip: String, host: String, timeout: TimeInterval) async -> ([String], Int)? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = resolver.endpointHost
        comps.path = resolver.path
        comps.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let (data, http) = try? await fetchSingleHop(url: url, host: resolver.endpointHost, ip: ip, request: req, timeout: timeout),
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

    /// 单跳 HTTPS 请求（直连 IP 字面量 + SNI + 真实证书校验 + HTTP/1.1）。
    /// internal（非 private）：StagedNetworkProbe 的直连 IP 探针复用同一条
    /// HTTP 栈，探针测的就是业务侧实际走的路径。
    func fetchSingleHop(
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
