// Components.swift — 共用小组件（v2 重建）

import SwiftUI

/// 封面卡片：AsyncImage 封面（16:9，灰底占位）+ 标题两行截断 + 收藏星标。
/// 点卡片本身由调用方包 NavigationLink；星标是独立按钮，不触发跳转。
struct VideoCard: View {
    let item: VideoItem
    let sourceId: String
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: coverURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    case .failure:
                        Color(.systemGray5)
                    case .empty:
                        Color(.systemGray5)
                    @unknown default:
                        Color(.systemGray5)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    favorites.toggle(item: item, sourceId: sourceId)
                } label: {
                    Image(systemName: favorites.isFavorite(item.id) ? "star.fill" : "star")
                        .foregroundColor(favorites.isFavorite(item.id) ? .yellow : .white)
                        .padding(6)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
            }

            Text(item.title)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var coverURL: URL? {
        guard let raw = item.coverURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 国家框 / 列表分区的小标题。
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 空态：标题 + 说明 + 可选操作按钮。
struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 加载中：转圈 + 一行文字。
struct LoadingView: View {
    var text = "正在加载…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
