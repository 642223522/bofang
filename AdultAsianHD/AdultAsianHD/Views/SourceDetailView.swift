// SourceDetailView.swift — 源信息页（v2 重建）
// 源 Tab 的代码页从「源详情」进这里；主页点源名不再经过这里，
// 直接进 SourceBrowseView（模块入口列表）。本页显示模块元数据、导入方式、
// 自检状态，操作有导出 / 自检 / 删除（带确认）/ 上传坏模块（自检失败时）。
// 浏览仍走「浏览此源」→ ModuleListView（模块入口列表，
// 点模块 → VideoGridView）。
// 元数据取自 host.meta（WidgetMeta）：id、名称、版本、描述、作者、站点都有；
// 作者与站点是可选字段，模块没给就显示 "—"。

import SwiftUI

struct SourceDetailView: View {
    let source: SourceRecord

    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: WidgetHost?
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false
    @State private var isChecking = false
    @State private var isUploading = false
    @State private var resultMessage = ""
    @State private var showResultAlert = false

    var body: some View {
        Group {
            if let errorMessage {
                EmptyState(title: "加载失败", message: errorMessage)
            } else if let host {
                infoView(host: host)
            } else {
                LoadingView(text: "正在加载模块…")
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let loaded = try store.loadHost(for: source)
                host = loaded
            } catch {
                errorMessage = "加载源失败：\(error.localizedDescription)"
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除源", systemImage: "trash")
                }
            }
        }
        .alert("删除这个源？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.delete(source)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后本地文件就没有了，同步的源下次同步还会拉回来。")
        }
        .alert("提示", isPresented: $showResultAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    // MARK: - 信息页

    private func infoView(host: WidgetHost) -> some View {
        List {
            Section("源信息") {
                infoRow("源 id", host.meta.id)
                infoRow("名称", host.meta.title)
                infoRow("版本", host.meta.version)
                infoRow("作者", host.meta.author ?? "—")
                infoRow("描述", host.meta.description)
                infoRow("站点", host.meta.site ?? "—")
                infoRow("导入方式", originText)
                infoRow("文件名", source.fileName)
                infoRow("导入时间", dateText(source.importedAt))
            }

            Section("自检状态") {
                checkStatusRows
                Button {
                    Task { await runCheck() }
                } label: {
                    Label(isChecking ? "正在自检…" : "立即自检", systemImage: "stethoscope")
                }
                .disabled(isChecking)
                if store.checkResults[source.id]?.status == .failed {
                    Button {
                        Task { await uploadBroken() }
                    } label: {
                        Label(isUploading ? "正在上传…" : "上传坏的模块到码云", systemImage: "arrow.up.doc")
                    }
                    .disabled(isUploading)
                }
            }

            Section("浏览") {
                NavigationLink {
                    ModuleListView(source: source, host: host)
                } label: {
                    Label("浏览此源", systemImage: "play.rectangle.on.rectangle")
                }
            }

            Section("操作") {
                if let url = store.exportURL(for: source) {
                    ShareLink(item: url) {
                        Label("导出 .js 文件", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除此源", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var checkStatusRows: some View {
        if let result = store.checkResults[source.id] {
            switch result.status {
            case .ok:
                Label("正常", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                if let at = result.checkedAt {
                    Text("检查时间：\(dateText(at))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                // 五步验真明细（每步 + 耗时）
                if let steps = result.steps, !steps.isEmpty {
                    ForEach(steps, id: \.name) { step in
                        HStack {
                            Text(step.name)
                            Spacer()
                            Text(step.passed ? "通过" : "失败")
                                .foregroundColor(step.passed ? .green : .red)
                            Text("\(step.milliseconds)ms")
                                .foregroundColor(.secondary)
                        }
                        .font(.footnote)
                    }
                }
                // 深探针（第二层）
                if let probe = result.deepProbe {
                    if probe.passed {
                        Text("深探针：通过 · \(dateText(probe.checkedAt))")
                            .font(.footnote)
                            .foregroundColor(.green)
                    } else {
                        Text("深探针：坏了（\(probe.failedStep ?? "首片")：\(probe.reason ?? "")）· \(dateText(probe.checkedAt))")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }
            case .failed:
                Label("失败", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
                // 死在哪步 + 原因
                if let step = result.failedStep {
                    Text("死在\(step)步：\(result.failedReason ?? "")")
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                ForEach(result.failedLines.sorted(by: { $0.key < $1.key }), id: \.key) { sample, reason in
                    Text("\(sample)：\(reason)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                // 五步验真明细（每步 + 耗时）
                if let steps = result.steps, !steps.isEmpty {
                    ForEach(steps, id: \.name) { step in
                        HStack {
                            Text(step.name)
                            Spacer()
                            Text(step.passed ? "通过" : "失败")
                                .foregroundColor(step.passed ? .green : .red)
                            Text("\(step.milliseconds)ms")
                                .foregroundColor(.secondary)
                        }
                        .font(.footnote)
                    }
                }
                if let at = result.checkedAt {
                    Text("检查时间：\(dateText(at))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                // 深探针（第二层）
                if let probe = result.deepProbe, !probe.passed {
                    Text("深探针：坏了（\(probe.failedStep ?? "首片")：\(probe.reason ?? "")）· \(dateText(probe.checkedAt))")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            case .skipped:
                Label("跳过", systemImage: "minus.circle.fill")
                    .foregroundColor(.secondary)
                Text("与 \(duplicateTitle(for: result.duplicateOf)) 重复，跳过")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                if let at = result.checkedAt {
                    Text("检查时间：\(dateText(at))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            Text("未自检")
                .foregroundColor(.secondary)
        }
    }

    /// 重复的那个源的标题（duplicateOf 是源 id；找不到显示 id）。
    private func duplicateTitle(for duplicateOf: String?) -> String {
        guard let id = duplicateOf else { return "其他源" }
        return store.sources.first(where: { $0.id == id })?.title ?? id
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    /// 来源标记：origin 为 gitee / 含「码云」即码云同步，否则外部导入。
    private var originText: String {
        if source.origin == "gitee" || source.origin.contains("码云") || source.origin.contains("Gitee") {
            return "码云同步"
        }
        return "外部导入"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    private func runCheck() async {
        isChecking = true
        _ = await store.runCheck(for: source)
        isChecking = false
    }

    private func uploadBroken() async {
        isUploading = true
        // 传空串：store 里先用 Keychain 存过的 Token，没有才报错；
        // 传的是全部自检失败的源，不只这一个。
        let result = await store.uploadBrokenSources(token: "")
        isUploading = false
        switch result {
        case .success(let count):
            resultMessage = "已上传 \(count) 个坏的模块到码云 broken 分支"
        case .failure(let error):
            resultMessage = error.localizedDescription
        }
        showResultAlert = true
    }
}
