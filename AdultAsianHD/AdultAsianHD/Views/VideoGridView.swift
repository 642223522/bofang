// VideoGridView.swift — 视频封面墙（v2 重建）
// LazyVGrid 2 列（宽屏 3–4 列），封面卡片带收藏星标，点封面 → DetailView。
// 下拉刷新（.refreshable）、向下滚动加载更多（到最后一项时 page+1 追加）、
// 从详情页返回恢复滚动位置（ScrollViewReader + 记录最后可见项 id，返回时 scrollTo）。
// 顶部搜索框调 host.search。

import SwiftUI

struct VideoGridView: View {
    enum LoadMode {
        /// 模块列表：调 host.loadList(moduleId:page:)。
        case module(id: String)
        /// 分类：调 host.loadCategoryVideos(categoryId:categoryName:page:siteHost:categorySlug:)。
        /// 直接带分类项（打分、取编号、取域名、取 slug 都从它身上取），
        /// 分类链接绝不送进 loadResource。
        case category(item: VideoItem)
    }

    let host: WidgetHost
    let mode: LoadMode
    let title: String
    let sourceId: String

    @State private var items: [VideoItem] = []
    @State private var currentPage = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var lastVisibleId: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        searchBar

                        if let errorMessage, items.isEmpty {
                            EmptyState(title: "加载失败", message: errorMessage)
                        } else if items.isEmpty && !isLoading {
                            EmptyState(title: "这里还没有视频", message: "换个分类看看，或下拉刷新。")
                        } else {
                            LazyVGrid(columns: columns(for: geometry.size.width), spacing: 16) {
                                ForEach(items) { item in
                                    NavigationLink {
                                        destination(for: item)
                                    } label: {
                                        VideoCard(item: item, sourceId: sourceId)
                                    }
                                    .buttonStyle(.plain)
                                    .id(item.id)
                                    .onAppear {
                                        lastVisibleId = item.id
                                        if item.id == items.last?.id {
                                            loadNextPage()
                                        }
                                    }
                                }
                            }

                            if isLoading {
                                ProgressView()
                                    .padding()
                            }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await reload()
                }
                .onAppear {
                    // 从详情页返回时恢复到之前的位置。
                    if let lastVisibleId {
                        proxy.scrollTo(lastVisibleId, anchor: .top)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if items.isEmpty {
                await reload()
            }
        }
    }

    // MARK: - 跳转：分类项进分类列表页，视频项进详情页

    /// 分类项只是个跳转桩：点它进 CategoryListView 加载该分类的视频，
    /// 绝不把分类链接送进 loadResource（模块会返回“无可用播放源”）。
    @ViewBuilder
    private func destination(for item: VideoItem) -> some View {
        if host.isCategoryItem(item) {
            CategoryListView(categoryItem: item, host: host, sourceId: sourceId)
        } else {
            DetailView(item: item, host: host, sourceId: sourceId)
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("搜索视频…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { runSearch() }
            Button("搜索", action: runSearch)
                .buttonStyle(.bordered)
            if isSearching {
                Button("清除") {
                    searchText = ""
                    isSearching = false
                    Task { await reload() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 列数：窄屏 2 列，宽屏 3–4 列

    private func columns(for width: CGFloat) -> [GridItem] {
        let count: Int
        if width < 500 {
            count = 2
        } else if width < 900 {
            count = 3
        } else {
            count = 4
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: - 加载

    private func reload() async {
        currentPage = 1
        hasMore = true
        await load(page: 1, append: false)
    }

    private func loadNextPage() {
        guard !isLoading, hasMore else { return }
        Task { await load(page: currentPage + 1, append: true) }
    }

    private func runSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearching = true
        Task { await reload() }
    }

    private func load(page: Int, append: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let fetched: [VideoItem]
            if isSearching {
                fetched = try await host.search(keyword: searchText, page: page)
            } else {
                switch mode {
                case .module(let id):
                    fetched = try await host.loadList(moduleId: id, page: page)
                case .category(let item):
                    fetched = try await host.loadCategoryVideos(
                        categoryId: item.categoryNumericId ?? item.id,
                        categoryName: item.categoryNameWithoutCount,
                        page: page,
                        siteHost: item.siteHost,
                        categorySlug: item.categorySlug
                    )
                }
            }
            if append {
                items.append(contentsOf: fetched)
            } else {
                items = fetched
            }
            hasMore = !fetched.isEmpty
            currentPage = page
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - 分类列表页

/// 分类列表页：点分类项进来，只加载该分类下的视频。
/// 复用 VideoGridView（分页 / 下拉刷新 / 滚动恢复都一样），
/// 取列表走 host.loadCategoryVideos（先请求拦截，不行再直调 WP REST）。
struct CategoryListView: View {
    let categoryItem: VideoItem
    let host: WidgetHost
    let sourceId: String

    var body: some View {
        VideoGridView(
            host: host,
            mode: .category(item: categoryItem),
            title: categoryItem.title,
            sourceId: sourceId
        )
    }
}
