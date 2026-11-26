// MyView.swift — 我的 Tab（v2 重建）
// 两层：第一层只是入口列表（收藏、下载、播放账本、设置、关于）；点一个入口进第二层，
// 里面是该功能的列表与操作。收藏原来是底部第二项，现挪到这里（入口换地方，
// 收藏本身、详情页星标、增删都不动）。下载管理在第二层：Downloader.tasks 列表，
// 标题 + 进度条 + 状态，支持删除已下载文件。

import SwiftUI

struct MyView: View {
    var body: some View {
        WideContent {
            List {
                NavigationLink {
                    FavoritesView()
                } label: {
                    Label("收藏", systemImage: "star")
                }

                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }

                NavigationLink {
                    LedgerHomeView()
                } label: {
                    Label("播放账本", systemImage: "list.clipboard")
                }

                NavigationLink {
                    SettingsView()
                } label: {
                    Label("设置", systemImage: "gearshape")
                }

                NavigationLink {
                    AboutView()
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 第二层：播放账本（从检测 Tab 挪过来，2026-11-26 用户决定）

struct LedgerHomeView: View {
    @ObservedObject private var ledger = PlaybackLedger.shared
    @ObservedObject private var netDiag = NetworkDiagnostics.shared
    @EnvironmentObject private var store: SourceStore
    @State private var isUploading = false
    @State private var uploadStatus: String?
    @State private var uploadFailed = false

    private var hasSavedToken: Bool {
        !(store.loadSavedGiteeToken()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var body: some View {
        WideContent {
            List {
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
                HStack {
                    Text("网络诊断")
                    Spacer()
                    Text("\(netDiag.events.count) 条")
                        .foregroundColor(.secondary)
                }
                Section {
                    Button {
                        uploadLedger()
                    } label: {
                        HStack {
                            Text(isUploading ? "正在上传…" : "上传账本到码云")
                            Spacer()
                            if isUploading {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                    .disabled(isUploading)
                    if !hasSavedToken {
                        Text("尚未保存 Gitee Token：请先到「源」Tab 填写并同步一次，或填写 Token 后再上传。")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if let uploadStatus {
                        Text(uploadStatus)
                            .font(.caption)
                            .foregroundColor(uploadFailed ? .red : .green)
                            .textSelection(.enabled)
                    }
                    Text("传到码云 reports 分支（一天一个文件），包含播放记录、路由不匹配、路线记忆与网络阶段诊断；没开节点失败的站会标 direct。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } footer: {
                    Text("只传 host + 路径模板哈希，不传 token、Cookie、完整链接。")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("播放账本")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func uploadLedger() {
        guard !isUploading else { return }
        isUploading = true
        uploadStatus = nil
        uploadFailed = false
        Task { @MainActor in
            let result = await store.uploadLedger(token: "")
            isUploading = false
            switch result {
            case .success(let file):
                uploadFailed = false
                uploadStatus = "已上传（\(file)）"
            case .failure(let error):
                uploadFailed = true
                uploadStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - 第二层：下载管理

struct DownloadsView: View {
    @EnvironmentObject private var downloader: Downloader

    var body: some View {
        WideContent {
            Group {
                if downloader.tasks.isEmpty {
                    EmptyState(title: "还没有下载", message: "在详情页点「下载」，下载好的视频会出现在这里。")
                } else {
                    List {
                        ForEach(downloader.tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                ProgressView(value: task.progress)
                                Text(task.status)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloader.delete(task)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 第二层：关于

private struct AboutView: View {
    /// 版本号 + 构建号从 Info.plist 读（CFBundleShortVersionString / CFBundleVersion），
    /// 不硬编码——包是 1.0.3 时这里就显示 1.0.3 (4)；读不到时 fallback "1.0.3"。
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.3"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "版本 \(version) (\(build))"
        }
        return "版本 \(version)"
    }

    var body: some View {
        WideContent {
            List {
                Section {
                    Text("我的私人影院")
                        .font(.headline)
                    Text(appVersionText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Bundle ID：com.liudehen.xiaoshipin")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Section {
                    Text("软件是壳，JS 是可导入的源；一个站一个 JS 文件，更新 JS 不用重装软件。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
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
    @ObservedObject private var ledger = PlaybackLedger.shared

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
                LedgerKeyValueRow(key: "网络", value: attempt.networkClass)
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
    @ObservedObject private var ledger = PlaybackLedger.shared

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
