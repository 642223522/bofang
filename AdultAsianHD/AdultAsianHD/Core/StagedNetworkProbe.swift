import Foundation
import Network
import Security
import WebKit

/// 真机网络探针（Gemini v2 staged probe，改写成回结构化结果供 检测 Tab 展示）：
/// 对给定 host 跑：系统 DNS / 两家 DoH（A/AAAA/HTTPS）→ NWConnection 分段建连
/// （hostname / IPv4 字面量 / IPv6 字面量，带 EstablishmentReport）→
/// URLSession 三档对照（默认 H3 / 禁 H3 / 裸头）→ 干净 WKWebView 同 URL 探针。
/// 不强制 IPv4（NAT64 安全），不改 UA、不注脚本、不碰挑战流程，只观测。
/// 每个子探针都有超时；整轮跑在后台 Task 里，取消即停、结果分段回填 UI。
/// 调用方在 DiagnosticsView（检测 Tab）里起 Task 跑它，onLine 每出一行就刷新列表。
final class StagedNetworkProbe: NSObject {

    /// 一行探针结果（UI 直接展示）。
    struct ProbeLine: Identifiable {
        let id = UUID()
        let stage: ProbeStage
        let label: String
        let detail: String
        /// true 通 / false 断 / nil 仅信息（如 metrics 明细）。
        let ok: Bool?
    }

    enum ProbeStage: String {
        case dns = "DNS"
        case tcp = "TCP"
        case tls = "TLS"
        case http = "HTTP"
        case waf = "WAF"
        case webview = "WebView"
        case info = "信息"
    }

    /// 一次探针的目标：API 根 URL（必填）+ 嵌页 URL（可选）。
    struct ProbeTarget {
        let name: String
        let apiURL: URL
        let embedURL: URL?
    }

    /// 默认跑的两个站（无节点时列表/播放都失败的站；pornjav 直连能播，不用探）。
    static let defaultTargets: [ProbeTarget] = [
        ProbeTarget(name: "黄果", apiURL: URL(string: "https://huangguoai.com")!, embedURL: nil),
        ProbeTarget(name: "onlybokep", apiURL: URL(string: "https://onlybokep.cam")!, embedURL: nil),
    ]

    /// 每出一行探针结果就调一次（调用方在里面跳回 MainActor 写 UI）。
    /// 探针只在后台 Task 里跑，onLine 在各子探针的回调线程上触发。
    var onLine: ((ProbeLine) -> Void)?

    private func emit(_ line: ProbeLine) {
        onLine?(line)
    }

