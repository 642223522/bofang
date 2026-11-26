import CryptoKit
import CFNetwork
import Foundation

// MARK: - 请求账本（Playback Ledger）+ 路由不匹配记录 + 路线记忆
//
// 一次播放尝试 = 一条账本：期望账本（宿主改写过、指望 AVPlayer 去取的 URL，
// 每个带唯一短 token）对实际账本（拦截器/代理真实收到的请求 + 上游状态）。
// 终局时按三路判定（Claude Q5 定稿）：
//   bypassed（被绕过）—— errorLog 指向的 URL 与期望账本里某一项同 host+路径模板，
//     且它不是回环/拦截器地址：宿主改写过它，AVPlayer 却直接去取了原始 https 地址；
//   rejectedUpstream（上游拒绝）—— 请求经代理/拦截器到了上游，上游回了 4xx/5xx；
//   avPlayerRejected（播放器拒收）—— 代理/拦截器拿到了 2xx，播放仍失败。
// 隐私铁律：账本只记 host + 路径模板哈希（去 query、去 token），不记 token、
// Cookie、完整 URL。errorLog 的 URI 进账本前也只存 host + 模板哈希。
//
// Q5 路由表（证据优先）：内容事实（首响应状态、重定向落点、首字节签名）
//   > URL 形态 > hint > 默认。hint 只调梯子方向与升级 P 的先验，绝不强制指定播放器。
// hint 与内容/形态不一致即记一条不匹配记录（诊断用，字段见 RouteMismatch）。
//
// 路线记忆：同一（模块 + host + URL 模板哈希 + hint + 网络类）走通过的起手路线，
// 下次直接用它起手，7 天内有效；只有分层明确的失败才累计，累计 2 次一致失败才过期；
// 分层不明绝不写（避免把偶然失败记成路线）。

/// 账本里一条请求的资源种类（代理与拦截器共用）。
enum BookKind: String {
    case playlist
    case variant
    case key
    case segment
    case map
}

/// 账本里的一条请求（期望/实际共用）：token 只存前 8 位（对账用），
/// URL 只存 host + 路径模板哈希（去 query、去 token）。
struct LedgerBookEntry: Identifiable {
    let id = UUID()
    let token: String
    let kind: BookKind
    let host: String
    let pathTemplateHash: String
    var upstreamStatus: Int?
    var bytes: Int?
    var servedFromCache: Bool

    var kindLabel: String {
        switch kind {
        case .playlist: return "播单"
        case .variant: return "变体"
        case .key: return "密钥"
        case .segment: return "分片"
        case .map: return "MAP"
        }
    }

    var statusLabel: String {
        guard let upstreamStatus else { return "未收到" }
        return "\(upstreamStatus)"
    }
}

/// 播放尝试走到哪一阶段（账本 stage：list / mint / manifest / key / first-segment / playing）。
enum LedgerStage: String {
    case list
    case mint
    case manifest
    case key
    case firstSegment
    case playing

    var label: String {
        switch self {
        case .list: return "列表"
        case .mint: return "现铸"
        case .manifest: return "播单"
        case .key: return "密钥"
        case .firstSegment: return "首分片"
        case .playing: return "播放中"
        }
    }
}

/// 三路判定（见文件头）。
enum LedgerVerdict: String {
    case ok
    case bypassed
    case rejectedUpstream
    case avPlayerRejected
    case failedOther
    case unknown

    var label: String {
        switch self {
        case .ok: return "正常"
        case .bypassed: return "被绕过（拦截未命中）"
        case .rejectedUpstream: return "上游拒绝（4xx/5xx）"
        case .avPlayerRejected: return "播放器拒收响应"
        case .failedOther: return "其他失败"
        case .unknown: return "未判定"
        }
    }
}

