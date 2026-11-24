// SourceBrowseView.swift — 主页点源名直进的浏览页（v2 重建）
// 入参只有 source：内部用 store.loadHost(for:) 加载 host，加载中显示
// “正在加载模块…”，失败显示人话错误；加载成功后调 raceLinesIfNeeded()
// （验线竞速，定本次首选线），再显示 ModuleListView（模块入口列表，
// 点模块 → VideoGridView）。不经过 SourceDetailView（源信息页）。

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
                // 点进模块：后台竞速固定验线，定本次首选线（只跑一次；
                // 播放器点视频时读 host.preferredLine，快路径不再写死 memojav）。
                loaded.raceLinesIfNeeded()
            } catch {
                errorMessage = "加载源失败：\(error.localizedDescription)"
            }
        }
    }
}
