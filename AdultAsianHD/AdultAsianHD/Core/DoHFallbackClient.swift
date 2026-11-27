import Foundation
import Network
import Security
import CFNetwork

/// 系统代理状态（CFNetworkCopySystemProxySettings 字符串键；kCFNetworkProxiesHTTPSProxy
/// 是 macOS-only，iOS 用字符串键）。显式 HTTP/SOCKS5 代理与包隧道 VPN 是两回事：
/// 前者必须经代理协议连接，后者（Shadowrocket/Clash/Surge 的 Network Extension
/// 隧道）下原始连接的包本就走 OS 路由进隧道，直连 IP 并不绕过隧道。
enum ActiveSystemProxy: Equatable {
    case none
    case http(host: String, port: UInt16)
    case socks5(host: String, port: UInt16)
    case pacOnly(url: String)

    static func current() -> ActiveSystemProxy {
        guard let dict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return .none
        }
        if (dict["HTTPSEnable"] as? Int) == 1,
           let host = dict["HTTPSProxy"] as? String, !host.isEmpty,
           let port = dict["HTTPSPort"] as? Int, port > 0, port <= 65535 {
            return .http(host: host, port: UInt16(port))
        }
        if (dict["HTTPEnable"] as? Int) == 1,
           let host = dict["HTTPProxy"] as? String, !host.isEmpty,
           let port = dict["HTTPPort"] as? Int, port > 0, port <= 65535 {
            return .http(host: host, port: UInt16(port))
        }
        if (dict["SOCKSEnable"] as? Int) == 1,
           let host = dict["SOCKSProxy"] as? String, !host.isEmpty,
           let port = dict["SOCKSPort"] as? Int, port > 0, port <= 65535 {
            return .socks5(host: host, port: UInt16(port))
        }
        if (dict["ProxyAutoConfigEnable"] as? Int) == 1,
           let pac = dict["ProxyAutoConfigURLString"] as? String, !pac.isEmpty {
            return .pacOnly(url: pac)
        }
        return .none
    }

    /// 诊断用的短标签（不含敏感信息）。
    var label: String {
        switch self {
        case .none: return "none"
        case .http: return "http-proxy"
        case .socks5: return "socks5-proxy"
        case .pacOnly: return "pac"
        }
    }

    /// 是否为显式代理（HTTP/SOCKS5），即 NWConnection 必须经代理协议连接。
    /// 注意：不能写 `proxy != .pacOnly` 这种裸比较——带关联值的 case 不能
    /// 直接比较（run #30 构建就是这么死的），一律用这里的计算属性或 switch。
    var isExplicitProxy: Bool {
        switch self {
        case .http, .socks5: return true
        case .none, .pacOnly: return false
        }
    }

    /// 是否为 PAC-only（NWConnection 执行不了 JS PAC，只能走 URLSession）。
    var isPACOnly: Bool {
        if case .pacOnly = self { return true }
        return false
    }
}

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

/// DoH 直连失败 + 是否已收到最终（非 1xx）响应头（F4）：收到响应头后
/// 再换 IP/换传输重发是错的——外层看到 responseStarted 就直接抛原错，不再重试。
/// 只在 DoHFallbackClient 内部流转；公开的 2 元组 fetchSingleHop 会拆开包装
/// 再抛原错，对外错误语义不变。
struct DoHTransportFailure: Error {
    let underlying: Error
    let responseStarted: Bool
}

/// DoH 解析结果（F13）：三种空结果分开，不再一律映射成 .cannotFindHost。
enum DoHResolution {
    case resolved([String])
    case nxdomain
    case resolversUnreachable
    case allCandidatesRejected
}

/// DoH 解析失败（F13 的三种信号）：诊断 classify() 会按种区分，
/// 不再把“解析商全挂 / 答案全被拒”误报成“域名不存在”。
enum DoHResolutionError: Error, LocalizedError {
    case nxdomain(host: String)
    case resolversUnreachable(host: String)
    case allCandidatesRejected(host: String)

    var errorDescription: String? {
        switch self {
        case .nxdomain(let host):
            return "DNS 域名不存在 (\(host))"
        case .resolversUnreachable(let host):
            return "DoH 解析商均未返回可用 A 记录 (\(host))"
        case .allCandidatesRejected(let host):
            return "DoH 解析答案全部被污染过滤拒绝 (\(host))"
        }
    }
}

/// 请求内 cookie jar 的一条：HTTPCookie 本身不区分有没有 Domain 属性，
/// host-only 与否只能从原始 Set-Cookie 行看（F5a），所以连同标志一起存。
private struct JarCookie {
    let cookie: HTTPCookie
    /// true = 原始 Set-Cookie 行没有 Domain 属性（host-only，只精确匹配 host）。
    let hostOnly: Bool
}

/// 服务端删掉的 cookie 的范围键（R3-10）：过期按 (name, domain, path)
/// 划范围，不再只记裸名——否则跨域的 Max-Age=0 会删掉别家的种子 cookie。
/// domain 已归一化（小写、去前导 "."）；hostOnly=true 表示只匹配完全相同的 host，
/// false 表示匹配该域及其子域；path 必须精确相等（种子的 path 视为 "/"）。
private struct ExpiredCookieKey: Hashable {
    let name: String
    let domain: String
    let hostOnly: Bool
    let path: String
}

final class DoHFallbackClient: @unchecked Sendable {
    static let shared = DoHFallbackClient()

    private struct CachedIPs {
        let ips: [String]
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var ipCache: [String: CachedIPs] = [:]
    private var preferredHosts: Set<String> = []
    /// 网络世代（R3-6）：resetForNetworkChange() 时 +1。resolveIPs() 与
    /// perform() 在入口捕获它，写缓存 / 记偏好前重新核对——旧网在途的
    /// 解析/请求绝不把旧 IP 写进新网的缓存与偏好表。
    private var networkGeneration: UInt64 = 0

    /// 当前网络世代（lock 内读）。
    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return networkGeneration
    }

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
        networkGeneration &+= 1
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

    /// 原子围栏记偏好（R4-10）：同一把锁内校验 generation == expected 再插入——
    /// 避免 resetForNetworkChange() 在检查与写入之间跑、把旧网的偏好插回新网的表。
    func markDoHPreferred(host: String, ifGeneration expected: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard networkGeneration == expected else { return }
        preferredHosts.insert(host.lowercased())
    }

    /// 撤销某 host 的 DoH 偏好（R4-4）：DoH 一挂就摘掉，下次请求重新走
    /// URLSession（偏好一旦建立永不撤销，会让一个站持续失败到切网）。
    /// 只 lock 内删除，不用 generation 校验。
    func removeDoHPreferred(host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        lock.lock()
        preferredHosts.remove(host)
        lock.unlock()
    }

