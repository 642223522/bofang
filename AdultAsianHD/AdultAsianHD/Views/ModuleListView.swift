// ModuleListView.swift — 该源的模块入口列表（v2 重建）
// 从 SourceDetailView.swift 抽出来复用：主页点源名（SourceBrowseView）和
// 源信息页的「浏览此源」都进这里。
// 点模块 → VideoGridView（loadList，page=1 起）。
// 从 WidgetHost.modules 取，排除 type == "stream" 的资源模块。

import SwiftUI

struct ModuleListView: View {
    let source: SourceRecord
    let host: WidgetHost

    var body: some View {
        List {
            let modules = host.modules.filter { $0.type != "stream" }
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
                            if module.requiresWebView {
                                Text("需 WebView · 嵌入播放")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
