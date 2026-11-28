// WidgetCrypto.swift — Widget.crypto 原生解密/编解码桥（run #35 第二轮，二进制桥）
//
// 给 JS 模块的通用原生解密接口（Widget.crypto）。朋友的"二进制桥"是解密绕付费墙
// 的东西，专为海角站做的；咱们先做通用接口留着，具体解什么打站时再发现。
//
// 设计（2026-11-28，三家 AI 评审定稿，见 round30-pack/crypto-design-brief.md）：
// - 只新增 Widget.crypto 一个命名空间，不动现有 Widget.* 接口。
// - JS 侧只传字符串（utf8/base64/hex/base64url），原生侧做编码转换；不传 ArrayBuffer
//   （裸 JSContext 没有 TextEncoder/TextDecoder）。
// - 编码按字段显式声明（inputEncoding/keyEncoding/ivEncoding/outputEncoding，
//   GCM 加 tagEncoding/aadEncoding），不自动识别；编码名大小写不敏感，"utf-8" 归一 "utf8"。
// - 错误分两类：参数/契约错 → JS TypeError；解密/认证失败 → JS Error + 稳定 code。
//   绝不静默返回 null/空串/原样数据。
// - 总长度护栏 5MB；randomBytes n 限定 0..65536。
// - CBC/ECB 用 CommonCrypto CCCrypt；CTR 用 ECB 加密计数器块 + XOR 手工实现
//   （CCCryptorCreateWithMode 虽在公开头文件 CommonCryptor.h 里（Gemini 核实），
//   但 ECB+计数器是标准的 CTR 构造，更简单、可验证，用 NIST 测试向量验证）；
//   GCM 用 CryptoKit AES.GCM，SealedBox(nonce:ciphertext:tag:) 手工拆分
//   （combined 只适用于 12 字节 nonce；16 字节 nonce 必须手工拆）。
// - 空 Data 传 C API 可能为 nil 指针：入口用 1 字节 dummy 指针处理。
//
// 本文件只放原生原语（thin primitives），输入输出全是 base64 字符串（二进制安全边界）。
// 友好的 Widget.crypto.* API（按字段编码、校验、错误映射、GCM tag/aad 组装）在
// Core/WidgetCrypto.js.txt（JS 胶水）里实现，沙箱 harness 用 Node crypto 做 mock 验证它。
// Swift 原语本身靠代码审查 + 三家 AI 评审 + 真机/模块验证（本机无 Swift 工具链）。

import Foundation
import CommonCrypto
import CryptoKit
import JavaScriptCore
import Security

/// Widget.crypto 原生原语。所有方法只做一件事：把 base64 字符串解成 Data，
/// 调原生 crypto，返回 base64/hex 字符串。参数校验（长度、mode、padding）由
/// JS 胶水做（它能报出字段名和期望值）；这里只做最后一道防线（防止 JS 胶水被绕过）。
enum WidgetCrypto {

    // MARK: - 错误（内部用；JS 胶水按 code 映射成 TypeError / Error）

    enum CryptoError: Error {
        /// 参数/契约错（JS 侧映射为 TypeError）。
        case invalidParameter(String)
        /// 运行时失败（JS 侧映射为 Error + code）。
        case failure(code: String, message: String)
        /// 超出护栏（JS 侧映射为 RangeError）。
        case outOfRange(String)
    }

    // MARK: - 常量

    /// 单次输入总长度护栏（5MB，按解码后的字节数计，与 JS 胶水 MAX_INPUT_BYTES 同口径）。
    static let maxInputBytes = 5 * 1024 * 1024
    /// randomBytes 的 n 上限。
    static let maxRandomBytes = 65536
    /// GCM tag 固定 16 字节。
    static let gcmTagLength = 16

