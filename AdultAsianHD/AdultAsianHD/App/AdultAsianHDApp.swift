// AdultAsianHDApp.swift — App 入口（v2 重建，1.0.0）
// 四 Tab 顺序固定：主页 / 检测 / 源 / 我的。收藏原来是底部第二项，
// 现挪到「我的」第一层入口里；第二项改放检测（自检 / 线路竞速 / 同步与健康）。
// App 级持有 SourceStore.shared 并注入 environmentObject；
// 外观跟随 SettingsView 的 @AppStorage 选择。

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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tabRouter.selectedTab) {
                NavigationStack {
                    HomeView()
                }
                .tabItem { Label("主页", systemImage: "house") }
                .tag(0)

                NavigationStack {
                    DiagnosticsView()
                }
                .tabItem { Label("检测", systemImage: "stethoscope") }
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
            .onAppear {
                // 启动时：闲置 12 小时一轮轻检 / 7 天一轮深探针（到期才跑）。
                store.maybeRunAutoCheck()
                // 异步探测 hls.js / dash.js 在本机 WebView 里是否可用
                // （ManagedMediaSource + Hls.isSupported()，运行时实测，不用版本号判断），
                // 不阻塞启动；探到可用才置 PlaybackCapabilities.hasHLSJS/hasDASH，
                // 路由才选这两路（B 路 WebPlayerCapabilityProbe，探完即释放隐藏 WebView）。
                WebPlayerCapabilityProbe.start()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    // 切回前台：到期就后台自检（闲置时自己跑）。
                    store.maybeRunAutoCheck()
                } else if newPhase == .background {
                    // 进后台：后台自检立刻停，下次断点续跑。
                    store.cancelAutoCheck()
                }
            }
            .onChange(of: tabRouter.selectedTab) { _, _ in
                // 切页面：后台自检立刻停（让路），下次断点续跑。
                store.cancelAutoCheck()
            }
        }
    }
}
