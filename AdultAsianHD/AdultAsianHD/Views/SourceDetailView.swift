// SourceDetailView.swift — 源详情：该源的模块列表（v2 重建）
// 从 WidgetHost.modules 取，排除 type == "stream" 的资源模块；
// 每个模块一行（title + description），点模块 → VideoGridView（loadList，page=1 起）。
// 模块加载失败显示中文错误。底部有删除源按钮。

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
                moduleList(host: host)
            } else {
                LoadingView(text: "正在加载模块…")
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                host = try store.loadHost(for: source)
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

    private func moduleList(host: WidgetHost) -> some View {
        let modules = host.modules.filter { $0.type != "stream" }
        return List {
            if modules.isEmpty {
                EmptyState(title: "没有可用的模块", message: "这个源里没有列表模块。")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(modules) { module in
                    NavigationLink {
                        VideoGridView(
                            host: host,
                            mode: .module(id: module.id),
                            title: module.title,
                            sourceId: source.id
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(module.title)
                                .font(.headline)
                            if !module.description.isEmpty {
                                Text(module.description)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}