    /// JS 胶水脚本进程级缓存：install 每次都读盘没必要，读一次缓存起来。
    /// 读不到为 nil（install 直接打日志 return，不注册原语）。
    static let glueScript: String? = {
        guard let url = Bundle.main.url(forResource: "WidgetCrypto", withExtension: "js.txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    // MARK: - base64 / hex 编解码（原语边界用）

    static func dataFromBase64(_ s: String) -> Data? {
        // 容忍缺 "=" 填充（视频站常省略）：按 4 对齐补 "="。
        var t = s
        let rem = t.count % 4
        if rem != 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }

    static func hexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AES

    /// AES 加密。mode: "CBC" | "ECB" | "CTR" | "GCM"。
    /// padding: "pkcs7" | "none" | "zero"（CTR/GCM 只认 "none"，传 pkcs7/zero 由 JS 胶水拦）。
    /// 返回 (ciphertext, tag)：GCM 时 tag 为 16 字节，其余 mode tag 为 nil。
    /// data/key/iv/aad 全是 Data（二进制），调用方（JS 胶水）负责按字段编码解码。
    static func aesEncrypt(data: Data, key: Data, iv: Data?, mode: String, padding: String, aad: Data?) throws -> (ciphertext: Data, tag: Data?) {
        switch mode.uppercased() {
        case "GCM":
            return try aesGCMEncrypt(data: data, key: key, iv: iv, aad: aad)
        case "CTR":
            let ct = try aesCTRCrypt(data: data, key: key, iv: iv)
            return (ct, nil)
        case "CBC", "ECB":
            let ct = try aesCCCrypt(data: data, key: key, iv: iv, encrypt: true, mode: mode, padding: padding)
            return (ct, nil)
        default:
            throw CryptoError.invalidParameter("unknown mode: \(mode)")
        }
    }

    /// AES 解密。tag 仅 GCM 用（16 字节）；aad 仅 GCM 用。
    static func aesDecrypt(data: Data, key: Data, iv: Data?, mode: String, padding: String, tag: Data?, aad: Data?) throws -> Data {
        switch mode.uppercased() {
        case "GCM":
            return try aesGCMDecrypt(data: data, key: key, iv: iv, tag: tag, aad: aad)
        case "CTR":
            return try aesCTRCrypt(data: data, key: key, iv: iv)
        case "CBC", "ECB":
            return try aesCCCrypt(data: data, key: key, iv: iv, encrypt: false, mode: mode, padding: padding)
        default:
            throw CryptoError.invalidParameter("unknown mode: \(mode)")
        }
    }

    // MARK: CBC / ECB（CommonCrypto CCCrypt 一次性接口）

    private static func aesCCCrypt(data: Data, key: Data, iv: Data?, encrypt: Bool, mode: String, padding: String) throws -> Data {
        // key 长度最后一道防线（JS 胶水已按解码后字节数校验）。
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.invalidParameter("key must be 16, 24 or 32 bytes, got \(key.count)")
        }
        let isECB = mode.uppercased() == "ECB"
        // iv 绑定到函数作用域：ECB 必须为空；CBC 必须 16 字节（本函数只处理 CBC/ECB，
        // CTR 走 aesCTRCrypt、自有校验）。缺 iv 直接抛错，
        // 绝不静默补全零 iv（"不自动补零"是本文件的原则；防御性默认值最容易被将来的
        // 改动绕过）。后面 ivBytes 直接用 iv16，不再写 ?? 兜底。
        let iv16: Data?
        if isECB {
            // ECB 传非空 iv 直接错（JS 胶水已拦，这里是防线）。
            if let iv = iv, !iv.isEmpty {
                throw CryptoError.invalidParameter("ECB must not carry an iv")
            }
            iv16 = nil
        } else {
            guard let v = iv, v.count == 16 else {
                throw CryptoError.invalidParameter("CBC iv must be 16 bytes")
            }
            iv16 = v
        }
        // padding:'none' 时数据长度必须是 16 的倍数（加密）；解密同样（CCCrypt 会报）。
        let pad = padding.lowercased()
        var options: CCOptions = 0
        if pad == "pkcs7" {
            options |= CCOptions(kCCOptionPKCS7Padding)
        } else if pad == "none" {
            // 不传 PKCS7 选项即无填充。
        } else if pad == "zero" {
            // zero padding：CCCrypt 不直接支持；JS 胶水已把数据补零到 16 倍数，
            // 这里按 none 处理（不传 PKCS7）。
        } else {
            throw CryptoError.invalidParameter("unknown padding: \(padding)")
        }
        if isECB { options |= CCOptions(kCCOptionECBMode) }

        // 解密 + pkcs7 + 空数据：合法 PKCS7 密文至少 16 字节；空密文直接报 BAD_PADDING，
        // 别依赖底层 CCCrypt 对 0 字节输入的行为（不同版本行为有差异，未验证）。
        if !encrypt && pad == "pkcs7" && data.isEmpty {
            throw CryptoError.failure(code: "CRYPTO_BAD_PADDING", message: "empty ciphertext with pkcs7 padding")
        }

        let algorithm = CCAlgorithm(kCCAlgorithmAES)
        let op: CCOperation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        // 输出 buffer：加密 pkcs7 时最多 +16；解密不超过输入。
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var outLength: Int = 0
        // 空 Data 传 C API 可能为 nil 指针：用 1 字节 dummy 兜底。
        let dataBytes: [UInt8] = data.isEmpty ? [0] : [UInt8](data)
        let keyBytes: [UInt8] = [UInt8](key)
        // ivBytes 必须是非可选 [UInt8]：Swift 的数组→指针隐式转换只支持非可选数组，
        // [UInt8]? 传给 CCCrypt 的 iv: UnsafeRawPointer? 是编译错。ECB 传空数组
        // （ECB 忽略 iv，传什么都不影响结果）；其余传 iv16（上面 guard 已保证 16 字节，
        // 缺 iv 到不了这里——else 分支走不到，但编译器要求穷尽，仍显式抛错，绝不补零）。
        let ivBytes: [UInt8]
        if isECB {
            ivBytes = []
        } else if let v = iv16 {
            ivBytes = [UInt8](v)
        } else {
            throw CryptoError.invalidParameter("CBC iv must be 16 bytes")
        }
        let status: CCStatus = out.withUnsafeMutableBytes { outPtr in
            CCCrypt(
                op, algorithm, options,
                keyBytes, key.count,
                ivBytes,
                dataBytes, data.count,
                outPtr.baseAddress, outCapacity,
                &outLength
            )
        }
        // CCStatus 是 Int32，kCCSuccess/kCCAlignmentError/kCCDecodeError 是无类型 C 枚举，
        // Swift 导入为 Int——直接比较是类型不匹配的编译错，必须用 CCStatus(...) 包装。
        guard status == CCStatus(kCCSuccess) else {
            // 坏 padding 是 kCCDecodeError；对齐错是 kCCAlignmentError；其余（参数/内存/缓冲）
            // 不是 padding 问题，报 CRYPTO_OS_ERROR，别一律扣成 BAD_PADDING。
            let code: String
            switch status {
            case CCStatus(kCCAlignmentError): code = "CRYPTO_ALIGNMENT_ERROR"
            case CCStatus(kCCDecodeError): code = "CRYPTO_BAD_PADDING"
            default: code = "CRYPTO_OS_ERROR"
            }
            throw CryptoError.failure(code: code, message: "CCCrypt failed with status \(status)")
        }
        out.count = outLength
        return out
    }

    // MARK: CTR（ECB 批量加密计数器块 + XOR，标准 CTR 构造）
    //
    // CCCryptorCreateWithMode 在公开头文件 CommonCryptor.h 里（Gemini 核实），但为稳妥
    // 仍用肯定公开的 CCCrypt(ECB) 做计数器加密——ECB+计数器就是标准 CTR，NIST 向量验证。
    // 性能：把所有计数器块拼成一个 Data 单次 ECB 加密（不再每块调一次 CCCrypt；
    // 5MB 要调 327,680 次会卡死同步 JS 线程）。计数器 16 字节大端整体递增，每块 +1，
    // 全 FF 回绕到全 0（计数器可从接近上限的值开始，回绕必须正确）。

    private static func aesCTRCrypt(data: Data, key: Data, iv: Data?) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.invalidParameter("key must be 16, 24 or 32 bytes, got \(key.count)")
        }
        guard let iv = iv, iv.count == 16 else {
            throw CryptoError.invalidParameter("CTR iv must be 16 bytes")
        }
        if data.isEmpty { return Data() }
        let blockCount = (data.count + 15) / 16
        // 所有计数器块拼成一个 Data（每块 = 当前计数器，16 字节大端，+1）。
        var counterBlocks = Data(capacity: blockCount * 16)
        var counter = [UInt8](iv)
        for _ in 0..<blockCount {
            counterBlocks.append(contentsOf: counter)
            var j = 15
            while j >= 0 {
                if counter[j] == 0xFF {
                    counter[j] = 0
                    j -= 1
                } else {
                    counter[j] += 1
                    break
                }
            }
        }
        // 单次 ECB 加密全部计数器块（无填充；长度是 16 的倍数），得到 keystream。
        let keystream = try aesCCCrypt(data: counterBlocks, key: key, iv: nil, encrypt: true, mode: "ECB", padding: "none")
        // XOR（最后一块不足 16 字节时只取 keystream 的前 n 字节，不补齐）。
        // 转 [UInt8] 再索引：Data[i] 假定 startIndex == 0，传 Data 切片会越界；
        // [UInt8] 既安全又更快。
        let dataBytes = [UInt8](data)
        let ksBytes = [UInt8](keystream)
        var out = Data(capacity: data.count)
        for i in 0..<data.count {
            out.append(dataBytes[i] ^ ksBytes[i])
        }
        return out
    }

    // MARK: GCM（CryptoKit AES.GCM）

    private static func aesGCMEncrypt(data: Data, key: Data, iv: Data?, aad: Data?) throws -> (ciphertext: Data, tag: Data?) {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.invalidParameter("key must be 16, 24 or 32 bytes, got \(key.count)")
        }
        guard let iv = iv, iv.count == 12 || iv.count == 16 else {
            throw CryptoError.invalidParameter("GCM nonce must be 12 or 16 bytes")
        }
        let symKey = SymmetricKey(data: key)
        let nonce: AES.GCM.Nonce
        do {
            // Nonce(data:) 只在长度 <12 字节时抛错（Apple 文档 + swift-crypto Nonces.swift
            // 核实），12 或 16 字节都接受；真机再用 16 字节 nonce 的已知向量做 seal/open 互操作确认。
            nonce = try AES.GCM.Nonce(data: iv)
        } catch {
            // 系统错误不拼进给模块的消息（固定文案 + 日志记详情，避免万一带出敏感内容）。
            print("[WidgetCrypto] invalid GCM nonce: \(error)")
            throw CryptoError.invalidParameter("invalid GCM nonce")
        }
        do {
            let sealed = try AES.GCM.seal(data, using: symKey, nonce: nonce, authenticating: aad ?? Data())
            return (sealed.ciphertext, sealed.tag)
        } catch {
            print("[WidgetCrypto] GCM seal failed: \(error)")
            throw CryptoError.failure(code: "CRYPTO_OS_ERROR", message: "GCM seal failed")
        }
    }

    private static func aesGCMDecrypt(data: Data, key: Data, iv: Data?, tag: Data?, aad: Data?) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw CryptoError.invalidParameter("key must be 16, 24 or 32 bytes, got \(key.count)")
        }
        guard let iv = iv, iv.count == 12 || iv.count == 16 else {
            throw CryptoError.invalidParameter("GCM nonce must be 12 or 16 bytes")
        }
        guard let tag = tag, tag.count == gcmTagLength else {
            throw CryptoError.invalidParameter("GCM tag must be 16 bytes")
        }
        let symKey = SymmetricKey(data: key)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: iv)
        } catch {
            // 系统错误不拼进给模块的消息（固定文案 + 日志记详情，避免万一带出敏感内容）。
            print("[WidgetCrypto] invalid GCM nonce: \(error)")
            throw CryptoError.invalidParameter("invalid GCM nonce")
        }
        // SealedBox 手工拆分（不用 combined：16 字节 nonce 时 combined 为 nil）。
        // SealedBox(nonce:ciphertext:tag:) 是 throwing 初始化器（tag 长度不对就抛），
        // 必须 try，不能裸调——裸调是编译错（ChatGPT R12 抓到的第二处真编译错）。
        // 构造参数错与认证失败分开报：前者 invalidParameter，后者 CRYPTO_AUTH_FAILED。
        // （tag 长度前面已校验过 16 字节，正常不应抛，但编译器只认签名，必须 try。）
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: tag)
        } catch {
            print("[WidgetCrypto] invalid GCM sealed box: \(error)")
            throw CryptoError.invalidParameter("invalid GCM sealed box")
        }
        do {
            return try AES.GCM.open(box, using: symKey, authenticating: aad ?? Data())
        } catch {
            // 只有认证失败才报 CRYPTO_AUTH_FAILED；其他错误（如参数错）报 CRYPTO_OS_ERROR，
            // 别把参数错误报成认证失败（诊断准确是验收项之一）。
            // 注意：catch 的 error 是 Error 类型，枚举 case 模式不能直接匹配它——必须先
            // as? 转成 CryptoKitError 再匹配，否则是编译错（ChatGPT R15 指出的风险）。
            if let cryptoError = error as? CryptoKitError, case .authenticationFailure = cryptoError {
                throw CryptoError.failure(code: "CRYPTO_AUTH_FAILED", message: "GCM authentication failed")
            }
            print("[WidgetCrypto] GCM open failed: \(error)")
            throw CryptoError.failure(code: "CRYPTO_OS_ERROR", message: "GCM open failed")
        }
    }

    // MARK: XOR

    static func xor(data: Data, key: Data) throws -> Data {
        // 空 key 取模会除零崩溃；且空 key 时原样返回数据是静默失败，必须抛错。
        // （JS 胶水已拦空 key，这里是最后一道防线。）
        guard !key.isEmpty else {
            throw CryptoError.invalidParameter("key must not be empty")
        }
        let keyBytes = [UInt8](key)
        var out = Data(capacity: data.count)
        for (i, byte) in data.enumerated() {
            out.append(byte ^ keyBytes[i % keyBytes.count])
        }
        return out
    }

    // MARK: Hash / HMAC

    /// algorithm: "md5" | "sha1" | "sha256" | "sha512"。返回原始摘要字节。
    static func hash(algorithm: String, data: Data) throws -> Data {
        switch algorithm.lowercased() {
        case "md5":
            return Data(Insecure.MD5.hash(data: data))
        case "sha1":
            return Data(Insecure.SHA1.hash(data: data))
        case "sha256":
            return Data(SHA256.hash(data: data))
        case "sha512":
            return Data(SHA512.hash(data: data))
        default:
            throw CryptoError.invalidParameter("unknown hash algorithm: \(algorithm)")
        }
    }

    /// algorithm: "md5" | "sha1" | "sha256" | "sha512"。返回原始 MAC 字节。
    static func hmac(algorithm: String, data: Data, key: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        switch algorithm.lowercased() {
        case "md5":
            // CryptoKit 没有 HMAC-MD5；用 CommonCrypto CCHmac。
            // kCCHmacAlgMD5 是无类型 C 枚举（Swift 导入为 Int），CCHmacAlgorithm 是 UInt32——
            // 直接传是类型不匹配的编译错，必须包装。
            return hmacCC(algorithm: CCHmacAlgorithm(kCCHmacAlgMD5), data: data, key: key)
        case "sha1":
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symKey)
            return Data(mac)
        case "sha256":
            let mac = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
            return Data(mac)
        case "sha512":
            let mac = HMAC<SHA512>.authenticationCode(for: data, using: symKey)
            return Data(mac)
        default:
            throw CryptoError.invalidParameter("unknown hmac algorithm: \(algorithm)")
        }
    }

    /// CommonCrypto CCHmac（仅 MD5 用；SHA-1/256/512 走 CryptoKit）。
    private static func hmacCC(algorithm: CCHmacAlgorithm, data: Data, key: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: 16)
        let dataBytes: [UInt8] = data.isEmpty ? [0] : [UInt8](data)
        let keyBytes: [UInt8] = key.isEmpty ? [0] : [UInt8](key)
        CCHmac(algorithm, keyBytes, key.count, dataBytes, data.count, &mac)
        return Data(mac)
    }

    // MARK: Random

    static func randomBytes(count: Int) throws -> Data {
        guard count >= 0 && count <= maxRandomBytes else {
            throw CryptoError.outOfRange("randomBytes count must be 0...\(maxRandomBytes), got \(count)")
        }
        if count == 0 { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw CryptoError.failure(code: "CRYPTO_OS_ERROR", message: "SecRandomCopyBytes failed with status \(status)")
        }
        return Data(bytes)
    }
}

