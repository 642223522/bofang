// MyView.swift — 我的 Tab（v2 重建）
// 两层：第一层只是入口列表（收藏、下载、设置、关于）；点一个入口进第二层，
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