/// 一次播放尝试的账本记录（内存里最多 20 条，旧的自然淘汰）。
struct LedgerAttempt: Identifiable {
    let id: UUID
    let startedAt: Date
    let moduleId: String
    let itemId: String
    let lineHost: String
    let lineTemplateHash: String
    let hint: String
    /// 本次尝试时的网络类：direct（直连，没开节点）/ proxy（系统代理或 VPN 隧道开着）。
    /// 账本传上码云后，靠它区分“没开节点所以失败”和“站真坏了”。
    let networkClass: String
    /// 播放时刻现铸过（账本 stage 用；现铸过的失败至少走到 mint）。
    let recastAtPlay: Bool
    /// 试过的引擎（按顺序，连续重复去重）。
    var ladder: [PlayerEngine] = []
    var stageReached: LedgerStage = .list
    var expected: [LedgerBookEntry] = []
    var actual: [LedgerBookEntry] = []
    var verdict: LedgerVerdict = .unknown
    var outcome: String = ""
    /// errorLog 的 URI（只存 host + 模板哈希，不存原串）。
    var errorURIHost: String?
    var errorURIHash: String?
    var serverAddress: String?
    var addressChanges: Int = 0
    /// 改写后残留的非回环绝对 URL 个数（代理 lint 计数）。
    var rewriteGaps: Int = 0
    var finalized: Bool = false
}

/// 不匹配种类（Q5：hint 与内容/形态不一致即记）。
enum MismatchKind: String {
    case none
    case hintVsForm
    case hintVsContent
    case formVsContent
    case hintAbsent
    case hintUnknown

    var label: String {
        switch self {
        case .none: return "无不匹配"
        case .hintVsForm: return "hint 与 URL 形态不符"
        case .hintVsContent: return "hint 与内容事实不符"
        case .formVsContent: return "URL 形态与内容事实不符"
        case .hintAbsent: return "无 hint（按形态/内容判）"
        case .hintUnknown: return "未知 hint"
        }
    }
}

/// 一条路由不匹配记录（内存里最多 50 条；host + 路径模板哈希，不记 token/Cookie）。
/// sniff / mismatch / outcome / ladderSteps 在终局时补上（路由时只知道 hint 与形态）。
struct RouteMismatch: Identifiable {
    let id = UUID()
    let at: Date
    let moduleId: String
    let itemId: String
    let hintDeclared: String
    let urlForm: String
    var sniff: String
    let evidenceUsed: String
    let decision: String
    var mismatch: MismatchKind
    var ladderSteps: [String]
    var outcome: String
}

/// 路线记忆的键（模块 + host + URL 模板哈希 + hint + 网络类）。
struct RouteMemoryKey: Hashable {
    let moduleId: String
    let host: String
    let urlTemplateHash: String
    let hint: String
    let networkClass: String
}

/// 路线记忆的值：走通的起手路线 + 身份配方 + 嗅探类型 + 置信度 + 验证时间 + 连续失败数。
struct RouteMemoryEntry {
    var firstRoute: PlayerEngine
    var identityRecipe: String
    var sniffType: String
    var confidence: Double
    var lastVerified: Date
    var consecutiveFailures: Int
}

/// 节点状态检测（只做标签，不影响播放与路由）：
/// Shadowrocket 开节点有两种形态——代理模式改系统 HTTP 代理，VPN 模式建 utun 虚拟网卡；
/// 两个都查，任一命中即判为代理。查不到/出错时按直连记（宁可漏标，不可误标）。
enum NetworkState {
    static func currentNetworkClass() -> String {
        if hasSystemProxy() || hasTunnelInterface() { return "proxy" }
        return "direct"
    }

    static func hasSystemProxy() -> Bool {
        // CFNetworkCopySystemProxySettings 是 Copy 系函数，返回 Unmanaged<CFDictionary>?，
        // 必须 takeRetainedValue() 拿到字典再桥接——直接 as? [String: Any] 永远失败（编译警告已点明）。
        guard let raw = CFNetworkCopySystemProxySettings() else { return false }
        let proxies = raw.takeRetainedValue() as NSDictionary
        // kCFNetworkProxiesHTTPEnable 在 iOS 上可用；kCFNetworkProxiesHTTPSEnable 是 macOS 专属（NA），
        // iOS 上不能引用这个常量——HTTPS 那项改用字符串键查（iOS 的代理字典里同样有这个键）。
        let httpOn = (proxies[kCFNetworkProxiesHTTPEnable as String] as? NSNumber)?.intValue == 1
        let httpsOn = (proxies["HTTPSEnable"] as? NSNumber)?.intValue == 1
        return httpOn || httpsOn
    }