// MARK: - JSContext 注册（Widget.crypto 的原生原语）
//
// 在 WidgetHost.installWidgetBridge 末尾调用一次：
//   WidgetCrypto.install(into: context)
// 它只做两件事：
//  1. 把 6 个原语挂成全局函数 __fwCryptoAESEncrypt / __fwCryptoAESDecrypt /
//     __fwCryptoXOR / __fwCryptoHash / __fwCryptoHMAC / __fwCryptoRandomBytes。
//  2. 评估 Core/WidgetCrypto.js.txt 胶水，由它组装出 Widget.crypto.* 友好 API。
// 原语的输入输出全是 base64 字符串（data/key/iv/tag/aad/result），二进制安全；
// 编码转换、字段校验、错误映射全在 JS 胶水里（沙箱 harness 可验证）。
// 原语返回 NSDictionary：{ok: true, result: String} 或 {ok: false, code, message}。
// code 约定：INVALID_PARAMETER（参数错 → JS TypeError）、RANGE（超限 → JS RangeError）、
// 其余为运行时 code（CRYPTO_* → JS Error + .code）。

extension WidgetCrypto {

    static func install(into context: JSContext) {
        // 胶水读不到直接 return：不注册原语，不留半成品（Widget.crypto 不存在，
        // 模块调它会明确报“不可用”，而不是拿到一个只有部分方法的对象）。
        guard let glue = glueScript else {
            print("[WidgetCrypto] WidgetCrypto.js.txt 读不到，Widget.crypto 不可用")
            return
        }
        // 删除 6 个全局原语：无论胶水成没成、挂没挂，都要删。放进 defer，保证所有返回
        // 路径都覆盖（胶水提前返回、评估抛异常、将来加的 early return 都不会漏）。
        // defer 在函数返回时执行，此时胶水已评完（原语已收进闭包），删全局不影响
        // 胶水内部调用。注意：guard 读不到胶水时提前 return，那时还没注册原语，
        // defer 不会执行（defer 声明在 guard 之后），没有要删的东西。
        defer {
            // 'use strict'：非严格模式下 delete 不可配置属性会静默失败；严格模式抛错，能被发现。
            // 删完断言 6 个全局确实没了（模块里 typeof __fwCryptoHash 应为 'undefined'）。
            context.evaluateScript("'use strict'; delete this.__fwCryptoAESEncrypt; delete this.__fwCryptoAESDecrypt; delete this.__fwCryptoXOR; delete this.__fwCryptoHash; delete this.__fwCryptoHMAC; delete this.__fwCryptoRandomBytes;")
            if let exc = context.exception {
                print("[WidgetCrypto] delete globals failed: \(exc)")
                context.exception = nil
            } else if let left = context.evaluateScript("typeof __fwCryptoAESEncrypt + ',' + typeof __fwCryptoAESDecrypt + ',' + typeof __fwCryptoXOR + ',' + typeof __fwCryptoHash + ',' + typeof __fwCryptoHMAC + ',' + typeof __fwCryptoRandomBytes")?.toString(), left != "undefined,undefined,undefined,undefined,undefined,undefined" {
                print("[WidgetCrypto] globals not deleted: \(left)")
                #if DEBUG
                // DEBUG 构建里直接断言：原语删不掉是安全问题，别只打一条日志就过去。
                assertionFailure("WidgetCrypto globals not deleted: \(left)")
                #endif
            }
        }
        // 统一的错误字典。
        func errDict(_ error: CryptoError) -> NSDictionary {
            switch error {
            case .invalidParameter(let m):
                return ["ok": false, "code": "INVALID_PARAMETER", "message": m]
            case .outOfRange(let m):
                return ["ok": false, "code": "RANGE", "message": m]
            case .failure(let code, let message):
                return ["ok": false, "code": code, "message": message]
            }
        }

        // AES 加密：(dataB64, keyB64, ivB64|nil, mode, padding, aadB64|nil)
        // → {ok, ciphertext, tag?}（tag 仅 GCM 有，为 base64；其余 mode 无 tag 键）。
        // 局部名必须加 Block 后缀：直接叫 aesEncrypt 会遮蔽同名静态方法，闭包里调
        // aesEncrypt(data:...) 解析到正在初始化的局部变量本身，是编译错。
        let aesEncryptBlock: @convention(block) (String, String, String?, String, String, String?) -> NSDictionary = { dataB64, keyB64, ivB64, mode, padding, aadB64 in
            do {
                guard let data = dataFromBase64(dataB64), let key = dataFromBase64(keyB64) else {
                    throw CryptoError.invalidParameter("invalid base64 input")
                }
                guard data.count <= maxInputBytes else {
                    throw CryptoError.outOfRange("input exceeds \(maxInputBytes) bytes")
                }
                let iv = ivB64.flatMap { dataFromBase64($0) }
                if ivB64 != nil && iv == nil { throw CryptoError.invalidParameter("invalid base64 iv") }
                let aad = aadB64.flatMap { dataFromBase64($0) }
                if aadB64 != nil && aad == nil { throw CryptoError.invalidParameter("invalid base64 aad") }
                // aad 也受 5MB 护栏（JS 胶水已拦，这里是最后一道防线）。
                if let aad = aad, aad.count > maxInputBytes {
                    throw CryptoError.outOfRange("aad exceeds \(maxInputBytes) bytes")
                }
                let (ct, tag) = try Self.aesEncrypt(data: data, key: key, iv: iv, mode: mode, padding: padding, aad: aad)
                var d: [String: Any] = ["ok": true, "ciphertext": ct.base64EncodedString()]
                if let tag = tag { d["tag"] = tag.base64EncodedString() }
                return d as NSDictionary
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        // AES 解密：(dataB64, keyB64, ivB64|nil, mode, padding, tagB64|nil, aadB64|nil)
        // → {ok, plaintext}（plaintext 为 base64）。
        let aesDecryptBlock: @convention(block) (String, String, String?, String, String, String?, String?) -> NSDictionary = { dataB64, keyB64, ivB64, mode, padding, tagB64, aadB64 in
            do {
                guard let data = dataFromBase64(dataB64), let key = dataFromBase64(keyB64) else {
                    throw CryptoError.invalidParameter("invalid base64 input")
                }
                guard data.count <= maxInputBytes else {
                    throw CryptoError.outOfRange("input exceeds \(maxInputBytes) bytes")
                }
                let iv = ivB64.flatMap { dataFromBase64($0) }
                if ivB64 != nil && iv == nil { throw CryptoError.invalidParameter("invalid base64 iv") }
                let tag = tagB64.flatMap { dataFromBase64($0) }
                if tagB64 != nil && tag == nil { throw CryptoError.invalidParameter("invalid base64 tag") }
                let aad = aadB64.flatMap { dataFromBase64($0) }
                if aadB64 != nil && aad == nil { throw CryptoError.invalidParameter("invalid base64 aad") }
                if let aad = aad, aad.count > maxInputBytes {
                    throw CryptoError.outOfRange("aad exceeds \(maxInputBytes) bytes")
                }
                let pt = try Self.aesDecrypt(data: data, key: key, iv: iv, mode: mode, padding: padding, tag: tag, aad: aad)
                return ["ok": true, "plaintext": pt.base64EncodedString()]
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        // XOR：(dataB64, keyB64) → {ok, result}（result 为 base64）。
        let xorBlock: @convention(block) (String, String) -> NSDictionary = { dataB64, keyB64 in
            guard let data = dataFromBase64(dataB64), let key = dataFromBase64(keyB64) else {
                return ["ok": false, "code": "INVALID_PARAMETER", "message": "invalid base64 input"]
            }
            guard data.count <= maxInputBytes else {
                return ["ok": false, "code": "RANGE", "message": "input exceeds \(maxInputBytes) bytes"]
            }
            // key 也受 5MB 护栏（JS 胶水已拦，这里是最后一道防线）。
            guard key.count <= maxInputBytes else {
                return ["ok": false, "code": "RANGE", "message": "key exceeds \(maxInputBytes) bytes"]
            }
            do {
                return ["ok": true, "result": try xor(data: data, key: key).base64EncodedString()]
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        // Hash：(algorithm, dataB64) → {ok, result}（result 为 hex 小写）。
        let hashBlock: @convention(block) (String, String) -> NSDictionary = { algorithm, dataB64 in
            do {
                guard let data = dataFromBase64(dataB64) else {
                    throw CryptoError.invalidParameter("invalid base64 input")
                }
                guard data.count <= maxInputBytes else {
                    throw CryptoError.outOfRange("input exceeds \(maxInputBytes) bytes")
                }
                return ["ok": true, "result": hexString(try hash(algorithm: algorithm, data: data))]
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        // HMAC：(algorithm, dataB64, keyB64) → {ok, result}（result 为 hex 小写）。
        let hmacBlock: @convention(block) (String, String, String) -> NSDictionary = { algorithm, dataB64, keyB64 in
            do {
                guard let data = dataFromBase64(dataB64), let key = dataFromBase64(keyB64) else {
                    throw CryptoError.invalidParameter("invalid base64 input")
                }
                guard data.count <= maxInputBytes else {
                    throw CryptoError.outOfRange("input exceeds \(maxInputBytes) bytes")
                }
                guard key.count <= maxInputBytes else {
                    throw CryptoError.outOfRange("key exceeds \(maxInputBytes) bytes")
                }
                return ["ok": true, "result": hexString(try hmac(algorithm: algorithm, data: data, key: key))]
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        // Random：(n) → {ok, result}（result 为 base64）。
        let randomBlock: @convention(block) (Int) -> NSDictionary = { n in
            do {
                return ["ok": true, "result": try randomBytes(count: n).base64EncodedString()]
            } catch let e as CryptoError {
                return errDict(e)
            } catch {
                return ["ok": false, "code": "CRYPTO_OS_ERROR", "message": "\(error)"]
            }
        }

        context.setObject(aesEncryptBlock as @convention(block) (String, String, String?, String, String, String?) -> NSDictionary, forKeyedSubscript: "__fwCryptoAESEncrypt" as NSString)
        context.setObject(aesDecryptBlock as @convention(block) (String, String, String?, String, String, String?, String?) -> NSDictionary, forKeyedSubscript: "__fwCryptoAESDecrypt" as NSString)
        context.setObject(xorBlock as @convention(block) (String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoXOR" as NSString)
        context.setObject(hashBlock as @convention(block) (String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoHash" as NSString)
        context.setObject(hmacBlock as @convention(block) (String, String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoHMAC" as NSString)
        context.setObject(randomBlock as @convention(block) (Int) -> NSDictionary, forKeyedSubscript: "__fwCryptoRandomBytes" as NSString)

        // JS 胶水（Core/WidgetCrypto.js.txt，进程级缓存 glueScript）：组装
        // Widget.crypto.* 友好 API。胶水评完后删掉全局上的 6 个原语：胶水已把它们
        // 收进闭包局部变量，删全局不影响胶水内部调用，但模块就调不到原语、绕不过
        // 胶水的校验。无论胶水成没成，最后都删全局原语：成则胶水已收进闭包（删了不
        // 影响胶水内部调用）；不成则不留半成品——Widget.crypto 不存在，模块调它会
        // 明确报“不可用”，而不是拿到一个只有部分方法的对象。胶水是单个 IIFE，
        // 抛错就整段不挂载，不存在“挂一半”。
        context.evaluateScript(glue, withSourceURL: URL(string: "host://WidgetCrypto.js.txt"))
        // 胶水评完检查 exception（全构建打日志，别只靠 WidgetHost 的 DEBUG 打印）。
        if let exc = context.exception {
            print("[WidgetCrypto] glue failed: \(exc)")
            context.exception = nil
        }
    }
}
