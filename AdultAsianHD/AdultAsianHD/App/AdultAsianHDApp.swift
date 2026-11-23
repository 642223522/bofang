// AdultAsianHDApp.swift — App 入口（v2 重建，1.0.0）
// 四 Tab 顺序固定：主页 / 收藏 / 源 / 我的。App 级持有 SourceStore.shared
// 并注入 environmentObject；外观跟随 SettingsView 的 @AppStorage 选择。

import SwiftUI

/// Tab 跳转路由器：主页空态「去导入源」按钮靠它切到「源」Tab。
final class TabRouter: ObservableObject {
    @Published var selectedTab = 0
}

@main
struct AdultAsianHDApp: App {
    @StateObject private var store = SourceStore.shared
    @StateObject private var favorites = FavoritesStore.shared
    @StateObject private var downloader = Downloader()
    @StateObject private var tabRouter = TabRouter()

    /// 外观：0 跟随系统 / 1 浅色 / 2 深色（SettingsView 写入同一 key）。
    @AppStorage("appearanceMode") private var appearanceMode = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tabRouter.selectedTab) {
                NavigationStack {
                    HomeView()
                }
                .tabItem { Label("主页", systemImage: "house") }
                .tag(0)

                NavigationStack {
                    FavoritesView()
                }
                .tabItem { Label("收藏", systemImage: "star") }
                .tag(1)

                NavigationStack {
                    SourcesView()
                }
                .tabItem { Label("源", systemImage: "square.stack.3d.up") }
                .tag(2)

                NavigationStack {
                    MyView()
                }
                .tabItem { Label("我的", systemImage: "person") }
                .tag(3)
            }
            .environmentObject(store)
            .environmentObject(favorites)
            .environmentObject(downloader)
            .environmentObject(tabRouter)
            .preferredColorScheme(
                appearanceMode == 1 ? .light
                : appearanceMode == 2 ? .dark
                : nil
            )
        }
    }
}
