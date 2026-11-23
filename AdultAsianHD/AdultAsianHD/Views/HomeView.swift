// HomeView.swift — 主页（v2 重建，照 LAYOUT.md）
// 按国家分框：每国一个圆角框（圆角 12，浅底 + 细边框），框内上下滑动；
// 框内源名排成格子：窄屏（宽 < 500）2 列、宽屏 4 列，GeometryReader 取实际宽度，
// 折叠/展开时立即重排；每个源名是一个圆角芯片（圆角 10，自适应底色 + 细边框），
// 文字居中、单行截断，行高 56pt，初显 3 排，框高 216pt，超出框内滚动。
// 无轮播、无最新/热门行、无「亚洲高清无码」标题。
// 点源名 → SourceDetailView。无源时空态：「还没有源」+「去导入源」跳源 Tab。

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var tabRouter: TabRouter

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if store.sources.isEmpty {
                        EmptyState(
                            title: "还没有源",
                            message: "先去导入或同步一个 JS 源，就能在这里看到它。",
                            actionTitle: "去导入源",
                            action: { tabRouter.selectedTab = 2 }
                        )
                        .frame(minHeight: 400)
                    } else {
                        ForEach(groupedCountries) { group in
                            countryBox(country: group.country, sources: group.sources, width: geometry.size.width)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("主页")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 国家分组

    private struct CountryGroup: Identifiable {
        let country: String
        let sources: [SourceRecord]
        var id: String { country }
    }

    private var groupedCountries: [CountryGroup] {
        let grouped = Dictionary(grouping: store.sources) { record in
            record.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "其他" : record.country
        }
        return grouped.keys.sorted().map { country in
            CountryGroup(country: country, sources: (grouped[country] ?? []).sorted { $0.title < $1.title })
        }
    }

    /// 折叠屏按宽度算列：宽 < 500 用 2 列，否则 4 列，最少 2 列。
    private func columns(for width: CGFloat) -> [GridItem] {
        let count = width < 500 ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: max(2, count))
    }

    // MARK: - 国家框

    private func countryBox(country: String, sources: [SourceRecord], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: country)
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns(for: width), spacing: 4) {
                    ForEach(sources) { source in
                        NavigationLink {
                            SourceDetailView(source: source)
                        } label: {
                            Text(source.title)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
                                .padding(.horizontal, 8)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(.separator), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(8)
        .frame(height: 216)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}
