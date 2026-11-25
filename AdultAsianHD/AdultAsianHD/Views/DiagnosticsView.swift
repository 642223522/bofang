// DiagnosticsView.swift — 检测 Tab（底部第二项）
// 各种检测数据的归拢页，不跑检测本身，只显示结果：
// - 自检：SourceStore.checkResults（五步验真；点一行进源详情页看完整自检状态 + 立即自检）
// - 线路竞速：SourceStore.raceResults（进模块时 raceLinesIfNeeded 跑完记的结果）
// - 同步与健康：上次同步、源数量、自检失败数、后台自检轮次
// - 播放账本：PlaybackLedger（每次播放尝试的期望 vs 实际请求账本、
//   三路判定、路由不匹配记录、路线记忆条数；点一行看明细）
// 数据都走 @Published：后台自动自检 / 竞速有新结果时列表自动刷新；
// 下拉刷新 + “自检全部”按钮可手动重测（复用 store.runCheckAll，不重写自检）。
// 样式跟其他 Tab 页一致：列表式。

import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var store: SourceStore
    @StateObject private var ledger = PlaybackLedger.shared

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

                        Section("播放账本") {
                            NavigationLink {
                                LedgerAttemptListView()
                            } label: {
                                HStack {
                                    Text("播放记录")
                                    Spacer()
                                    Text("\(ledger.attempts.count) 条")
                                        .foregroundColor(.secondary)
                                }
                            }
                            NavigationLink {
                                RouteMismatchListView()
                            } label: {
                                HStack {
                                    Text("路由不匹配")
                                    Spacer()
                                    Text("\(ledger.mismatches.count) 条")
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack {
                                Text("路线记忆")
                                Spacer()
                                Text("\(ledger.routeMemoryCount) 条")
                                    .foregroundColor(.secondary)
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

// MARK: - 播放账本（PlaybackLedger 的查看页；只显示，不跑检测）
// 隐私：账本只记 host + 路径模板哈希，不记 token、Cookie、完整 URL，
// 这里显示的也是哈希后的样子——看得到是哪类请求、走了哪步、判定是什么，
// 看不到签名值。

/// 一行键值对（账本明细页用）。
private struct LedgerKeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// 判定颜色：正常绿 / 被绕过·上游拒绝·播放器拒收红 / 其他失败橙 / 未判定灰。
private func ledgerVerdictColor(_ verdict: LedgerVerdict) -> Color {
    switch verdict {
    case .ok: return .green
    case .bypassed, .rejectedUpstream, .avPlayerRejected: return .red
    case .failedOther: return .orange
    case .unknown: return .secondary
    }
}

/// 播放记录列表（最新在前；点一行看期望 vs 实际账本明细）。
private struct LedgerAttemptListView: View {
    @StateObject private var ledger = PlaybackLedger.shared

    var body: some View {
        List {
            if ledger.attempts.isEmpty {
                Text("还没有播放记录：播一次视频，这里就会记一条（期望账本对实际账本）。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(ledger.attempts) { attempt in
                NavigationLink {
                    LedgerAttemptDetailView(attempt: attempt)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attempt.moduleId.isEmpty ? attempt.lineHost : attempt.moduleId)
                            .font(.subheadline)
                        Text("\(attempt.verdict.label) · \(attempt.stageReached.label) · \(attempt.startedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(ledgerVerdictColor(attempt.verdict))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("播放记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一条播放尝试的明细：概况 + 期望账本 + 实际账本。
private struct LedgerAttemptDetailView: View {
    let attempt: LedgerAttempt

    var body: some View {
        List {
            Section("概况") {
                LedgerKeyValueRow(key: "模块", value: attempt.moduleId.isEmpty ? "—" : attempt.moduleId)
                LedgerKeyValueRow(key: "片", value: attempt.itemId)
                LedgerKeyValueRow(key: "线路 host", value: attempt.lineHost)
                LedgerKeyValueRow(key: "线路模板哈希", value: attempt.lineTemplateHash)
                LedgerKeyValueRow(key: "hint", value: attempt.hint.isEmpty ? "无" : attempt.hint)
                LedgerKeyValueRow(key: "阶段", value: attempt.stageReached.label)
                LedgerKeyValueRow(key: "判定", value: attempt.verdict.label)
                LedgerKeyValueRow(key: "结果", value: attempt.outcome.isEmpty ? "—" : attempt.outcome)
                LedgerKeyValueRow(key: "梯子", value: attempt.ladder.map { $0.displayName }.joined(separator: " → "))
                if let errorHost = attempt.errorURIHost {
                    LedgerKeyValueRow(key: "失败地址 host", value: errorHost)
                }
                if let errorHash = attempt.errorURIHash {
                    LedgerKeyValueRow(key: "失败地址模板哈希", value: errorHash)
                }
                if let serverAddress = attempt.serverAddress {
                    LedgerKeyValueRow(key: "实际服务器", value: serverAddress)
                }
                LedgerKeyValueRow(key: "换服务器次数", value: "\(attempt.addressChanges)")
                if attempt.rewriteGaps > 0 {
                    LedgerKeyValueRow(key: "改写残留", value: "\(attempt.rewriteGaps) 个非回环绝对 URL")
                }
                LedgerKeyValueRow(key: "时间", value: attempt.startedAt.formatted(date: .numeric, time: .shortened))
            }
            Section("期望账本（宿主改写过、指望播放器去取的）") {
                if attempt.expected.isEmpty {
                    Text("无（这条线没经过拦截器/代理改写）。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(attempt.expected) { entry in
                    LedgerBookRow(entry: entry)
                }
            }
            Section("实际账本（拦截器/代理真实收到的）") {
                if attempt.actual.isEmpty {
                    Text("无（没有请求经过拦截器/代理；裸播或嵌页时常见）。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(attempt.actual) { entry in
                    LedgerBookRow(entry: entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("播放记录")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 账本里的一条请求：种类 + host + 模板哈希 + 短 token + 上游状态。
private struct LedgerBookRow: View {
    let entry: LedgerBookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.kindLabel) · \(entry.host)")
                .font(.subheadline)
            Text("模板 \(entry.pathTemplateHash) · token \(entry.token) · \(entry.statusLabel)\(entry.servedFromCache ? " · 缓存" : "")\(entry.bytes.map { " · \($0) 字节" } ?? "")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// 路由不匹配列表（最新在前；点一行看完整字段）。
private struct RouteMismatchListView: View {
    @StateObject private var ledger = PlaybackLedger.shared

    var body: some View {
        List {
            if ledger.mismatches.isEmpty {
                Text("还没有不匹配记录：hint 与 URL 形态/内容事实不一致时，这里记一条。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(ledger.mismatches) { mismatch in
                NavigationLink {
                    RouteMismatchDetailView(mismatch: mismatch)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mismatch.mismatch.label)
                            .font(.subheadline)
                        Text("\(mismatch.moduleId.isEmpty ? "—" : mismatch.moduleId) · 判 \(mismatch.decision) · \(mismatch.at.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("路由不匹配")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一条不匹配记录的完整字段（Claude Q5 定稿的字段表）。
private struct RouteMismatchDetailView: View {
    let mismatch: RouteMismatch

    var body: some View {
        List {
            Section("路由决策") {
                LedgerKeyValueRow(key: "模块", value: mismatch.moduleId.isEmpty ? "—" : mismatch.moduleId)
                LedgerKeyValueRow(key: "片", value: mismatch.itemId)
                LedgerKeyValueRow(key: "hint（声明）", value: mismatch.hintDeclared.isEmpty ? "无" : mismatch.hintDeclared)
                LedgerKeyValueRow(key: "URL 形态", value: mismatch.urlForm.isEmpty ? "—" : mismatch.urlForm)
                LedgerKeyValueRow(key: "嗅探", value: mismatch.sniff)
                LedgerKeyValueRow(key: "用到的证据", value: mismatch.evidenceUsed)
                LedgerKeyValueRow(key: "决策", value: mismatch.decision)
                LedgerKeyValueRow(key: "不匹配", value: mismatch.mismatch.label)
                LedgerKeyValueRow(key: "梯子", value: mismatch.ladderSteps.joined(separator: " → "))
                LedgerKeyValueRow(key: "结果", value: mismatch.outcome.isEmpty ? "—" : mismatch.outcome)
                LedgerKeyValueRow(key: "时间", value: mismatch.at.formatted(date: .numeric, time: .shortened))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("路由不匹配")
        .navigationBarTitleDisplayMode(.inline)
    }
}
