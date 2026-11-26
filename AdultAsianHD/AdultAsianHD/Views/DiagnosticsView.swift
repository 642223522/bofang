// DiagnosticsView.swift — 检测 Tab（底部第二项）
// 各种检测数据的归拢页，不跑检测本身，只显示结果：
// - 自检：SourceStore.checkResults（五步验真；点一行进源详情页看完整自检状态 + 立即自检）
// - 线路竞速：SourceStore.raceResults（进模块时 raceLinesIfNeeded 跑完记的结果）
// - 同步与健康：上次同步、源数量、自检失败数、后台自检轮次
// 数据都走 @Published：后台自动自检 / 竞速有新结果时列表自动刷新；
// 下拉刷新 + “自检全部”按钮可手动重测（复用 store.runCheckAll，不重写自检）。
// 样式跟其他 Tab 页一致：列表式。

import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: SourceStore
    @ObservedObject private var netDiag = NetworkDiagnostics.shared

    @State private var isCheckingAll = false
    @State private var resultMessage = ""
    @State private var showResultAlert = false

    var body: some View {
        WideContent {
            Group {
                if store.sources.isEmpty {
                    EmptyState(title: "还没有源", message: "先到「源」Tab 导入一个 JS 源，自检与竞速结果会出现在这里。")
                } else {
                    List {
                        Section("自检") {
                            Button {
                                checkAll()
                            } label: {
                                Label(isCheckingAll ? "正在自检…" : "自检全部", systemImage: "stethoscope")
                            }
                            .disabled(isCheckingAll)

                            ForEach(store.sources) { source in
                                NavigationLink {
                                    SourceDetailView(source: source)
                                } label: {
                                    checkRow(for: source)
                                }
                            }
                        }

                        Section("线路竞速") {
                            ForEach(store.sources) { source in
                                NavigationLink {
                                    RaceDetailView(source: source)
                                } label: {
                                    raceRow(for: source)
                                }
                            }
                        }

                        Section("同步与健康") {
                            infoRow("上次同步", lastSyncText)
                            infoRow("源数量", "\(store.sources.count)")
                            infoRow("自检失败", "\(failedCheckCount) 个")
                            infoRow("竞速已测", "\(store.raceResults.count) 个")
                            infoRow("后台自检", store.autoCheckCycleDescription)
                        }

                        Section("网络诊断（DNS/TCP/TLS/HTTP/WAF）") {
                            infoRow("当前网络", PlaybackLedger.networkClass == "proxy" ? "proxy（代理/VPN）" : "direct（直连无节点）")
                            if netDiag.events.isEmpty {
                                Text("暂无请求记录：浏览列表或播放后，这里会显示每条请求死在哪一层（DNS/TCP/TLS/HTTP/WAF）与各阶段耗时。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                let failedCount = netDiag.events.filter { $0.phase != .ok && $0.phase != .cancelled }.count
                                infoRow("最近记录", "\(netDiag.events.count) 条（异常 \(failedCount) 条）")
                                ForEach(netDiag.events.prefix(15)) { event in
                                    NavigationLink {
                                        NetworkDiagDetailView(event: event)
                                    } label: {
                                        netDiagRow(for: event)
                                    }
                                }
                                if netDiag.events.count > 15 {
                                    NavigationLink {
                                        NetworkDiagAllView()
                                    } label: {
                                        Text("查看全部 \(netDiag.events.count) 条记录")
                                            .font(.subheadline)
                                    }
                                }
                                Button("清空网络诊断记录", role: .destructive) {
                                    netDiag.clear()
                                }
                                .font(.subheadline)
                            }
                        }

                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        _ = await store.runCheckAll()
                    }
                }
            }
        }
        .navigationTitle("检测")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showResultAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    // MARK: - 自检行

    /// 一行 = 源名 + 自检状态（正常绿 / 失败红死在哪步 / 跳过灰 / 未自检灰）。
    /// 显示格式与源 Tab 的自检状态行一致。
    @ViewBuilder
    private func checkRow(for source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.title)
                .font(.subheadline)
            if let result = store.checkResults[source.id] {
                switch result.status {
                case .ok:
                    Text("自检正常" + (result.checkedAt.map { " · \($0.formatted(date: .numeric, time: .shortened))" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.green)
                case .failed:
                    let step = result.failedStep.map { "死在\($0)步" } ?? "自检失败"
                    let reason = result.failedReason
                        ?? result.failedLines.sorted(by: { $0.key < $1.key }).first.map { "\($0.key)：\($0.value)" }
                        ?? ""
                    Text(step + "：" + reason + (result.checkedAt.map { " · \($0.formatted(date: .numeric, time: .shortened))" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                case .skipped:
                    Text("与 \(duplicateTitle(for: result.duplicateOf)) 重复，跳过" + (result.checkedAt.map { " · \($0.formatted(date: .numeric, time: .shortened))" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let probe = result.deepProbe, !probe.passed {
                    Text("深探针：坏了（\(probe.failedStep ?? "首片")）· \(probe.checkedAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                Text("未自检")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 竞速行

    /// 一行 = 源名 + 竞速结果（首选线 + 耗时 / 未分出胜负 + 原因 / 尚未竞速）。
    @ViewBuilder
    private func raceRow(for source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.title)
                .font(.subheadline)
            if let race = store.raceResults[source.id] {
                if let winner = race.winnerLabel {
                    let winnerMs = race.timings.first(where: { $0.kind == winner })?.milliseconds
                    Text("首选 \(winner)" + (winnerMs.map { " · \($0)ms" } ?? "") + " · \(race.racedAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("未分出胜负" + (race.note.map { "：\($0)" } ?? "") + " · \(race.racedAt.formatted(date: .numeric, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            } else {
                Text("尚未竞速（进模块浏览一次即跑）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 同步与健康

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
    }

    private var lastSyncText: String {
        guard let date = store.lastSyncAt else { return "从未同步" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private var failedCheckCount: Int {
        store.checkResults.values.filter { $0.status == .failed }.count
    }

    /// 重复的那个源的标题（duplicateOf 是源 id；找不到显示 id）。
    private func duplicateTitle(for duplicateOf: String?) -> String {
        guard let id = duplicateOf else { return "其他源" }
        return store.sources.first(where: { $0.id == id })?.title ?? id
    }

    // MARK: - 自检全部（复用 store.runCheckAll）

    private func checkAll() {
        isCheckingAll = true
        Task {
            let (ok, failed, skipped) = await store.runCheckAll()
            isCheckingAll = false
            var text = "自检完成：\(ok) 个正常，\(failed) 个失败"
            if skipped > 0 { text += "，\(skipped) 个重复跳过" }
            resultMessage = text
            showResultAlert = true
        }
    }

    // MARK: - 网络诊断行

    @ViewBuilder
    private func netDiagRow(for event: NetworkDiagEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(event.phase.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(netDiagPhaseColor(event.phase))
                Text(event.host.isEmpty ? "—" : event.host)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(event.networkClass)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text("\(event.source) · \(event.statusCode.map { "HTTP \($0)" } ?? (event.errorSummary ?? "无响应")) · \(event.timingSummary)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
            if let ip = event.remoteAddress, !ip.isEmpty {
                Text("IP: \(ip)\(event.protocolName.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 竞速明细（点一行进来）

/// 某源一次竞速的明细：胜出线、各线耗时、竞速时间、没分出胜负的原因。
/// “重新竞速”走同一条老路：现建一个 host 调 raceLinesIfNeeded(force: true)
///（无视本会话去重，强制重测一次）；结果记回 SourceStore 后本页自动刷新。
/// 竞速跑着的时候 host 存在 @State 里扣着（不然 host 一释放，后台竞速就丢了）。
private struct RaceDetailView: View {
    let source: SourceRecord

    @EnvironmentObject private var store: SourceStore

    @State private var racing = false
    @State private var racingHost: WidgetHost?
    @State private var raceError: String?

    var body: some View {
        WideContent {
            Group {
                if let race = store.raceResults[source.id] {
                    List {
                        Section("结果") {
                            if let winner = race.winnerLabel {
                                HStack {
                                    Text("首选线路")
                                    Spacer()
                                    Text(winner)
                                        .foregroundColor(.green)
                                }
                            } else {
                                HStack {
                                    Text("首选线路")
                                    Spacer()
                                    Text("未分出胜负")
                                        .foregroundColor(.orange)
                                }
                                if let note = race.note {
                                    Text(note)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack {
                                Text("竞速时间")
                                Spacer()
                                Text(race.racedAt.formatted(date: .numeric, time: .shortened))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if !race.timings.isEmpty {
                            Section("各线耗时") {
                                ForEach(race.timings, id: \.kind) { timing in
                                    HStack {
                                        Text(timing.kind)
                                        Spacer()
                                        if timing.kind == race.winnerLabel {
                                            Text("首选")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        }
                                        Text("\(timing.milliseconds)ms")
                                            .foregroundColor(.secondary)
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }

                        Section {
                            Button {
                                rerace()
                            } label: {
                                Label(racing ? "正在竞速…" : "重新竞速", systemImage: "bolt")
                            }
                            .disabled(racing)
                            if let raceError {
                                Text(raceError)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                        } footer: {
                            Text("进模块浏览时自动竞速一次（定本次首选线）；这里点一次即重测一次，结果记下来供下次参考。")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                } else {
                    VStack(spacing: 16) {
                        EmptyState(title: "尚未竞速", message: "进这个源的模块浏览一次，后台即自动竞速并记下结果；也可以直接点下面重测。")
                        Button {
                            rerace()
                        } label: {
                            Label(racing ? "正在竞速…" : "重新竞速", systemImage: "bolt")
                        }
                        .buttonStyle(.bordered)
                        .disabled(racing)
                        if let raceError {
                            Text(raceError)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                    }
                }
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.raceResults[source.id]?.racedAt) { _, _ in
            // 新竞速结果到了：收起“竞速中”，放掉扣着的 host。
            racing = false
            racingHost = nil
        }
    }

    private func rerace() {
        raceError = nil
        racing = true
        Task {
            do {
                let host = try store.loadHost(for: source)
                // host 扣在 @State 里，竞速跑完（结果记回 store）前不释放。
                racingHost = host
                // 手动重竞：force 强制重测一次（无视本会话“每模块只竞一次”的去重）。
                host.raceLinesIfNeeded(force: true)
            } catch {
                racing = false
                raceError = "加载源失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 网络诊断明细

private func netDiagPhaseColor(_ phase: NetworkDiagPhase) -> Color {
    switch phase {
    case .ok: return .green
    case .dns, .tcp, .tls, .waf: return .red
    case .http: return .orange
    case .cancelled, .unknown: return .secondary
    }
}

private struct NetworkDiagAllView: View {
    @ObservedObject private var netDiag = NetworkDiagnostics.shared

    var body: some View {
        WideContent {
            List {
                ForEach(netDiag.events) { event in
                    NavigationLink {
                        NetworkDiagDetailView(event: event)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.phase.label)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(netDiagPhaseColor(event.phase))
                                Text(event.host.isEmpty ? "—" : event.host)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            Text("\(event.source) · \(event.networkClass) · \(event.timingSummary)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("网络诊断记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NetworkDiagDetailView: View {
    let event: NetworkDiagEvent

    var body: some View {
        WideContent {
            List {
                Section("判定") {
                    row("阶段/结果", event.phase.label, color: netDiagPhaseColor(event.phase))
                    row("网络类", event.networkClass)
                    row("来源", event.source)
                    row("方法", event.method)
                    row("Host", event.host.isEmpty ? "—" : event.host)
                    row("路径（已脱敏）", event.sanitizedPath)
                    if let status = event.statusCode {
                        row("HTTP 状态", "\(status)")
                    }
                    if let summary = event.errorSummary, !summary.isEmpty {
                        row("错误摘要", summary)
                    }
                    if let domain = event.errorDomain, let code = event.errorCode {
                        row("错误码", "\(domain) (\(code))")
                    }
                    row("时间", event.at.formatted(date: .numeric, time: .standard))
                }
                Section("连接与耗时（URLSessionTaskMetrics）") {
                    row("对端 IP", event.remoteAddress ?? "未知")
                    row("协议", event.protocolName ?? "未知")
                    row("连接复用", event.reusedConnection ? "是" : "否")
                    row("经代理连接", event.proxyConnection ? "是" : "否")
                    row("DNS", event.dnsMs.map { "\($0) ms" } ?? "—")
                    row("TCP", event.tcpMs.map { "\($0) ms" } ?? "—")
                    row("TLS/SNI", event.tlsMs.map { "\($0) ms" } ?? "—")
                    row("TTFB", event.ttfbMs.map { "\($0) ms" } ?? "—")
                    row("总耗时", "\(event.totalMs) ms")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(event.host.isEmpty ? "请求详情" : event.host)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ key: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