    /// 走 DoH 解析商链解析并直连 IP 发 HTTPS 请求（最多跟随 5 次重定向）。
    /// viaProxy：系统显式代理开着时传 .http/.socks5——每跳改走代理（代理负责
    /// DNS + TCP，不做 DoH 解析、不记 DoH 偏好）；nil / .none 时走原 DoH 直连
    /// 逻辑。.pacOnly 不应传进来（PAC 下走 URLSession，见调用方）。
    func perform(
        request rawRequest: URLRequest,
        preservedHeaders: [String: String],
        timeout: TimeInterval,
        viaProxy: ActiveSystemProxy? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse, remoteIP: String) {
        var currentReq = rawRequest
        let originURL = rawRequest.url
        // R3-6：入口捕获网络世代；记 DoH 偏好前重新核对，变了就跳过这次
        // 标记（不抛错——在途请求可能还能通；只是不污染新网的偏好表）。
        let generation = currentGeneration()
        // 请求内 cookie jar：跳转时把上跳的 Set-Cookie 带到下跳（Cloudflare
        // 的 cf_clearance 就靠这个不断挑战循环；jar 只活在这一次请求里，
        // 不进共享存储，跨请求不持久化）。
        // expiredKeys：服务端用 Max-Age=0 / 过期时间删掉的 cookie 范围键——
        // jar 里被删的条目已不在，过期键必须另记，否则种子里的旧 cookie
        // 下一跳会被复活（F5）。fresh cookie 到达时按 (name, domain, path)
        // 撤销对应的过期键（R3-10：只记裸名会跨域误删别家的种子 cookie）。
        var cookieJar: [JarCookie] = []
        var expiredKeys: Set<ExpiredCookieKey> = []
        // 绝对 deadline：data() 传进来的是剩余预算，perform 内部各阶段
        //（解析商链、每跳、每个 IP）共用这一本账，不再每层重起预算。
        if timeout <= 0 { throw URLError(.timedOut) }
        let absoluteDeadline = Date().addingTimeInterval(timeout)
        let remaining: () -> TimeInterval = { max(0, absoluteDeadline.timeIntervalSinceNow) }
        for _ in 0..<6 {
            guard let url = currentReq.url,
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else {
                throw URLError(.badURL)
            }
            guard remaining() > 0 else { throw URLError(.timedOut) }
            let perHopTimeout = min(min(max(timeout / 2, 4), 10), remaining())
            let hop: (data: Data, response: HTTPURLResponse, remoteIP: String, setCookieValues: [String])
            if let proxy = viaProxy, proxy.isExplicitProxy {
                // 经系统代理：不解析 DoH、不记偏好；代理做 DNS + TCP。
                // R3-2：Core 会把非取消失败包成 DoHTransportFailure，这里
                // 必须解包再抛原错——否则 classify() 误判成 .unknown，
                // WordPress 的 .timedOut/.networkConnectionLost 重试也触发不了。
                do {
                    let res = try await fetchSingleHopViaProxyCore(
                        url: url,
                        host: host,
                        proxy: proxy,
                        request: currentReq,
                        timeout: min(perHopTimeout, remaining())
                    )
                    // R4-8：remoteIP 只用于展示（诊断事件的 remoteAddress），
                    // 代理标签不是 IP——返回空串，展示层空值即“经代理”。
                    hop = (res.0, res.1, "", res.2)
                } catch let failure as DoHTransportFailure {
                    throw failure.underlying
                }
            } else {
                // F13：解析失败分三种信号，不再一律 .cannotFindHost。
                let ips: [String]
                switch try await resolveIPs(host: host, deadline: absoluteDeadline) {
                case .resolved(let resolvedIPs):
                    ips = resolvedIPs
                case .nxdomain:
                    throw DoHResolutionError.nxdomain(host: host)
                case .resolversUnreachable:
                    throw DoHResolutionError.resolversUnreachable(host: host)
                case .allCandidatesRejected:
                    throw DoHResolutionError.allCandidatesRejected(host: host)
                }
                guard !ips.isEmpty else { throw URLError(.cannotFindHost) }

                var lastError: Error = URLError(.cannotConnectToHost)
                var succeeded: (Data, HTTPURLResponse, String, [String])?
                let candidates = Array(ips.prefix(4))
                for (index, ip) in candidates.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    guard remaining() > 0 else { throw URLError(.timedOut) }
                    // F28：每个 IP 最多拿 remaining()/剩余 IP 数（下限 2s，上限
                    // perHopTimeout），黑洞首 IP 不能吃光预算饿死后面的 IP。
                    let ipsLeft = candidates.count - index
                    let perIPTimeout = min(perHopTimeout, max(2, remaining() / Double(max(ipsLeft, 1))))
                    do {
                        let res = try await fetchSingleHopCore(
                            url: url,
                            host: host,
                            ip: ip,
                            request: currentReq,
                            timeout: min(perIPTimeout, remaining())
                        )
                        succeeded = (res.0, res.1, ip, res.2)
                        markDoHPreferred(host: host, ifGeneration: generation)
                        break
                    } catch let failure as DoHTransportFailure {
                        // F4：该 IP 已收到最终响应头，body 失败不再换 IP。
                        if failure.responseStarted { throw failure.underlying }
                        lastError = failure.underlying
                        continue
                    } catch {
                        lastError = error
                        continue
                    }
                }
                guard let s = succeeded else { throw lastError }
                hop = s
            }

            // 本跳的 Set-Cookie 收进 jar（每条原始头行单独解析——
            // parseHTTP11Response 的 [String: String] 会丢多值）。
            // host-only 与否从原始头行看有没有 Domain 属性（F5a）；
            // 过期 cookie 不进 jar，但范围键记进 expiredKeys（F5/R3-10：
            // 种子里的旧 cookie 下一跳要删掉，但只删范围匹配的）；
            // fresh cookie 到达时按同样的 (name, domain, path) 撤销过期键。
            for rawValue in hop.setCookieValues {
                let hasDomainAttr = Self.setCookieHasDomainAttribute(rawValue)
                let parsed = HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": rawValue],
                    for: hop.response.url ?? url
                )
                for cookie in parsed {
                    cookieJar.removeAll {
                        $0.cookie.name == cookie.name
                            && Self.normalizedCookieDomain($0.cookie.domain) == Self.normalizedCookieDomain(cookie.domain)
                            && $0.cookie.path == cookie.path
                    }
                    let key = ExpiredCookieKey(
                        name: cookie.name,
                        domain: Self.normalizedCookieDomain(cookie.domain),
                        hostOnly: !hasDomainAttr,
                        path: cookie.path
                    )
                    if cookie.expiresDate == nil || cookie.expiresDate! > Date() {
                        cookieJar.append(JarCookie(cookie: cookie, hostOnly: !hasDomainAttr))
                        expiredKeys.remove(key)
                    } else {
                        expiredKeys.insert(key)
                    }
                }
            }