    /// 跑一个站点的完整探针（分段出结果；取消即停，返回前已出的行也保留）。
    func run(target: ProbeTarget) async {
        emit(ProbeLine(stage: .info, label: target.name, detail: "开始探针 \(target.apiURL.host ?? "")", ok: nil))
        var hosts = [target.apiURL.host].compactMap { $0 }
        if let eHost = target.embedURL?.host, !hosts.contains(eHost) { hosts.append(eHost) }
        hosts.append("challenges.cloudflare.com")

        for host in hosts {
            if Task.isCancelled { return }
            emit(ProbeLine(stage: .info, label: "HOST", detail: host, ok: nil))

            // 1. 系统 DNS（异步 getaddrinfo，可取消、5 秒超时，不卡死 Swift 并发池）。
            let sys = await resolveSystemDNS(host: host)
            emit(ProbeLine(
                stage: .dns,
                label: "DNS[System]",
                detail: "latency=\(sys.latencyMs)ms A=\(sys.v4) AAAA=\(sys.v6)",
                ok: !sys.v4.isEmpty || !sys.v6.isEmpty
            ))

            // 1b. 两家 DoH（IP 字面量，不走系统 DNS）× A / AAAA / HTTPS(65)。
            for (name, base) in [("AliDoH", "https://223.5.5.5/resolve"), ("CFDoH", "https://1.1.1.1/dns-query")] {
                for qtype in ["A", "AAAA", "HTTPS"] {
                    if Task.isCancelled { return }
                    let rec = await resolveDoH(resolver: name, endpoint: base, host: host, qtype: qtype)
                    let ok = rec.error == nil && !rec.records.isEmpty
                    emit(ProbeLine(
                        stage: .dns,
                        label: "DNS[\(rec.resolver) \(rec.qtype)]",
                        detail: "\(rec.latencyMs)ms cname=\(rec.cnames) ans=\(rec.records.map { "\($0.value)(TTL \($0.ttl))" }) err=\(rec.error ?? "none")",
                        ok: ok
                    ))
                }
            }

            // 2. NWConnection 分段建连：hostname（Happy Eyeballs）/ IPv4 字面量 / IPv6 字面量。
            if Task.isCancelled { return }
            emit(await probeNWStaged(connectHost: host, sni: host, port: 443, label: "Hostname(HE)"))
            if let v4 = sys.v4.first {
                if Task.isCancelled { return }
                emit(await probeNWStaged(connectHost: v4, sni: host, port: 443, label: "IPv4Literal(\(v4))"))
            }
            if let v6 = sys.v6.first {
                if Task.isCancelled { return }
                emit(await probeNWStaged(connectHost: v6, sni: host, port: 443, label: "IPv6Literal(\(v6))"))
            }
        }

        // 3. URLSession 三档对照：默认（H3 允许）/ 禁 H3 / 裸头。
        if Task.isCancelled { return }
        emit(ProbeLine(stage: .info, label: target.name, detail: "URLSession 对照：默认 H3 / 禁 H3 / 裸头", ok: nil))
        emit(await probeURLSession(url: target.apiURL, ua: NetConstants.iPhoneUserAgent, referer: target.apiURL.absoluteString, allowH3: true, label: "API_Default_H3Allowed"))
        if Task.isCancelled { return }
        emit(await probeURLSession(url: target.apiURL, ua: NetConstants.iPhoneUserAgent, referer: target.apiURL.absoluteString, allowH3: false, label: "API_H3Disabled"))
        if Task.isCancelled { return }
        emit(await probeURLSession(url: target.apiURL, ua: nil, referer: nil, allowH3: true, label: "API_BareDefaultHeaders"))
        if let embedURL = target.embedURL {
            if Task.isCancelled { return }
            emit(await probeURLSession(url: embedURL, ua: NetConstants.iPhoneUserAgent, referer: target.apiURL.absoluteString, allowH3: true, label: "Embed_Default"))
        }

        // 4. 干净 WKWebView 同 URL 探针（不改 UA、不注脚本，只看能不能加载）。
        if Task.isCancelled { return }
        emit(await probeCleanWKWebView(url: target.apiURL))
        emit(ProbeLine(stage: .info, label: target.name, detail: "探针结束", ok: nil))
    }

