// Components.swift — 共用小组件（v2 重建）

import CommonCrypto
import SwiftUI
import UIKit

// MARK: - 加密封面解码（黄果图床）

/// 黄果图床的图是密文：CDN 直接返回 binary/octet-stream、熵 8.0，
/// 明文 <img>/AsyncImage 解不出来（所以黄果网格全是灰框）。
/// 站方自己的解码协议公开下发在 crypto-image-protocol.js 里
/// （浏览器打开站页都会下载这份文件），key/IV 是站内静态值：
/// AES-128-CBC，key/IV 取这两个字符串的 UTF-8（各 16 字节），PKCS7。
/// 实测：神瞳觉醒封面解密后是正常 JPEG（FF D8 开头）。
/// 注意：如果站方轮换 key/IV，解密会失败、封面变回灰框——
/// 到时从同一份协议文件里取新值更新下面两行即可。
enum CryptoImage {
    static let keyString = "f5d965df75336270"
    static let ivString = "97b60394abc2fbe1"

    /// 一段字节是不是常见图片：只看文件头（JPEG/PNG/GIF/WebP）。
    static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 { return true } // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true } // PNG
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 { return true } // GIF
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return true } // WebP
        return false
    }

    /// AES-128-CBC 解密一段数据；失败返回 nil。
    static func decrypt(_ data: Data) -> Data? {
        let key = Data(keyString.utf8)
        let iv = Data(ivString.utf8)
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128,
              data.count > kCCBlockSizeAES128 else { return nil }
        var decrypted = Data(count: data.count + kCCBlockSizeAES128)
        // 注意：decrypted.count 必须在 withUnsafeMutableBytes 之前先取出来。
        // 在闭包里一边持有 decrypted 的可变访问、一边又读 decrypted.count，
        // 会触发 Swift 的排他访问检查（overlapping accesses），编不过。
        let decryptedCapacity = decrypted.count
        var decryptedLength = 0
        let status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                data.withUnsafeBytes { dataPtr in
                    decrypted.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, decryptedCapacity,
                            &decryptedLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, decryptedLength > 0 else { return nil }
        decrypted.count = decryptedLength
        return decrypted
    }

    /// 解码一张封面字节：本身是图片直接用；不是图片就按黄果协议解密一次，
    /// 解出来是图片就用；都不是返回 nil（调用方显示灰色占位）。
    static func decodeCover(_ data: Data) -> Data? {
        if looksLikeImage(data) { return data }
        if let plain = decrypt(data), looksLikeImage(plain) { return plain }
        return nil
    }
}

// MARK: - 封面加载（带重试 + 解密 + 内存缓存）

/// 封面内存缓存（NSCache 本身线程安全）。
final class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 200 }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// 封面图：替代裸 AsyncImage。
/// AsyncImage 不重试、不带请求头、慢网一张失败就一直灰——
/// 黄果的图床本来就慢（沙箱快网拉一张也要 2 秒），4G 下经常首拉失败。
/// 这里 URLSession 带 iPhone UA + 站点 Referer 拉，失败 0.5 秒后重试一次，
/// 拉到的字节过 CryptoImage.decodeCover（黄果密文自动解密），
/// 成功进内存缓存（NSCache；URLSession.shared 自带 URLCache 磁盘缓存，
/// 两级缓存）；失败就一直灰色占位，不报错、不闪。
struct CoverImage: View {
    let urlString: String?
    @State private var image: UIImage?

    /// 图床域名 → 站点 Referer（按站配；四家 AI 一致的 VideoSiteConfig 思路，
    /// 目前就这两家有图床防盗链需要，够了再加）。
    static func referer(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host.contains("qnlycc.cn") { return "https://huangguoai.com/" }
        if host.contains("imgswipe.org") || host.contains("imgswipe.com") { return "https://onlybokep.cam/" }
        if host.isEmpty { return "https://huangguoai.com/" }
        return "https://\(host)/"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
            } else {
                Color(.systemGray5)
            }
        }
        .task(id: urlString) { await load() }
    }

    private func load() async {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString) else { return }
        if let cached = CoverImageCache.shared.image(for: urlString) {
            image = cached
            return
        }
        for attempt in 0..<2 {
            do {
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
                // 防盗链 Referer 按站配（四家 AI 一致：按站点配 imageReferer，
                // 别用裸 AsyncImage）：图床域名 → 它的站。没配到的用图床自己。
                // 实测：黄果图床不带 Referer 也 200，但站内 Referer 更稳；
                // 真正让黄果封面出不来的是密文（见 CryptoImage），不是 Referer。
                request.setValue(Self.referer(for: url), forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                guard let decoded = CryptoImage.decodeCover(data),
                      let uiImage = UIImage(data: decoded) else { continue }
                CoverImageCache.shared.store(uiImage, for: urlString)
                image = uiImage
                return
            } catch {
                if attempt == 1 { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
}

/// 封面卡片：封面（16:9，灰底占位）+ 标题两行截断 + 收藏星标。
/// 点卡片本身由调用方包 NavigationLink；星标是独立按钮，不触发跳转。
struct VideoCard: View {
    let item: VideoItem
    let sourceId: String
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImage(urlString: item.coverURL)
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

/// 宽屏内容容器：窄屏贴边，宽屏（展开的 Duo 内屏 / 横屏）内容限宽 700pt 居中，
/// 两边不再是大黑边。只限宽、不改内容本身；配 systemGroupedBackground 底色，
/// 深色下是柔和深灰而不是纯黑空洞。
struct WideContent<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content.frame(maxWidth: 700)
            Spacer(minLength: 0)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 空态：标题 + 说明 + 可选操作按钮。
/// 上下 Spacer 让内容在可用高度里真正居中（原来只有 minHeight 400 顶在上方，
/// 高屏上就是黑底里一小坨）；图标和标题放大一号，窄屏也不显寒酸。
/// 在 ScrollView 这类无限高度的容器里 Spacer 会缩到 0，内容自然排布，不会撑高。
struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 52))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            .padding()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 底部留白：iOS 26 的悬浮 Tab 栏盖在内容上面。窗口矮的时候（Duo 展开横屏、
        // 浮动窗口）居中后的按钮会正好落到 Tab 栏底下被盖住，留 90pt 把内容顶上去。
        .padding(.bottom, 90)
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