            // 处理 301/302/303/307/308 重定向
            if let nextReq = Self.redirectRequest(
                after: hop.response,
                from: currentReq,
                originURL: originURL,
                originRequest: rawRequest,
                preservedHeaders: preservedHeaders,
                cookies: cookieJar,
                expiredKeys: expiredKeys
            ) {
                currentReq = nextReq
                continue
            }
            return (hop.data, hop.response, hop.remoteIP)
        }
        throw URLError(.httpTooManyRedirects)
    }

    /// 3xx 重定向的下一跳请求（301/302/303/307/308 + Location）：无重定向返回 nil。
    /// 只有 303 强制转 GET（转 GET 时 Content-Type 随 body 一起丢掉）；301/302
    /// 保持原方法（RFC 7231：301/302 的方法保留是允许的，POST 301/302 转 GET
    /// 是历史遗留行为，对签名 POST（如黄果现铸）转 GET 会丢 body 导致失败）。
    /// 非 http(s) 的 Location 返回 nil（停住跳转、返回 3xx 响应，与
    /// PerRequestDelegate 的行为一致，不抛 .badURL）。
    /// 跨域时凭据头不跟过去；Host/Content-Length/Cookie 永不复制——Cookie 每次
    /// 按目标 URL 重建：种子（原始请求的 Cookie 头，只同源继承）→ 删过期键
    ///（按 name/domain/path 划范围，R3-10）→ jar 覆盖（同名不同 Path 都保留，
    /// 按 path 长度降序，R3-9；合并为空时删掉 Cookie 头）。
    /// cookies：perform 的请求内 jar——按目标 URL 匹配后带上（Cloudflare
    /// 的 cf_clearance 就靠这个不断挑战循环）。
    private static func redirectRequest(
        after http: HTTPURLResponse,
        from currentReq: URLRequest,
        originURL: URL?,
        originRequest: URLRequest,
        preservedHeaders: [String: String],
        cookies: [JarCookie] = [],
        expiredKeys: Set<ExpiredCookieKey> = []
    ) -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let url = currentReq.url,
              let nextURL = URL(string: location, relativeTo: url)?.absoluteURL,
              let scheme = nextURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        var nextReq = URLRequest(url: nextURL)
        let is303 = http.statusCode == 303
        nextReq.httpMethod = is303 ? "GET" : (currentReq.httpMethod ?? "GET")
        // R4-5：流式 body（httpBodyStream）不复制——DoH 自研栈只读 httpBody，
        // 流会被丢掉；有流的请求根本不进 DoH（data() 里已拦），这里只是兜底。
        if nextReq.httpMethod != "GET", currentReq.httpBodyStream == nil { nextReq.httpBody = currentReq.httpBody }
        let sameOrigin = NetConstants.isSameOrigin(originURL, nextURL)
        // 跳步头（Connection/Transfer-Encoding/Keep-Alive/Proxy-Connection/
        // Upgrade）上 H2/H3 会违反 RFC 9113/9114，直接 RST_STREAM，永不复制。
        // Cookie 也不复制——每次按目标 URL 重建（见下面）。
        let hopByHop: Set<String> = ["host", "content-length", "connection",
                                     "transfer-encoding", "keep-alive",
                                     "proxy-connection", "upgrade", "cookie"]
        // 先抄上跳实际发出的全部请求头（UA/Accept/Referer 等——旧代码只抄
        // preservedHeaders，这些全丢了）；跨域时凭据头不跟过去。
        if let sent = currentReq.allHTTPHeaderFields {
            for (k, v) in sent {
                let lower = k.lowercased()
                if hopByHop.contains(lower) { continue }
                if !sameOrigin && NetConstants.isSensitiveHeader(k) { continue }
                nextReq.setValue(v, forHTTPHeaderField: k)
            }
        }
        // 模块声明头后抄（同名时覆盖上跳的值）。
        for (k, v) in preservedHeaders {
            let lower = k.lowercased()
            if !sameOrigin && NetConstants.isSensitiveHeader(k) { continue }
            if hopByHop.contains(lower) { continue }
            nextReq.setValue(v, forHTTPHeaderField: k)
        }
        // 303 转 GET：Content-Type 随 body 一起丢掉（Content-Length 已在
        // hopByHop 里，body 本来也不复制）。
        if is303 { nextReq.setValue(nil, forHTTPHeaderField: "Content-Type") }
        // Cookie 重建（顺序必须是：种子 → 删过期键 → jar 覆盖）：
        // 种子只从原始请求取（多跳回源 A→B→A 时 B 的 Cookie 不能跟着抄回 A），
        // 且只同源继承；jar 里活着的同名 cookie 能在删除后重新补回来。
        // R3-9：merged 是有序的 (name, value) 对列表，不再按 name 唯一化——
        // 同名不同 Path 的 cookie 都保留（同名 jar 条目按 path 长度降序排）。
        // R3-10：每个对都带范围（domain/hostOnly/path），过期删除只删范围匹配的。
        // 种子的范围是 (origin host, host-only, "/")。
        var merged: [(name: String, value: String, domain: String, hostOnly: Bool, path: String)] = []
        let originHost = originURL?.host?.lowercased() ?? ""
        if sameOrigin, let seedCookie = originRequest.value(forHTTPHeaderField: "Cookie") {
            for pair in seedCookie.split(separator: ";") {
                // R4-9：空值 cookie（"flag="）必须拆成 ["flag", ""]——默认
                // omittingEmptySubsequences: true 会把它拆成 ["flag"]，
                // guard kv.count == 2 失败就把空值 cookie 悄悄丢了。
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let name = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                merged.append((name: name, value: value, domain: originHost, hostOnly: true, path: "/"))
            }
        }
        merged.removeAll { pair in
            expiredKeys.contains { Self.expiredKeyAppliesToSeed($0, name: pair.name, domain: pair.domain, nextURL: nextURL) }
        }
        let matching = cookies.filter { Self.cookieMatches($0, url: nextURL) }
        // 按 name 分组（保持首次出现顺序）；组内按 path 长度降序——最具体的在前。
        var namesInOrder: [String] = []
        var byName: [String: [JarCookie]] = [:]
        for entry in matching {
            if byName[entry.cookie.name] == nil { namesInOrder.append(entry.cookie.name) }
            byName[entry.cookie.name, default: []].append(entry)
        }
        for name in namesInOrder {
            let entries = (byName[name] ?? []).sorted(by: { $0.cookie.path.count > $1.cookie.path.count })
            for entry in entries {
                // R4-1：只删与 jar 条目 (name, domain, path) 身份相同的对——
                // 不同 path/domain 的种子保留（同名不同 path 是两个合法 cookie，
                // 按裸 name 全删会把种子的 sid=root 连同 jar 的 sid=admin 一起丢掉）。
                merged.removeAll {
                    $0.name == entry.cookie.name
                        && Self.normalizedCookieDomain($0.domain) == Self.normalizedCookieDomain(entry.cookie.domain)
                        && $0.path == entry.cookie.path
                }
                merged.append((
                    name: entry.cookie.name,
                    value: entry.cookie.value,
                    domain: Self.normalizedCookieDomain(entry.cookie.domain),
                    hostOnly: entry.hostOnly,
                    path: entry.cookie.path
                ))
            }
        }
        // R4-1：同名条目（种子 + jar 一起）按 path 长度降序排——最具体的 path
        // 在前（RFC 6265：同名 cookie 按 path 长度降序发）。按 name 首次出现
        // 顺序分组，只排组内，不动组间顺序。
        if !merged.isEmpty {
            var order: [String] = []
            var groups: [String: [(name: String, value: String, domain: String, hostOnly: Bool, path: String)]] = [:]
            for pair in merged {
                if groups[pair.name] == nil { order.append(pair.name) }
                groups[pair.name, default: []].append(pair)
            }
            merged = order.flatMap { (groups[$0] ?? []).sorted(by: { $0.path.count > $1.path.count }) }
        }
        if merged.isEmpty {
            nextReq.setValue(nil, forHTTPHeaderField: "Cookie")
        } else {
            let header = merged
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            nextReq.setValue(header, forHTTPHeaderField: "Cookie")
        }
        return nextReq
    }

    /// 原始 Set-Cookie 行是否带 Domain 属性（有 → domain cookie，可匹配子域；
    /// 无 → host-only）。第一段是 name=value，只看后面的属性段。
    /// R3-11：空 Domain= 不算 domain 属性（RFC 6265 §5.2.3：空值忽略，
    /// cookie 仍是 host-only）；裸 "domain"（无 "="）也不是。
    private static func setCookieHasDomainAttribute(_ rawValue: String) -> Bool {
        for seg in rawValue.split(separator: ";", omittingEmptySubsequences: false).dropFirst() {
            let attr = seg.trimmingCharacters(in: .whitespaces).lowercased()
            if attr.hasPrefix("domain=") && !attr.dropFirst("domain=".count).isEmpty { return true }
        }
        return false
    }

    /// Cookie 域名归一化（小写、去前导 "."）：HTTPCookie.domain 对 domain
    /// cookie 可能带前导 "."，比较前统一去掉，避免同域因写法不同判不等。
    private static func normalizedCookieDomain(_ domain: String) -> String {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return d
    }

    /// 过期键是否删种子 cookie（R4-3，种子专用——全代码只有 redirectRequest
    /// 的种子删除一个调用点；Set-Cookie 循环用身份 remove/insert，不走这里）。
    /// 种子永远是 host-only：domain-scope（Domain=）的过期键不删种子；
    /// domain 精确相等；path 用 RFC 6265 前缀规则对 nextURL.path 匹配——
    /// 不是与种子建模的 "/" 精确相等（种子没有 path 元数据，服务端可能按
    /// /app 删它；nextURL.path 在过期键的 path 前缀内才算覆盖）。
    private static func expiredKeyAppliesToSeed(_ key: ExpiredCookieKey, name: String, domain: String, nextURL: URL) -> Bool {
        guard key.name == name, key.hostOnly else { return false }
        guard Self.normalizedCookieDomain(domain) == key.domain else { return false }
        let path = nextURL.path.isEmpty ? "/" : nextURL.path
        if path == key.path { return true }
        guard path.hasPrefix(key.path) else { return false }
        if key.path.hasSuffix("/") { return true }
        let nextIndex = path.index(path.startIndex, offsetBy: key.path.count)
        return path[nextIndex] == "/"
    }

    /// host 是否为 IP 字面量（IPv4 四段数字 / 含冒号的 IPv6）：IP 上后缀匹配
    /// 无意义，cookie 只精确匹配。
    private static func isIPAddressLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Cookie 是否适用于目标 URL（域名/路径前缀/secure/过期，RFC 6265
    /// 的够用子集）。host-only（原始 Set-Cookie 无 Domain 属性）只精确匹配
    /// host；domain cookie 才允许子域后缀匹配；IP 字面量 host 只精确匹配。
    /// jar 的域名匹配本身就是跨域守卫——只有 domain 匹配目标 host 的 cookie
    /// 才会被带上，不再另加 sameOrigin 门。
    private static func cookieMatches(_ entry: JarCookie, url: URL) -> Bool {
        let cookie = entry.cookie
        guard let host = url.host?.lowercased() else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        if let exp = cookie.expiresDate, exp <= Date() { return false }
        let domain = cookie.domain.lowercased()
        let hostOK: Bool = {
            if Self.isIPAddressLiteral(host) { return host == domain }
            if entry.hostOnly { return host == domain }
            if domain.hasPrefix(".") {
                let bare = String(domain.dropFirst())
                return host == bare || host.hasSuffix("." + bare)
            }
            return host == domain || host.hasSuffix("." + domain)
        }()
        guard hostOK else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path
        if path == cookiePath { return true }
        guard path.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let nextIndex = path.index(path.startIndex, offsetBy: cookiePath.count)
        return path[nextIndex] == "/"
    }

    // MARK: - DoH 解析商链（Google → Cloudflare → Ali → DNSPod，逐家问，第一家给有效答案即停）

    /// 解析 host 的 A 记录：先读 TTL 内的缓存；没有就按 `resolvers` 表逐家问，
    /// 每家 4 秒预算、第一家给有效答案即停。
    /// 每家返回的 IP 先过污染过滤：命中 Meta 段的答案拒掉（只留干净的；
    /// 全污染则问下一家），被拒的记进诊断（`poisonRejectionsSnapshot`）。
    /// 干净 IP 按答案 TTL 缓存（钳制 [5, 300] 秒，与旧逻辑一致）。
    /// 会 throw——只抛 CancellationError（父任务取消时立即停，不要把取消
    /// 翻译成 cannotFindHost）与 URLError(.timedOut)（deadline 耗尽，直接抛，
    /// 不再返回空数组）；空结果分三种信号回（F13），不再一律 .cannotFindHost。
    func resolveIPs(host: String, deadline: Date) async throws -> DoHResolution {
        let key = host.lowercased()
        // R3-6：入口捕获网络世代；写缓存前重新核对，变了就跳过这次写
        //（不抛错——在途请求手里已有 IP，可能还能通；只是不污染新网缓存）。
        let generation = currentGeneration()
        lock.lock()
        if let cached = ipCache[key], cached.expiresAt > Date() {
            lock.unlock()
            return .resolved(cached.ips)
        }
        lock.unlock()

        var sawAnyAnswer = false
        for resolver in Self.resolvers {
            // 取消传播：换解析商前查一次，取消了就停，不要继续烧 4 秒预算。
            if Task.isCancelled { throw CancellationError() }
            // 绝对 deadline：预算到了直接抛 .timedOut，不要把整条解析商链问完（最坏 16 秒）。
            guard Date() < deadline else { throw URLError(.timedOut) }
            let houseDeadline = Date().addingTimeInterval(min(Self.resolverTimeoutSeconds, max(0, deadline.timeIntervalSinceNow)))
            var houseIPs: [String] = []
            var houseMinTTL = 180
            // F28：同家多个 IP 均分本家剩余预算（下限 1s），黑洞首 IP 不吃光整家预算。
            // R3-4：再 clamp 到 houseRemaining——剩余不足 1s 时不许放大到 1s 跑出 deadline。
            let resolverIPs = resolver.ips
            for (ipIndex, ip) in resolverIPs.enumerated() {
                let houseRemaining = houseDeadline.timeIntervalSinceNow
                guard houseRemaining > 0 else { break }
                let ipsLeft = resolverIPs.count - ipIndex
                let timeout = min(Self.resolverTimeoutSeconds, houseRemaining, max(1, houseRemaining / Double(max(ipsLeft, 1))))
                guard let query = try await queryDoH(resolver: resolver, ip: ip, host: host, timeout: timeout) else { continue }
                if query.0.isEmpty {
                    // ([], 0) 哨兵：NXDOMAIN 已确认，停链（G4）。
                    return .nxdomain
                }
                houseIPs.append(contentsOf: query.0)
                houseMinTTL = min(houseMinTTL, query.1)
                break
            }
            guard !houseIPs.isEmpty else { continue }
            sawAnyAnswer = true
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
            if generation == networkGeneration {
                ipCache[key] = CachedIPs(ips: cleanIPs, expiresAt: Date().addingTimeInterval(clampedTTL))
            }
            lock.unlock()
            return .resolved(cleanIPs)
        }
        // R3-5：deadline 在最后一个解析商查询中过期时，循环会正常结束——
        // 这里补查一次，否则会被误报成 .resolversUnreachable（.dns 而非 .timeout）。
        if Task.isCancelled { throw CancellationError() }
        if Date() >= deadline { throw URLError(.timedOut) }
        // F13：三种空结果分开——有答案但全被污染过滤拒掉 vs 一家都没给出可用答案。
        if sawAnyAnswer { return .allCandidatesRejected }
        return .resolversUnreachable
    }

    /// 对一家解析商做一次 JSON API 查询：不用 URLSession——直连该解析商的
    /// IP 字面量（`ip`:443），SNI = `resolver.endpointHost`，证书按端点域名校验
    ///（URLSession 对 IP 字面量 URL 的证书校验不可控；DoH 查询本身走系统 DNS
    /// 解析的话也会被污染）。
    /// 注意：JSON API 的查询参数是 name/type；Cloudflare/DNSPod 的 /dns-query
    /// 同样支持 `?name=&type=` + `Accept: application/dns-json`。
    /// 只取 A 记录（type == 1），与旧 queryAliDoH 一致——AAAA 未开通，
    /// 业务侧 perform() 只连 A 记录解析出的 IPv4。
    /// 会 throw——只抛 CancellationError（旧代码用 try? 把取消也吞了，
    /// 取消会一路变成 cannotFindHost）；别的失败一律回 nil（换下一个 IP/解析商）。
    private func queryDoH(resolver: DoHResolver, ip: String, host: String, timeout: TimeInterval) async throws -> ([String], Int)? {
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
        let fetched: (Data, HTTPURLResponse)
        do {
            fetched = try await fetchSingleHop(url: url, host: resolver.endpointHost, ip: ip, request: req, timeout: timeout)
        } catch let e as CancellationError {
            throw e
        } catch {
            return nil
        }
        let (data, http) = fetched
        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // G4：读 DNS Status——Status 3 (NXDOMAIN) 立即停链（([[], 0) 哨兵，
        // resolveIPs 见到空数组即报 NXDOMAIN）；别的非 0 状态换下一家；
        // Status 0 但无 A 记录也继续轮询（保留冗余，歧义情况不提前下结论）。
        let status = json["Status"] as? Int ?? -1
        if status == 3 {
            return ([], 0)
        }
        guard status == 0,
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
    /// TLS 选项：显式 SNI = 目标域名 + ALPN http/1.1 + 按目标真实域名校验证书
    ///（而非 IP 字面量）。verify block 跑在独立 queue 上（与连接 queue 分开也无妨）。
    /// TLS 校验队列：static 共享，每次新建会泄漏队列（F33）。
    private static let tlsVerifyQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.doh.tlsverify")

    private func makeTLSOptions(host: String) -> NWProtocolTLS.Options {
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tlsOpts.securityProtocolOptions, "http/1.1")
        let verifyQueue = Self.tlsVerifyQueue
        sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, policy)
            let ok = SecTrustEvaluateWithError(trust, nil)
            complete(ok)
        }, verifyQueue)
        return tlsOpts
    }

    /// 带代理配置的 NWParameters（iOS 17+）：HTTP/SOCKS5 代理时把 ProxyConfiguration
    /// 挂到 PrivacyContext 上，连接目标 hostname（代理负责 DNS + TCP）；直连/PAC
    /// 时不挂代理（PAC 走 URLSession，NWParameters 执行不了 JS PAC）。
    private func makeHTTP11TLSParameters(sniHost: String, proxy: ActiveSystemProxy) -> NWParameters {
        let tlsOpts = makeTLSOptions(host: sniHost)
        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        switch proxy {
        case .http(let host, let port):
            // 端口已在 ActiveSystemProxy.current() 里验过 1...65535，不会为 nil。
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
            let cfg = ProxyConfiguration(httpCONNECTProxy: endpoint)
            let ctx = NWParameters.PrivacyContext(description: "SystemHTTPProxy")
            ctx.proxyConfigurations = [cfg]
            params.setPrivacyContext(ctx)
        case .socks5(let host, let port):
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
            let cfg = ProxyConfiguration(socksv5Proxy: endpoint)
            let ctx = NWParameters.PrivacyContext(description: "SystemSOCKS5Proxy")
            ctx.proxyConfigurations = [cfg]
            params.setPrivacyContext(ctx)
        case .none, .pacOnly:
            break
        }
        return params
    }

    func fetchSingleHop(
        url: URL,
        host: String,
        ip: String,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response, _) = try await fetchSingleHopCore(url: url, host: host, ip: ip, request: request, timeout: timeout)
            return (data, response)
        } catch let failure as DoHTransportFailure {
            // F4：包装只在 perform 的 IP 循环里有意义；公开 2 元组接口拆开
            // 包装再抛原错，对外错误语义不变（queryDoH / 探针继续原有逻辑）。
            throw failure.underlying
        }
    }

    /// fetchSingleHop 的内核：多返回原始 Set-Cookie 头行（供 perform 的
    /// cookie jar 用——[String: String] 存头会丢多值）。2 元组签名不动
    ///（StagedNetworkProbe 靠它），perform 内部直接调内核。
    private func fetchSingleHopCore(
        url: URL,
        host: String,
        ip: String,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse, [String]) {
        let portNum = UInt16(url.port ?? 443)
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            throw URLError(.badURL)
        }
        let wireData = buildHTTP11Request(url: url, host: host, request: request)
        let tlsOpts = makeTLSOptions(host: host)
        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        let rawResponse = try await driveConnection(
            endpoint: .hostPort(host: .init(ip), port: nwPort),
            params: params,
            wireData: wireData,
            timeout: timeout,
            method: request.httpMethod ?? "GET"
        )
        do {
            return try parseHTTP11Response(rawResponse, url: url, method: request.httpMethod ?? "GET")
        } catch {
            // driveConnection 只返回收齐帧的原始响应（最终头已解析），
            // 解析失败意味着已收到响应头：包起来，外层不再换 IP（F4）。
            throw DoHTransportFailure(underlying: error, responseStarted: true)
        }
    }

    /// 经系统代理的单跳 HTTPS（HTTP CONNECT / SOCKS5）：NWConnection 连目标
    /// hostname（代理负责 DNS + TCP），TLS + ALPN http/1.1 在代理隧道内完成，
    /// 零 H3、零绕代理。PAC-only 时不走这里（NWParameters 执行不了 JS PAC）。
    func fetchSingleHopViaProxy(
        url: URL,
        host: String,
        proxy: ActiveSystemProxy,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response, _) = try await fetchSingleHopViaProxyCore(url: url, host: host, proxy: proxy, request: request, timeout: timeout)
            return (data, response)
        } catch let failure as DoHTransportFailure {
            // F4：同 fetchSingleHop，公开接口拆开包装再抛原错。
            throw failure.underlying
        }
    }

    /// fetchSingleHopViaProxy 的内核：同 fetchSingleHopCore（多返回原始
    /// Set-Cookie 头行），perform 内部直接调内核。
    private func fetchSingleHopViaProxyCore(
        url: URL,
        host: String,
        proxy: ActiveSystemProxy,
        request: URLRequest,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse, [String]) {
        let portNum = UInt16(url.port ?? 443)
        guard let nwPort = NWEndpoint.Port(rawValue: portNum) else {
            throw URLError(.badURL)
        }
        let wireData = buildHTTP11Request(url: url, host: host, request: request)
        let params = makeHTTP11TLSParameters(sniHost: host, proxy: proxy)
        let rawResponse = try await driveConnection(
            // 注意：不要写 .name(host, nil)——NWEndpoint.Host.name 的第二个
            // 关联值没有公开文档可查，无法确认 nil 是否合法（run #31 构建
            // 1 分钟挂，唯一未经核实的 API 就是这一行）。Host 的 String
            // 初始化器 NWEndpoint.Host(host) 是公开且被 WireGuard 等生产
            // 代码在用的写法，主机名进 .name、IP 进 .ipv4/.ipv6，语义相同。
            endpoint: .hostPort(host: .init(host), port: nwPort),
            params: params,
            wireData: wireData,
            timeout: timeout,
            method: request.httpMethod ?? "GET"
        )
        do {
            return try parseHTTP11Response(rawResponse, url: url, method: request.httpMethod ?? "GET")
        } catch {
            // F4：同 fetchSingleHopCore，解析失败 = 已收到响应头。
            throw DoHTransportFailure(underlying: error, responseStarted: true)
        }
    }

    /// 驱动一条 NWConnection：发 wireData、按 HTTP 帧收完响应、超时取消。
    /// fetchSingleHop（直连 IP）与 fetchSingleHopViaProxy（经系统代理）共用。
    /// 帧规则（收到即停，不等 TCP 关）：HEAD/204/304 只有头；Content-Length
    /// 精确字节数；chunked 到终结 0 块；既无长度又非 chunked 才等 EOF。
    /// 任何错误 + 半截 body 都是失败——截断的响应绝不当成功返回。
    /// 失败时按 F4 包装：已收到最终响应头就记 responseStarted，外层不再换 IP。
    private func driveConnection(
        endpoint: NWEndpoint,
        params: NWParameters,
        wireData: Data,
        timeout: TimeInterval,
        method: String
    ) async throws -> Data {
        let queue = DispatchQueue(label: "com.liudehen.xiaoshipin.doh.conn.\(UUID().uuidString)")
        let conn = NWConnection(to: endpoint, using: params)

        /// 完成盒（F1：与 URLSessionRaceBox 同款 pending 设计）：
        /// finish 先于 set 到达时把结果暂存 pending，set 时直接恢复——
        /// 父任务先取消、continuation 后安装也不会永久挂住。
        /// buffer / responseStarted / 计时器都在锁内读写（F24：finish 时
        /// 清 buffer、同时取消 waiting 与超时计时器）。
        final class ConnBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<Data, Error>?
            private var pending: Result<Data, Error>?
            private var done = false
            var connection: NWConnection?
            private var buffer = Data()
            private var waitingTimer: DispatchWorkItem?
            private var timeoutTimer: DispatchWorkItem?
            private var responseStarted = false

            func set(_ c: CheckedContinuation<Data, Error>) {
                lock.lock()
                let result = pending
                if result == nil {
                    cont = c
                }
                lock.unlock()
                if let result {
                    c.resume(with: result)
                }
            }
            func finish(_ result: Result<Data, Error>) {
                lock.lock()
                guard !done else { lock.unlock(); return }
                done = true
                let c = cont; cont = nil
                let cn = connection; connection = nil
                let wt = waitingTimer; waitingTimer = nil
                let tt = timeoutTimer; timeoutTimer = nil
                buffer.removeAll()
                if c == nil {
                    pending = result
                }
                lock.unlock()
                wt?.cancel()
                tt?.cancel()
                cn?.cancel()
                switch result {
                case .success(let d): c?.resume(returning: d)
                case .failure(let e): c?.resume(throwing: e)
                }
            }
            func appendData(_ data: Data) {
                lock.lock()
                // R3-14：finish() 之后迟到的 receive 回调不再往已清的 buffer 里写。
                guard !done else { lock.unlock(); return }
                buffer.append(data)
                lock.unlock()
            }
            func currentBuffer() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return buffer
            }
            func markResponseStarted() {
                lock.lock()
                responseStarted = true
                lock.unlock()
            }
            var isResponseStarted: Bool {
                lock.lock()
                defer { lock.unlock() }
                return responseStarted
            }
            func setWaitingTimer(_ item: DispatchWorkItem?) {
                lock.lock()
                let old = waitingTimer
                let isDone = done
                // R3-14：done 后不再存 item——存下来会形成保留环（box →
                // waitingTimer → item → fail → box），且 finish() 已把字段清成 nil。
                if !isDone { waitingTimer = item }
                lock.unlock()
                old?.cancel()
                if isDone { item?.cancel() }
            }
            func setTimeoutTimer(_ item: DispatchWorkItem?) {
                lock.lock()
                let old = timeoutTimer
                let isDone = done
                // R3-14：同上（超时 item 捕获 fail，fail 捕获 box）。
                if !isDone { timeoutTimer = item }
                lock.unlock()
                old?.cancel()
                if isDone { item?.cancel() }
            }
        }

        let box = ConnBox()
        box.connection = conn
        // .waiting 有界宽限：死 IP/不可达路径会在 waiting 里挂住；给 1.5s
        // 恢复机会，超时仍 waiting 就按等待错误失败，不干等到每跳超时。
        // 注意：waiting 也可能只是瞬时路径恢复，绝不一上来就判失败。
        // 宽限受剩余预算约束（F22：timeout 已是剩余预算）。
        let waitingGraceSeconds: TimeInterval = min(1.5, max(0, timeout))

        // 失败出口（F4）：取消原样抛；别的失败按是否已收到最终响应头包装，
        // 外层（perform 的 IP 循环）看到 responseStarted 就不再换 IP。
        let fail: (Error) -> Void = { error in
            if error is CancellationError {
                box.finish(.failure(error))
            } else {
                box.finish(.failure(DoHTransportFailure(underlying: error, responseStarted: box.isResponseStarted)))
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.set(cont)
                if Task.isCancelled {
                    box.finish(.failure(CancellationError()))
                    return
                }
                func receiveLoop() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            box.appendData(data)
                        }
                        let buf = box.currentBuffer()
                        // F4：缓冲里已出现最终（非 1xx）响应头块即记下。
                        if !box.isResponseStarted,
                           case .finalBlock = Self.skipInterimResponses(in: buf, from: buf.startIndex) {
                            box.markResponseStarted()
                        }
                        let status = DoHFallbackClient.frameStatus(of: buf, method: method)
                        switch status {
                        case .complete(let raw):
                            box.finish(.success(raw))
                            return
                        case .malformed:
                            fail(URLError(.cannotParseResponse))
                            return
                        case .awaitingEOF, .incomplete:
                            break
                        }
                        if isComplete {
                            // EOF：只有 awaitingEOF 的响应到这里算成功；
                            // Content-Length/chunked 没收齐就是截断。
                            if case .awaitingEOF = status {
                                box.finish(.success(buf))
                            } else {
                                fail(URLError(.cannotParseResponse))
                            }
                            return
                        }
                        if let error {
                            // 错误 + 半截 body = 失败，不再把残 buffer 当成功。
                            fail(error)
                            return
                        }
                        receiveLoop()
                    }
                }
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        // 连上了：waiting 宽限计时器作废。
                        box.setWaitingTimer(nil)
                        conn.send(content: wireData, completion: .contentProcessed { sendErr in
                            if let sendErr {
                                fail(sendErr)
                                return
                            }
                            receiveLoop()
                        })
                    case .setup, .preparing:
                        // F14：离开 .waiting 即取消宽限计时器，不只在 .ready 取消——
                        // .waiting → .preparing 恢复中的连接可能在 preparing 里做
                        // TLS 超过 1.5 秒，不能被旧 timer 杀掉。
                        box.setWaitingTimer(nil)
                    case .waiting(let waitError):
                        let item = DispatchWorkItem {
                            fail(waitError)
                        }
                        box.setWaitingTimer(item)
                        queue.asyncAfter(deadline: .now() + waitingGraceSeconds, execute: item)
                    case .failed(let err):
                        fail(err)
                    case .cancelled:
                        box.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                // 总超时：存进 ConnBox，finish 时一起取消（F24）；finish 内部
                // 已取消连接，这里不再单独 conn.cancel()（F34，去掉歧义）。
                let timeoutItem = DispatchWorkItem {
                    fail(URLError(.timedOut))
                }
                box.setTimeoutTimer(timeoutItem)
                queue.asyncAfter(deadline: .now() + max(0, timeout), execute: timeoutItem)
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }

    /// HTTP 帧状态：收到即停的判定（收到完整响应就不再等 TCP 关）。
    private enum HTTPFrameStatus {
        /// 已收齐：exact raw response bytes。
        case complete(Data)
        /// 头已齐、body 靠 EOF 界定：继续收，等连接关。
        case awaitingEOF
        /// 还没收齐（头不全或 body 未满）。
        case incomplete
        /// 头/块结构非法。
        case malformed
    }

    /// 跳过中间响应头块的结果（F21：frameStatus 与 parseHTTP11Response 共用，
    /// 保证两处对 1xx / 101 的行为完全一致）。
    private enum HeaderBlockResult {
        /// 还没收齐一个完整的头块。
        case incomplete
        /// 结构非法（状态行非法 / 101 / 1xx 超限）。
        case malformed
        /// 最终响应头块：块起始位置、头块分隔范围、状态码。
        case finalBlock(blockStart: Data.Index, sep: Range<Data.Index>, code: Int)
    }

    /// 头行解码：先按 UTF-8，失败回退 ISO-Latin-1（F31：Latin-1 对任意字节
    /// 都能解码，所以这里总能返回字符串，不再因非 UTF-8 头行判 malformed）。
    private static func decodeHeaderBlock(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// 从 start 起跳过 1xx 中间响应头块，返回最终响应头块。
    /// 最多跳 5 个 1xx（F21），超了判 malformed；101 是协议升级，不是普通
    /// 中间响应，直接判 malformed（F20）。
    private static func skipInterimResponses(in raw: Data, from start: Data.Index) -> HeaderBlockResult {
        let headerSep = Data("\r\n\r\n".utf8)
        var offset = start
        var skipped = 0
        while true {
            guard let sepRange = raw.range(of: headerSep, in: offset..<raw.endIndex) else {
                return .incomplete
            }
            let headStr = decodeHeaderBlock(raw[offset..<sepRange.lowerBound])
            let lines = headStr.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else { return .malformed }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else { return .malformed }
            if code == 101 { return .malformed }
            if (100...199).contains(code) {
                skipped += 1
                guard skipped <= 5 else { return .malformed }
                offset = sepRange.upperBound
                continue
            }
            return .finalBlock(blockStart: offset, sep: sepRange, code: code)
        }
    }

    /// Transfer-Encoding 是否恰好是纯 chunked（F19）：按逗号拆分、trim、小写
    /// 后精确比对 token；gzip、gzip+chunked、xchunked 等一律不算 chunked。
    private static func transferEncodingIsChunked(_ value: String) -> Bool {
        let codings = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return codings == ["chunked"]
    }

    /// chunk size 行解析（F15）：必须非空且全是十六进制字符（0-9a-fA-F），
    /// 再 Int(..., radix: 16) 且 >= 0。Swift 的 Int(..., radix:) 接受前导
    /// "-"，光靠它会把 "-1" 当成合法尺寸，必须先拦。
    private static func parseChunkSize(_ s: String) -> Int? {
        guard !s.isEmpty,
              s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
              let size = Int(s, radix: 16), size >= 0 else { return nil }
        return size
    }

    /// 对已收到的原始字节做帧判定（纯函数，不动 buffer）。
    /// 1xx 中间响应跳过；HEAD/204/304 只有头；Content-Length 精确字节数；
    /// chunked 到终结 0 块；既无长度又非 chunked 才等 EOF。
    /// 注意：绝不用子串搜索判状态（如 " 204 "、"0\r\n\r\n" 都会误判）——
    /// 状态码按行解析，chunk 按尺寸逐块走。
    private static func frameStatus(of raw: Data, method: String) -> HTTPFrameStatus {
        let crlf = Data("\r\n".utf8)
        let skip = skipInterimResponses(in: raw, from: raw.startIndex)
        guard case .finalBlock(let blockStart, let sepRange, let code) = skip else {
            if case .incomplete = skip { return .incomplete }
            return .malformed
        }
        let headStr = decodeHeaderBlock(raw[blockStart..<sepRange.lowerBound])
        let lines = headStr.components(separatedBy: "\r\n")
        // 最终响应头块：解析帧规则。
        if method.uppercased() == "HEAD" || code == 204 || code == 304 {
            return .complete(Data(raw[..<sepRange.upperBound]))
        }
        var contentLengths: [Int] = []
        var chunked = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if k == "transfer-encoding" {
                // F19：只有恰好 ["chunked"] 才算 chunked，别的编码组合判 malformed。
                guard transferEncodingIsChunked(String(v)) else { return .malformed }
                chunked = true
            } else if k == "content-length" {
                guard let n = Int(v), n >= 0 else { return .malformed }
                contentLengths.append(n)
            }
        }
        let bodyStart = sepRange.upperBound
        if chunked {
            // F29：chunked 时完全忽略 Content-Length（不校验、不因它 malformed）。
            // chunked 优先于 Content-Length（RFC 7230 §3.3.3）。
            return chunkedFrameStatus(body: raw, from: bodyStart, crlf: crlf)
        }
        if let first = contentLengths.first {
            guard contentLengths.allSatisfy({ $0 == first }) else { return .malformed }
            let n = first
            let have = raw.endIndex - bodyStart
            if have >= n {
                let end = raw.index(bodyStart, offsetBy: n)
                return .complete(Data(raw[..<end]))
            }
            return .incomplete
        }
        return .awaitingEOF
    }

    /// chunked 体增量判定：从 bodyStart 起逐块走；收齐终结 0 块 + 空行即
    /// complete，块结构非法即 malformed，缺字节即 incomplete（不等 EOF
    /// 判截断——EOF 时调用方按 incomplete → cannotParseResponse 处理）。
    private static func chunkedFrameStatus(body raw: Data, from bodyStart: Data.Index, crlf: Data) -> HTTPFrameStatus {
        var idx = bodyStart
        while idx < raw.endIndex {
            guard let lineEnd = raw.range(of: crlf, in: idx..<raw.endIndex) else {
                return .incomplete
            }
            let sizeStr = String(decoding: raw[idx..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = parseChunkSize(sizeStr) else {
                return .malformed
            }
            if size == 0 {
                // 终结块：随后是 0 个或多个 trailer 行，以一个空行结束。
                // trailer 行数有上限（F21：最多 32 行，超了判 malformed，
                // 防恶意服务端用超长无终结 trailer 行把 buffer 撑爆）。
                var t = lineEnd.upperBound
                var trailerLines = 0
                while true {
                    guard let le = raw.range(of: crlf, in: t..<raw.endIndex) else {
                        return .incomplete
                    }
                    if le.lowerBound == t {
                        return .complete(Data(raw[..<le.upperBound]))
                    }
                    trailerLines += 1
                    guard trailerLines <= 32 else { return .malformed }
                    t = le.upperBound
                }
            }
            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = raw.index(chunkStart, offsetBy: size, limitedBy: raw.endIndex) else {
                return .incomplete
            }
            guard let afterChunk = raw.index(chunkEnd, offsetBy: 2, limitedBy: raw.endIndex) else {
                return .incomplete
            }
            guard raw[chunkEnd..<afterChunk] == crlf else {
                return .malformed
            }
            idx = afterChunk
        }
        return .incomplete
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
                // R4-6：header 名/值里的 \r、\n 直接去掉——自研 HTTP 栈不像
                // URLSession 会拒这类头，含换行的值会注入换行（header injection）。
                let cleanKey = k.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let cleanValue = v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                let lower = cleanKey.lowercased()
                guard !seen.contains(lower) else { continue }
                seen.insert(lower)
                lines.append("\(cleanKey): \(cleanValue)")
            }
        }
        let body = request.httpBody
        // 有 Data body 时永远补 Content-Length（F30）：请求自带的
        // Transfer-Encoding 头不复制（seen 里已排除），不存在“两个头并存”，
        // 不再因原请求带 TE 头就跳过补 CL。
        if let body {
            lines.append("Content-Length: \(body.count)")
        }
        var out = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { out.append(body) }
        return out
    }

    /// 返回体 + 响应 + 原始 Set-Cookie 头行：多条 Set-Cookie 不能进
    /// [String: String]（后一条盖前一条），原始头行单独留一份给 cookie jar。
    private func parseHTTP11Response(_ raw: Data, url: URL, method: String) throws -> (Data, HTTPURLResponse, [String]) {
        // 1xx 中间响应（100 Continue / 103 Early Hints）会先发一组头：
        // 与 frameStatus 共用 skipInterimResponses（F21），只解析最终响应头。
        let skip = Self.skipInterimResponses(in: raw, from: raw.startIndex)
        guard case .finalBlock(let blockStart, let range, let statusCode) = skip else {
            throw URLError(.cannotParseResponse)
        }
        // R4-15：HEAD/204/304 没有 body（RFC 9110）——跳过 TE 校验、body 直接 Data()。
        let isBodyless = method.uppercased() == "HEAD" || statusCode == 204 || statusCode == 304
        let headStr = Self.decodeHeaderBlock(raw[blockStart..<range.lowerBound])
        let headerLines = headStr.components(separatedBy: "\r\n")
        guard headerLines.first != nil else { throw URLError(.cannotParseResponse) }
        var headerFields: [String: String] = [:]
        var isChunked = false
        var setCookieValues: [String] = []
        for line in headerLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // F19：只有恰好 ["chunked"] 才算 chunked，别的编码组合判 malformed。
            // R4-15：bodyless 响应跳过 TE 校验（frameStatus 已按头完成，不看 TE）。
            if k.lowercased() == "transfer-encoding", !isBodyless {
                guard Self.transferEncodingIsChunked(String(v)) else {
                    throw URLError(.cannotParseResponse)
                }
                isChunked = true
            }
            if k.lowercased() == "set-cookie" {
                setCookieValues.append(String(v))
            }
            headerFields[k] = v
        }
        let rawBody = Data(raw[range.upperBound...])
        let body = isBodyless ? Data() : (isChunked ? try decodeChunked(rawBody) : rawBody)
        guard let httpResp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headerFields) else {
            throw URLError(.cannotParseResponse)
        }
        return (body, httpResp, setCookieValues)
    }

    /// chunked 解码：任何截断（缺尺寸行、尺寸不是十六进制、块体不够长、
    /// 块后缺 CRLF）都 throw，不再悄悄返回半截数据（半截 m3u8/JSON
    /// 下游解析会出怪错，不如直接报解析失败走重试/换线）。
    private func decodeChunked(_ data: Data) throws -> Data {
        var out = Data()
        var idx = data.startIndex
        let crlf = Data("\r\n".utf8)
        // R4-15：见过 size==0 终结块才算完整——没见过终结块、流直接到末尾
        // 是截断，必须 throw（与本函数注释“任何截断都 throw”一致）。
        var sawTerminator = false
        while idx < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: idx..<data.endIndex) else {
                throw URLError(.cannotParseResponse)
            }
            let sizeStr = String(decoding: data[idx..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Self.parseChunkSize(sizeStr) else {
                throw URLError(.cannotParseResponse)
            }
            if size == 0 {
                // 终结块：后面只有 trailer + CRLF，直接收尾。
                sawTerminator = true
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
        guard sawTerminator else { throw URLError(.cannotParseResponse) }
        return out
    }
}
