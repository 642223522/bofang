// SourceDetailView.swift — 源信息页（v2 重建）
// 源 Tab 的代码页从「源详情」进这里；主页点源名不再经过这里，
// 直接进 SourceBrowseView（模块入口列表）。本页显示模块元数据、导入方式，
// 操作有导出 / 删除（带确认）。
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

}
