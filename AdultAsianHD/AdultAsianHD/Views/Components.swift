// Components.swift — 共用小组件（v2 重建）

import CommonCrypto
import CryptoKit
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

// MARK: - 封面加载（带重试 + 解密 + 内存/磁盘二级缓存）

/// 封面二级缓存：
/// - L1 内存（NSCache，限 200 张 / 40MB，主线程零延迟命中）；
/// - L2 磁盘（Library/Caches/CoverImageCache/<sha256>.img，存已解密/解码后的图片字节，
///   重启或内存回收后直接读盘、不再抢视频带宽，且免去黄果封面重复 AES 解密）；
/// - 容量上限 100MB、最长保留 14 天，按访问时间 LRU 异步淘汰。
final class CoverImageCache: @unchecked Sendable {
    static let shared = CoverImageCache()

    static let maxDiskBytes: Int64 = 100 * 1024 * 1024 // 100 MB
    static let targetDiskBytes: Int64 = 80 * 1024 * 1024 // 淘汰回落到 80 MB，避免频繁触发
    static let maxDiskAge: TimeInterval = 14 * 24 * 3600 // 14 天

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL
    private let ioQueue = DispatchQueue(label: "com.liudehen.xiaoshipin.covercache.io", qos: .utility)
    private var writesSinceCleanup = 0

    private init() {
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 40 * 1024 * 1024

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.diskDirectory = cachesDir.appendingPathComponent("CoverImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        // 启动后后台做一次过期/超容巡检（不挡首屏）
        ioQueue.async { [weak self] in
            self?.evictDiskIfNeeded()
        }
    }

    /// 同步查 L1 内存缓存（快速路径，无闪烁）。
    func image(for key: String) -> UIImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// 先查 L1 内存，未命中再异步读 L2 磁盘并回填 L1；均未命中返回 nil（调用方才发网络请求）。
    func cachedImage(for key: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }
        let fileURL = diskFileURL(for: key)
        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let data = try? Data(contentsOf: fileURL),
                      var uiImage = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                // 磁盘解出的图预渲染一次再回填 L1/上屏，避免主线程首次绘制卡顿。
                if let prepared = uiImage.preparingForDisplay() {
                    uiImage = prepared
                }
                // 更新修改时间用于 LRU 淘汰
                var mutableURL = fileURL
                var values = URLResourceValues()
                values.contentModificationDate = Date()
                try? mutableURL.setResourceValues(values)

                self.memoryCache.setObject(uiImage, forKey: key as NSString, cost: Self.memoryCost(of: uiImage))
                continuation.resume(returning: uiImage)
            }
        }
    }

    /// 存 L1 内存 + 异步写 L2 磁盘。
    /// rawDecodedData：已解密/校验好的原图片字节（直接落盘，零重压缩损失）；未传时自动转 JPEG 0.85。
    func store(_ image: UIImage, rawDecodedData: Data? = nil, for key: String) {
        memoryCache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))
        let fileURL = diskFileURL(for: key)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let payload: Data? = rawDecodedData ?? image.jpegData(compressionQuality: 0.85)
            guard let payload, !payload.isEmpty else { return }
            try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
            try? payload.write(to: fileURL, options: .atomic)
            self.writesSinceCleanup += 1
            if self.writesSinceCleanup >= 25 {
                self.writesSinceCleanup = 0
                self.evictDiskIfNeeded()
            }
        }
    }

    /// 兼容旧签名（直接存 UIImage）。
    func store(_ image: UIImage, for key: String) {
        store(image, rawDecodedData: nil, for: key)
    }

    /// 清空封面内存与磁盘缓存。
    func clearAll() {
        memoryCache.removeAllObjects()
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.diskDirectory)
            try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        }
    }

    private func diskFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hex + ".img")
    }

    private static func memoryCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// 磁盘 LRU + TTL 淘汰（只在 ioQueue 调用）。
    private func evictDiskIfNeeded() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var totalSize: Int64 = 0

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let modDate = values.contentModificationDate ?? .distantPast
            let size = Int64(values.fileSize ?? 0)
            if now.timeIntervalSince(modDate) > Self.maxDiskAge {
                try? fm.removeItem(at: url)
                continue
            }
            totalSize += size
            entries.append((url: url, size: size, date: modDate))
        }

        guard totalSize > Self.maxDiskBytes else { return }
        // 最久未访问的先删，直到回落至 targetDiskBytes 以下
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard totalSize > Self.targetDiskBytes else { break }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }
}

/// 封面图：替代裸 AsyncImage。
/// 优先读 CoverImageCache（内存 → 磁盘），都未命中才走专用低并发 URLSession 拉图（不和视频抢带宽）；
/// 失败 0.5 秒后重试一次，拉到的字节过 CryptoImage.decodeCover（黄果密文自动解密）后同时写入内存与磁盘。
struct CoverImage: View {
    let urlString: String?
    @State private var image: UIImage?

    /// 封面专用会话：限每域 4 并发（不抢视频分片带宽）、关掉 URLCache 避免和 CoverImageCache 重复写盘。
    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 图床域名 → 站点 Referer（按站配）。
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
              let url = URL(string: urlString) else {
            image = nil
            return
        }
        // 1. 同步查 L1 内存：命中立即显示；未命中先把旧图清掉（cell 复用时
        // 不闪上一张图的旧封面），再走异步 L2/网络路径。
        if let mem = CoverImageCache.shared.image(for: urlString) {
            image = mem
            return
        }
        image = nil
        // 2. L2 磁盘，命中直接显示，绝不发网络请求
        if let cached = await CoverImageCache.shared.cachedImage(for: urlString) {
            if !Task.isCancelled { image = cached }
            return
        }
        // 3. 缓存均未命中：带 UA + Referer 拉图，禁用 HTTP/3 规避无节点 UDP 443 卡顿。
        // 4xx（图不存在/没权限）直接放弃不重试；5xx/网络错 500ms 后重试一次。
        // 解码放 Task.detached（不占主线程），解完 preparingForDisplay 预渲染。
        for attempt in 0..<2 {
            if Task.isCancelled { return }
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.assumesHTTP3Capable = false
                request.setValue(NetConstants.iPhoneUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(Self.referer(for: url), forHTTPHeaderField: "Referer")
                let (data, response) = try await Self.imageSession.data(for: request)
                if Task.isCancelled { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (400..<500).contains(status) { return }
                // 非 200（5xx/网络错的响应）：500ms 退避后再重试一次——
                // 以前 continue 直接重发，等于无退避连打两下。
                guard status == 200 else {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    continue
                }
                // 解密放后台：CryptoImage.decodeCover 是 AES 解密，.task 在主线程跑，
                // 原来直接调等于主线程解密；解完再预渲染（同一次 detached，少一次 hop）。
                let decodedImage = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage)? in
                    guard let decoded = CryptoImage.decodeCover(data),
                          let img = UIImage(data: decoded) else { return nil }
                    return (decoded, img.preparingForDisplay() ?? img)
                }.value
                guard let (decoded, uiImage) = decodedImage else { continue }
                CoverImageCache.shared.store(uiImage, rawDecodedData: decoded, for: urlString)
                if !Task.isCancelled { image = uiImage }
                return
            } catch {
                if Task.isCancelled || attempt == 1 { return }
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
                    Image(systemName: favorites.isFavorite(itemId: item.id, sourceId: sourceId) ? "star.fill" : "star")
                        .foregroundColor(favorites.isFavorite(itemId: item.id, sourceId: sourceId) ? .yellow : .white)
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
