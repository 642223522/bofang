// SettingsView.swift — 设置（v2 重建）
// 外观：跟随系统 / 浅色 / 深色（三选一，存 UserDefaults @AppStorage，
// App 入口用 .preferredColorScheme 生效）。版本号从 Info.plist 读（不硬编码）与 Bundle ID，
// 以及下载说明（直接本地下载、不限 Wi-Fi）。

import SwiftUI

struct SettingsView: View {
    /// 0 跟随系统 / 1 浅色 / 2 深色，与 AdultAsianHDApp 读写同一 key。
    @AppStorage("appearanceMode") private var appearanceMode = 0

    /// 版本号 + 构建号从 Info.plist 读（CFBundleShortVersionString / CFBundleVersion），
    /// 不硬编码——包是 1.0.3 时这里就显示 1.0.3 (4)；读不到时 fallback "1.0.3"。
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.3"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "\(version) (\(build))"
        }
        return version
    }

    var body: some View {
        List {
            Section("外观") {
                Picker("外观", selection: $appearanceMode) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
                .pickerStyle(.segmented)
            }

            Section("下载") {
                Text("下载是直接保存到本机，不打开网页；不限 Wi-Fi，移动数据也能下载。能下载的站就做，不能下载的站就不做，不强求。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Section("关于本 App") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersionText)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Bundle ID")
                    Spacer()
                    Text("com.liudehen.xiaoshipin")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