    static func hasTunnelInterface() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let name = String(cString: node.pointee.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") {
                return true
            }
            cursor = node.pointee.ifa_next
        }
        return false
    }
}

@MainActor
final class PlaybackLedger: ObservableObject {

    static let shared = PlaybackLedger()

    static let maxAttempts = 20
    static let maxMismatches = 50
    static let maxRouteMemoryEntries = 100
    /// 路线记忆有效期（7 天）；过期即失效（下次重走梯子重新验证）。
    static let routeMemoryTTL: TimeInterval = 7 * 24 * 3600

    @Published private(set) var attempts: [LedgerAttempt] = []
    @Published private(set) var mismatches: [RouteMismatch] = []
    private var routeMemory: [RouteMemoryKey: RouteMemoryEntry] = [:]

    /// 当前网络类（路线记忆的键的一部分）：直连 / 代理，按本次播放时的实际网络定。
    /// 代理 = 系统配了 HTTP(S) 代理，或存在 utun/ppp/ipsec 虚拟网卡（如 Shadowrocket 节点开着）。
    /// 每次读都现测（节点开关会变）；nonisolated：代理（非 MainActor）也要读它。
    nonisolated static var networkClass: String { NetworkState.currentNetworkClass() }

    private init() {}

    var routeMemoryCount: Int { routeMemory.count }

    // MARK: - 模板哈希（隐私：去 query、去 token，只剩 host + 路径的 SHA-256 前 12 位）

