// SourceBrowseView.swift — 主页点源名直进的浏览页（v2 重建）
// 入参只有 source：内部用 store.loadHost(for:) 加载 host，加载中显示
// “正在加载模块…”，失败显示人话错误；加载成功后显示 ModuleListView（模块入口列表，
// 点模块 → VideoGridView）。竞速不再这里跑：首屏 latest 第 1 页画出来后，
// VideoGridView 拿新鲜种子触发（run #20，种子制）。

import SwiftUI

struct SourceBrowseView: View {
    let source: SourceRecord

    @EnvironmentObject private var store: SourceStore

    @State private var host: WidgetHost?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                EmptyState(title: "加载失败", message: errorMessage)
            } else if let host {
                ModuleListView(source: source, host: host)
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
    }
}
