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

    /// 跨源唯一键（不参与 Codable 持久化，只作列表身份与判重用）：
    /// "\(sourceId)::\(id)"——WordPress 系多源共用递增数字 id，裸 id 会跨源碰撞。
    static func key(itemId: String, sourceId: String) -> String {
        "\(sourceId)::\(itemId)"
    }

    var compositeKey: String {
        Self.key(itemId: id, sourceId: sourceId)
    }

    var videoItem: VideoItem {
        VideoItem(
            id: id, title: title, link: link,
            coverURL: coverURL, description: description, category: category
        )
    }
}

// MARK: - 收藏仓库

@MainActor
final class FavoritesStore: ObservableObject {
    // 与 NetworkDiagnostics / PlaybackLedger / CloudflareWarmup 同款写法：
    // @MainActor 类 + 普通 static let shared，本工程已构建验证过
    // （App 里 @StateObject = FavoritesStore.shared 不用改）。
    static let shared = FavoritesStore()

    private let idsKey = "favoriteIDs"
    private let entriesKey = "favoriteEntriesJSON"

    @Published private(set) var entries: [FavoriteEntry] = []

    /// 复合键集合：isFavorite 从 O(N) 降为 O(1)，与 entries 数组保持同步
    ///（load / toggle / remove 处同步更新）。
    private var favoriteKeys: Set<String> = []

    private init() {
        load()
    }

    func isFavorite(itemId: String, sourceId: String) -> Bool {
        favoriteKeys.contains(FavoriteEntry.key(itemId: itemId, sourceId: sourceId))
    }

    func toggle(item: VideoItem, sourceId: String) {
        let key = FavoriteEntry.key(itemId: item.id, sourceId: sourceId)
        if let index = entries.firstIndex(where: { $0.sourceId == sourceId && $0.id == item.id }) {
            entries.remove(at: index)
            favoriteKeys.remove(key)
        } else {
            entries.append(FavoriteEntry(item: item, sourceId: sourceId))
            favoriteKeys.insert(key)
        }
        save()
    }

    func remove(_ entry: FavoriteEntry) {
        entries.removeAll { $0.sourceId == entry.sourceId && $0.id == entry.id }
        favoriteKeys.remove(entry.compositeKey)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([FavoriteEntry].self, from: data) else {
            entries = []
            favoriteKeys = []
            return
        }
        entries = decoded
        favoriteKeys = Set(decoded.map(\.compositeKey))
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
        WideContent {
            Group {
                if favorites.entries.isEmpty {
                    EmptyState(title: "还没有收藏", message: "在视频封面或详情页点星标，就会出现在这里。")
                } else {
                    List {
                        // 不用默认 Identifiable（entry.id 是裸 item.id，会跨源重复）：
                        // 用 "\(sourceId)::\(id)" 作列表身份。
                        ForEach(favorites.entries, id: \.compositeKey) { entry in
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
                    .scrollContentBackground(.hidden)
                }
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