    // MARK: - 1. System DNS with timing
    /// 可取消、带 5s 超时的系统 DNS 解析（不卡死 Swift 并发池）：
    /// getaddrinfo 是同步阻塞调用，放后台全局队列跑；5 秒没回就按空结果收尾，
    /// 取消时也一样收尾（不留挂起的 continuation）。
    private func resolveSystemDNS(host: String) async -> (latencyMs: Int, v4: [String], v6: [String]) {
        let start = CFAbsoluteTimeGetCurrent()
        final class DNSBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cont: CheckedContinuation<(latencyMs: Int, v4: [String], v6: [String]), Never>?
            private var done = false
            func set(_ c: CheckedContinuation<(latencyMs: Int, v4: [String], v6: [String]), Never>) {
                lock.lock(); defer { lock.unlock() }
                if done { c.resume(returning: (0, [], [])) } else { cont = c }
            }
            func finish(_ val: (latencyMs: Int, v4: [String], v6: [String])) {
                lock.lock()
                guard !done else { lock.unlock(); return }
                done = true
                let c = cont; cont = nil
                lock.unlock()
                c?.resume(returning: val)
            }
        }
        let box = DNSBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                box.set(cont)
                if Task.isCancelled {
                    box.finish((Int((CFAbsoluteTimeGetCurrent() - start) * 1000), [], []))
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo(
                        ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                        ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
                    )
                    var res: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                        box.finish((Int((CFAbsoluteTimeGetCurrent() - start) * 1000), [], []))
                        return
                    }
                    defer { freeaddrinfo(res) }
                    var v4: [String] = []
                    var v6: [String] = []
                    var ptr: UnsafeMutablePointer<addrinfo>? = first
                    while let cur = ptr {
                        if cur.pointee.ai_family == AF_INET, let addr = cur.pointee.ai_addr {
                            var s = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            if inet_ntop(AF_INET, &s, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                                let ip = String(cString: buf)
                                if !v4.contains(ip) { v4.append(ip) }
                            }
                        } else if cur.pointee.ai_family == AF_INET6, let addr = cur.pointee.ai_addr {
                            var s6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                            if inet_ntop(AF_INET6, &s6, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                                let ip = String(cString: buf)
                                if !v6.contains(ip) { v6.append(ip) }
                            }
                        }
                        ptr = cur.pointee.ai_next
                    }
                    box.finish((Int((CFAbsoluteTimeGetCurrent() - start) * 1000), v4, v6))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    box.finish((Int((CFAbsoluteTimeGetCurrent() - start) * 1000), [], []))
                }
            }
        } onCancel: {
            box.finish((Int((CFAbsoluteTimeGetCurrent() - start) * 1000), [], []))
        }
    }

    // MARK: - 1b. IP-Literal DoH Query (A / AAAA / HTTPS=65)
    private struct DNSAnswerRecord {
        let resolver: String
        let qtype: String
        let latencyMs: Int
        let cnames: [String]
        let records: [(value: String, ttl: Int)]
        let error: String?
    }

    private func resolveDoH(resolver: String, endpoint: String, host: String, qtype: String) async -> DNSAnswerRecord {
        let start = CFAbsoluteTimeGetCurrent()
        guard var comps = URLComponents(string: endpoint) else {
            return DNSAnswerRecord(resolver: resolver, qtype: qtype, latencyMs: 0, cnames: [], records: [], error: "bad_url")
        }
        comps.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: qtype)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 4)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, _) = try await session.data(for: req)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return DNSAnswerRecord(resolver: resolver, qtype: qtype, latencyMs: ms, cnames: [], records: [], error: "bad_json")
            }
            let answers = (json["Answer"] as? [[String: Any]]) ?? []
            let wantType: Int = (qtype == "A") ? 1 : (qtype == "AAAA" ? 28 : 65)
            var cnames: [String] = []
            var recs: [(String, Int)] = []
            for a in answers {
                let t = a["type"] as? Int ?? -1
                let val = a["data"] as? String ?? ""
                let ttl = a["TTL"] as? Int ?? -1
                if t == 5 { cnames.append(val) }
                else if t == wantType { recs.append((val, ttl)) }
            }
            return DNSAnswerRecord(resolver: resolver, qtype: qtype, latencyMs: ms, cnames: cnames, records: recs, error: nil)
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return DNSAnswerRecord(resolver: resolver, qtype: qtype, latencyMs: ms, cnames: [], records: [], error: "\((error as NSError).code)")
        }
    }

    // MARK: - 2. Staged NWConnection + EstablishmentReport (TCP + TLS)
    private func probeNWStaged(connectHost: String, sni: String, port: UInt16, label: String) async -> ProbeLine {
        let tlsOpts = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOpts.securityProtocolOptions, sni)
        sec_protocol_options_add_tls_application_protocol(tlsOpts.securityProtocolOptions, "h2")
        sec_protocol_options_add_tls_application_protocol(tlsOpts.securityProtocolOptions, "http/1.1")

        // NOTE: Do NOT force ipOpts.version = .v4; allow OS NAT64 synthesis when connecting to IPv4 literals.
        let params = NWParameters(tls: tlsOpts, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: NWEndpoint.Host(connectHost), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let q = DispatchQueue(label: "probe.nw.\(UUID().uuidString)")
        let start = CFAbsoluteTimeGetCurrent()
        let box = NWProbeBox()
        box.connection = conn

        let summary = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                box.setContinuation(cont)
                // 任务进函数时已取消：onCancel 可能在 continuation 存进去之前就跑，
                // 存进去后要再查一次，抢在建连前收尾。resumeOnce 失败说明 onCancel
                // 先跑了（它 take 时盒子还是空的，没 resume 到）：直接把这次存进去的
                // continuation 取出来 resume，finish 那边也被 done 拦着，不会重复。
                if Task.isCancelled {
                    if !box.resumeOnce("\(label) | CANCELLED") {
                        box.takeContinuation()?.resume(returning: "\(label) | CANCELLED")
                    }
                    return
                }
                var stageHistory: [String] = []
                let finish: (String) -> Void = { summary in
                    _ = box.resumeOnce("\(label) | \(summary) | trace=[\(stageHistory.joined(separator: " -> "))]")
                }
                conn.stateUpdateHandler = { state in
                    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    switch state {
                    case .preparing:
                        stageHistory.append("preparing@\(ms)ms")
                    case .waiting(let err):
                        stageHistory.append("waiting(\(err))@\(ms)ms")
                    case .ready:
                        stageHistory.append("ready@\(ms)ms")
                        let remoteDesc = conn.currentPath?.remoteEndpoint.map { "\($0)" } ?? "unknown"
                        conn.requestEstablishmentReport(queue: q) { report in
                            guard let report else {
                                finish("READY remote=\(remoteDesc) total=\(ms)ms report=nil")
                                return
                            }
                            let resStr = report.resolutions.map { r in
                                "src=\(r.source) dur=\(Int(r.duration * 1000))ms cnt=\(r.endpointCount)"
                            }.joined(separator: "; ")
                            let hsStr = report.handshakes.map { h in
                                "\(h.definition.name):dur=\(Int(h.handshakeDuration * 1000))ms,rtt=\(Int(h.handshakeRTT * 1000))ms"
                            }.joined(separator: "; ")
                            finish("READY remote=\(remoteDesc) est=\(Int(report.duration * 1000))ms proxy=\(report.usedProxy) res=[\(resStr)] hs=[\(hsStr)]")
                        }
                    case .failed(let err):
                        stageHistory.append("failed(\(err))@\(ms)ms")
                        // TLS 失败单独打标记：最终按 .tls 归类，不再跟 TCP 失败混在一起。
                        if case .tls = err {
                            finish("FAILED_TLS(\(err))")
                        } else {
                            finish("FAILED(\(err))")
                        }
                    default:
                        break
                    }
                }
                conn.start(queue: q)
                q.asyncAfter(deadline: .now() + 8) {
                    finish("TIMEOUT@8000ms")
                }
            }
        } onCancel: {
            box.resumeOnce("\(label) | CANCELLED")
        }

        if summary.contains("READY") {
            return ProbeLine(stage: .tls, label: "NW[\(label)]", detail: summary, ok: true)
        }
        if summary.contains("CANCELLED") {
            return ProbeLine(stage: .info, label: "NW[\(label)]", detail: summary, ok: false)
        }
        if summary.contains("FAILED_TLS") {
            return ProbeLine(stage: .tls, label: "NW[\(label)]", detail: summary, ok: false)
        }
        return ProbeLine(stage: .tcp, label: "NW[\(label)]", detail: summary, ok: false)
    }

    // MARK: - 3. Staged URLSession Probe (Default vs H3 Disabled)
    /// 每请求一个 metrics delegate：label 跟着这次请求走，不再用共享
    /// currentMetricsLabel（串行探针也可能被取消/重入，共享 label 会张冠李戴）。
    private final class ProbeMetricsDelegate: NSObject, URLSessionDataDelegate {
        let label: String
        weak var probe: StagedNetworkProbe?

        init(label: String, probe: StagedNetworkProbe) {
            self.label = label
            self.probe = probe
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let probe else { return }
            for m in metrics.transactionMetrics {
                let d = { (a: Date?, b: Date?) -> String in
                    guard let a, let b else { return "nil" }
                    return "\(Int(b.timeIntervalSince(a) * 1000))ms"
                }
                let detail = "proto=\(m.networkProtocolName ?? "nil") remote=\(m.remoteAddress ?? "nil"):\(m.remotePort ?? 0) DNS=\(d(m.domainLookupStartDate, m.domainLookupEndDate)) TCP=\(d(m.connectStartDate, m.connectEndDate)) TLS=\(d(m.secureConnectionStartDate, m.secureConnectionEndDate)) TTFB=\(d(m.requestStartDate, m.responseStartDate))"
                probe.emit(ProbeLine(stage: .tcp, label: "[Metrics \(label)]", detail: detail, ok: nil))
            }
        }
    }

    private func probeURLSession(url: URL, ua: String?, referer: String?, allowH3: Bool, label: String) async -> ProbeLine {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 12
        let metricsDelegate = ProbeMetricsDelegate(label: label, probe: self)
        let session = URLSession(configuration: cfg, delegate: metricsDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: url)
        req.assumesHTTP3Capable = allowH3
        if let ua { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (data, resp) = try await session.data(for: req)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? -1
            let altSvc = http?.value(forHTTPHeaderField: "alt-svc") ?? "-"
            let cfRay = http?.value(forHTTPHeaderField: "cf-ray") ?? "-"
            let cfMit = http?.value(forHTTPHeaderField: "cf-mitigated") ?? "-"
            let body = String(data: data.prefix(220), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<binary \(data.count)B>"
            let isWAF = cfMit.lowercased().contains("challenge") || status == 403 || status == 429 || status == 503
            let detail = "HTTP \(status) (\(elapsed)ms) cf-ray=\(cfRay) cf-mit=\(cfMit) alt-svc=\(altSvc) body: \(body)"
            if isWAF {
                return ProbeLine(stage: .waf, label: "[\(label)]", detail: detail, ok: false)
            }
            return ProbeLine(stage: .http, label: "[\(label)]", detail: detail, ok: (200...299).contains(status))
        } catch {
            let ns = error as NSError
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let detail = "ERR (\(elapsed)ms) domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)"
            return ProbeLine(stage: .http, label: "[\(label)]", detail: detail, ok: false)
        }
    }

    // MARK: - 4. Clean WKWebView Probe (Zero UA spoofing, zero script injection)
    @MainActor
    private func probeCleanWKWebView(url: URL) async -> ProbeLine {
        let cfg = WKWebViewConfiguration()
        // 不用 .default() 持久 store：探针的 cookie/缓存不污染正常浏览，
        // 也不让上次探针的 CF 状态影响这次结果。
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = nil

        final class Loader: NSObject, WKNavigationDelegate, @unchecked Sendable {
            var cont: CheckedContinuation<String, Never>?
            var done = false
            func finish(_ text: String) {
                guard !done else { return }
                done = true
                cont?.resume(returning: text)
                cont = nil
            }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 200) : ''") { val, _ in
                    self.finish("LOADED snippet=\((val as? String ?? "").replacingOccurrences(of: "\n", with: " "))")
                }
            }
            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                let ns = error as NSError
                self.finish("PROVISIONAL_FAIL code=\(ns.code) \(ns.localizedDescription)")
            }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                let ns = error as NSError
                self.finish("NAV_FAIL code=\(ns.code) \(ns.localizedDescription)")
            }
        }

        let loader = Loader()
        wv.navigationDelegate = loader
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                loader.cont = cont
                wv.load(URLRequest(url: url, timeoutInterval: 15))
                // 20 秒看门狗：挑战页/挂起的加载不会永远等下去（原版没有超时，会永久挂住）。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    loader.finish("TIMEOUT@20000ms（页面 20 秒未加载完）")
                }
            }
        } onCancel: {
            // 取消即停加载，不只 finish：不调 stopLoading 的话 WebView 还在后台
            // 跑，下一轮探针的结果会跟这轮的串在一起。
            Task { @MainActor in
                wv.stopLoading()
                loader.finish("CANCELLED")
            }
        }
        let ok = result.hasPrefix("LOADED")
        return ProbeLine(stage: .webview, label: "WKWebView[Clean]", detail: result, ok: ok)
    }
}

/// NW 探针的 continuation 盒子：onCancel 可能在 continuation 存进去之前跑，
/// 存进去后要再查一次 Task.isCancelled（与 WidgetHost.awaitPromiseRaw 同款处理）。
/// resumeOnce 只成功一次（锁 + done 标志），同时断开连接。
private final class NWProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    var connection: NWConnection?
    private var done = false

    func setContinuation(_ continuation: CheckedContinuation<String, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    /// 取出存着的 continuation（并清空）：onCancel 先跑、resumeOnce 已被占时，
    /// 调用方用它直接 resume 这次存进去的 continuation，不会重复。
    func takeContinuation() -> CheckedContinuation<String, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }

    @discardableResult
    func resumeOnce(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: value)
        continuation = nil
        return true
    }
}