    /// URL → 稳定模板哈希：host + 去 query/fragment 的路径，SHA-256 前 12 位十六进制。
    /// 同一线路的同一类 URL（不同签名 token）哈希相同；不同路径哈希不同。
    /// 纯函数，nonisolated：代理（非 MainActor）也要算它。
    nonisolated static func templateHash(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "invalid" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let template = host + (components?.path ?? "")
        let digest = SHA256.hash(data: Data(template.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // MARK: - 播放尝试

    func beginAttempt(moduleId: String, itemId: String, lineURL: String, hint: String, recastAtPlay: Bool) -> UUID {
        let id = UUID()
        let attempt = LedgerAttempt(
            id: id,
            startedAt: Date(),
            moduleId: moduleId,
            itemId: itemId,
            lineHost: URL(string: lineURL)?.host ?? "",
            lineTemplateHash: Self.templateHash(for: lineURL),
            hint: hint,
            networkClass: Self.networkClass,
            recastAtPlay: recastAtPlay
        )
        attempts.insert(attempt, at: 0)
        if attempts.count > Self.maxAttempts {
            attempts.removeLast()
        }
        return id
    }

    /// 梯子每走一级记一级（连续重复去重）。
    func noteEngine(_ engine: PlayerEngine, attemptId: UUID) {
        guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
        if attempts[index].ladder.last != engine {
            attempts[index].ladder.append(engine)
        }
    }

    /// 合并期望/实际账本（按 token 去重；终局时由 ViewModel 从拦截器/代理取快照后调）。
    func mergeBooks(expected: [LedgerBookEntry], actual: [LedgerBookEntry], attemptId: UUID) {
        guard let index = attempts.firstIndex(where: { $0.id == attemptId }) else { return }
        for entry in expected where !attempts[index].expected.contains(where: { $0.token == entry.token && $0.kind == entry.kind }) {
            attempts[index].expected.append(entry)
        }
        for entry in actual where !attempts[index].actual.contains(where: { $0.token == entry.token && $0.kind == entry.kind }) {
            attempts[index].actual.append(entry)
        }
    }

    /// 终局：定 stage、定三路判定、记播放器日志（errorLog URI 只存 host + 模板哈希）。
    /// 已终局的尝试再次终局是空操作（markPlaying 可能被多次触发）。
    func finalizeAttempt(
        _ id: UUID,
        outcome: String,
        playedOK: Bool,
        errorURI: String?,
        serverAddress: String?,
        addressChanges: Int,
        rewriteGaps: Int
    ) {
        guard let index = attempts.firstIndex(where: { $0.id == id }) else { return }
        guard !attempts[index].finalized else { return }
        var attempt = attempts[index]
        if playedOK {
            attempt.stageReached = .playing
        } else if attempt.actual.contains(where: { $0.kind == .segment }) {
            attempt.stageReached = .firstSegment
        } else if attempt.actual.contains(where: { $0.kind == .key }) {
            attempt.stageReached = .key
        } else if attempt.actual.contains(where: { $0.kind == .playlist || $0.kind == .variant }) {
            attempt.stageReached = .manifest
        } else if attempt.recastAtPlay {
            attempt.stageReached = .mint
        } else {
            attempt.stageReached = .list
        }
        attempt.verdict = Self.computeVerdict(expected: attempt.expected, actual: attempt.actual, errorURI: errorURI, playedOK: playedOK)
        attempt.outcome = outcome
        attempt.errorURIHost = errorURI.flatMap { URL(string: $0)?.host }
        attempt.errorURIHash = errorURI.map { Self.templateHash(for: $0) }
        attempt.serverAddress = serverAddress
        attempt.addressChanges = addressChanges
        attempt.rewriteGaps = rewriteGaps
        attempt.finalized = true
        attempts[index] = attempt
    }

    /// 三路判定（见文件头）：绕过 > 上游拒绝 > 播放器拒收 > 其他 > 未判定。
    static func computeVerdict(expected: [LedgerBookEntry], actual: [LedgerBookEntry], errorURI: String?, playedOK: Bool) -> LedgerVerdict {
        if playedOK { return .ok }
        // 绕过：errorLog 指向的 URL 与期望账本里某一项同 host+路径模板，
        // 且它不是回环/拦截器地址（即 AVPlayer 直接取了原始 https 地址）。
        if let errorURI, let errorURL = URL(string: errorURI),
           (errorURL.scheme == "http" || errorURL.scheme == "https"),
           errorURL.host != "127.0.0.1" {
            let hash = templateHash(for: errorURI)
            if expected.contains(where: { $0.pathTemplateHash == hash }) {
                return .bypassed
            }
        }
        if actual.contains(where: { ($0.upstreamStatus ?? 0) >= 400 }) {
            return .rejectedUpstream
        }
        if actual.contains(where: {
            let status = $0.upstreamStatus ?? 0
            return status >= 200 && status < 300
        }) {
            return .avPlayerRejected
        }
        if !actual.isEmpty || errorURI != nil {
            return .failedOther
        }
        return .unknown
    }

    // MARK: - 路由不匹配

    func recordMismatch(_ mismatch: RouteMismatch) {
        mismatches.insert(mismatch, at: 0)
        if mismatches.count > Self.maxMismatches {
            mismatches.removeLast()
        }
    }

    /// 终局时把路由时记的不匹配记录补上：outcome、嗅探结果、完整梯子；
    /// kind 传 nil 表示不改（路由时已定的 hint_vs_form 之类不动）。
    func updateMismatch(id: UUID, outcome: String, sniff: String, ladderSteps: [String], kind: MismatchKind?) {
        guard let index = mismatches.firstIndex(where: { $0.id == id }) else { return }
        mismatches[index].outcome = outcome
        mismatches[index].sniff = sniff
        mismatches[index].ladderSteps = ladderSteps
        if let kind {
            mismatches[index].mismatch = kind
        }
    }

    // MARK: - 路线记忆

    /// 取缓存的起手路线：存在、7 天内验证过、连续失败 < 2 次才返回。
    func cachedRoute(moduleId: String, host: String, urlTemplateHash: String, hint: String, networkClass: String) -> PlayerEngine? {
        let key = RouteMemoryKey(moduleId: moduleId, host: host, urlTemplateHash: urlTemplateHash, hint: hint, networkClass: networkClass)
        guard let entry = routeMemory[key] else { return nil }
        guard entry.consecutiveFailures < 2 else { return nil }
        guard Date().timeIntervalSince(entry.lastVerified) < Self.routeMemoryTTL else { return nil }
        return entry.firstRoute
    }

    /// 走通了：记（或刷新）路线记忆，置信度 1.0，失败数清零。
    func recordRouteSuccess(key: RouteMemoryKey, firstRoute: PlayerEngine, identityRecipe: String, sniffType: String) {
        routeMemory[key] = RouteMemoryEntry(
            firstRoute: firstRoute,
            identityRecipe: identityRecipe,
            sniffType: sniffType,
            confidence: 1.0,
            lastVerified: Date(),
            consecutiveFailures: 0
        )
        if routeMemory.count > Self.maxRouteMemoryEntries {
            if let oldest = routeMemory.min(by: { $0.value.lastVerified < $1.value.lastVerified })?.key {
                routeMemory.removeValue(forKey: oldest)
            }
        }
    }

    /// 失败了：只有分层明确（clearClass）才累计；累计 2 次一致失败即过期删除。
    /// 分层不明时不写——避免把偶然失败记成路线。
    func recordRouteFailure(key: RouteMemoryKey, clearClass: Bool) {
        guard clearClass, var entry = routeMemory[key] else { return }
        entry.consecutiveFailures += 1
        if entry.consecutiveFailures >= 2 {
            routeMemory.removeValue(forKey: key)
        } else {
            routeMemory[key] = entry
        }
    }

    // MARK: - 账本快照（上传码云 reports 分支用）

    /// 账本快照 JSON：播放尝试 + 路由不匹配 + 路线记忆。
    /// 只含 host + 路径模板哈希，不含 token、Cookie、完整 URL。
    /// 每条尝试只取前 20 条期望/实际账本（播单、密钥等诊断关键项在前，分片再多也不撑大文件）。
    /// 空账本返回 "{}"，调用方按“不用上传”处理。
    func snapshotJSON() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func bookJSON(_ e: LedgerBookEntry) -> [String: Any] {
            var d: [String: Any] = [
                "kind": e.kind.rawValue,
                "host": e.host,
                "hash": e.pathTemplateHash,
                "cached": e.servedFromCache
            ]
            if let s = e.upstreamStatus { d["status"] = s }
            if let b = e.bytes { d["bytes"] = b }
            return d
        }
        let attemptsJSON: [[String: Any]] = attempts.map { a in
            var d: [String: Any] = [
                "startedAt": iso.string(from: a.startedAt),
                "module": a.moduleId,
                "item": a.itemId,
                "host": a.lineHost,
                "templateHash": a.lineTemplateHash,
                "hint": a.hint,
                "network": a.networkClass,
                "ladder": a.ladder.map { String(describing: $0) },
                "stage": a.stageReached.rawValue,
                "verdict": a.verdict.rawValue,
                "outcome": a.outcome,
                "recastAtPlay": a.recastAtPlay,
                "finalized": a.finalized,
                "expected": a.expected.prefix(20).map(bookJSON),
                "actual": a.actual.prefix(20).map(bookJSON)
            ]
            if let h = a.errorURIHost { d["errorHost"] = h }
            if let h = a.errorURIHash { d["errorHash"] = h }
            if let s = a.serverAddress { d["serverAddress"] = s }
            if a.addressChanges > 0 { d["addressChanges"] = a.addressChanges }
            if a.rewriteGaps > 0 { d["rewriteGaps"] = a.rewriteGaps }
            return d
        }
        let mismatchesJSON: [[String: Any]] = mismatches.map { m in
            let d: [String: Any] = [
                "at": iso.string(from: m.at),
                "module": m.moduleId,
                "item": m.itemId,
                "hint": m.hintDeclared,
                "urlForm": m.urlForm,
                "sniff": m.sniff,
                "evidence": m.evidenceUsed,
                "decision": m.decision,
                "mismatch": m.mismatch.rawValue,
                "ladder": m.ladderSteps,
                "outcome": m.outcome
            ]
            return d
        }
        let routesJSON: [[String: Any]] = routeMemory.map { (key, entry) in
            let d: [String: Any] = [
                "module": key.moduleId,
                "host": key.host,
                "templateHash": key.urlTemplateHash,
                "hint": key.hint,
                "network": key.networkClass,
                "firstRoute": String(describing: entry.firstRoute),
                "confidence": entry.confidence,
                "lastVerified": iso.string(from: entry.lastVerified),
                "consecutiveFailures": entry.consecutiveFailures
            ]
            return d
        }
        let root: [String: Any] = [
            "exportedAt": iso.string(from: Date()),
            "attempts": attemptsJSON,
            "mismatches": mismatchesJSON,
            "routeMemory": routesJSON
        ]
        guard attemptsJSON.count + mismatchesJSON.count > 0,
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "{}"
        }
        return text
    }
}
