// FavoritesView.swift — 收藏 Tab（v2 重建）
// 收藏存在 UserDefaults：[String] 存 VideoItem.id，另存一份 [FavoriteEntry] 的
// JSON 供展示；每条收藏还存 sourceId，打开时用 SourceStore.loadHost 重建 host
// 再进 DetailView。注意：契约里的 VideoItem 未声明 Codable，所以这里用自有
// 的 Codable 结构 FavoriteEntry 存字段、再还原成 VideoItem，不依赖 VideoItem 的
// Codable。

import SwiftUI

// MARK: - 存储结构

/// 一条收藏：视频字段 + 它所属的源 id（打开详情页时靠它重建 WidgetHost）。
struct FavoriteEntry: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let link: String
    let coverURL: String?
    let description: String
    let category: String
    let sourceId: String

    init(item: VideoItem, sourceId: String) {
        self.id = item.id
        self.title = item.title
        self.link = item.link
        self.coverURL = item.coverURL
        self.description = item.description
        self.category = item.category
        self.sourceId = sourceId
    }

    var videoItem: VideoItem {
        VideoItem(
            id: id, title: title, link: link,
            coverURL: coverURL, description: description, category: category
        )
    }
}

// MARK: - 收藏仓库

final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    private let idsKey = "favoriteIDs"
    private let entriesKey = "favoriteEntriesJSON"

    @Published private(set) var entries: [FavoriteEntry] = []

    private init() {
        load()
    }

    func isFavorite(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    func toggle(item: VideoItem, sourceId: String) {
        if let index = entries.firstIndex(where: { $0.id == item.id }) {
            entries.remove(at: index)
        } else {
            entries.append(FavoriteEntry(item: item, sourceId: sourceId))
        }
        save()
    }

    func remove(_ entry: FavoriteEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([FavoriteEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        UserDefaults.standard.set(entries.map(\.id), forKey: idsKey)
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }
}

// MARK: - 收藏列表

struct FavoritesView: View {
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        Group {
            if favorites.entries.isEmpty {
                EmptyState(title: "还没有收藏", message: "在视频封面或详情页点星标，就会出现在这里。")
            } else {
                List {
                    ForEach(favorites.entries) { entry in
                        NavigationLink(value: entry) {
                            HStack(spacing: 12) {
                                // 和网格同一套封面加载（带重试 + 黄果密文解密），
                                // 不然收藏里的黄果封面还是灰框。
                                CoverImage(urlString: entry.coverURL)
                                    .frame(width: 96, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(entry.title)
                                    .font(.subheadline)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { offsets in
                        // 先按原下标取出来再删：逐个按下标删会在删除后移位删错。
                        let toRemove = offsets.map { favorites.entries[$0] }
                        toRemove.forEach { favorites.remove($0) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FavoriteEntry.self) { entry in
            FavoriteDetailLoader(entry: entry)
        }
    }
}

// MARK: - 收藏打开：按 sourceId 重建 host 再进详情页

private struct FavoriteDetailLoader: View {
    let entry: FavoriteEntry

    @EnvironmentObject private var store: SourceStore
    @State private var host: WidgetHost?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let host {
                DetailView(item: entry.videoItem, host: host, sourceId: entry.sourceId)
            } else if let errorMessage {
                EmptyState(title: "打不开这个收藏", message: errorMessage)
            } else {
                LoadingView(text: "正在打开…")
            }
        }
        .task {
            guard let source = store.sources.first(where: { $0.id == entry.sourceId }) else {
                errorMessage = "这个收藏所属的源已被删除，请重新导入该源。"
                return
            }
            do {
                host = try store.loadHost(for: source)
            } catch {
                errorMessage = "加载源失败：\(error.localizedDescription)"
            }
        }
    }
}
