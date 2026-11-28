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
//   （CCCryptorCreateWithMode 在 CommonCryptorSPI.h 里，Swift 侧 import CommonCrypto
//   不暴露它；ECB+计数器是标准的 CTR 构造，用 NIST 测试向量验证）；
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

    /// 单次输入总长度护栏（5MB）。
    static let maxInputBytes = 5 * 1024 * 1024
    /// randomBytes 的 n 上限。
    static let maxRandomBytes = 65536
    /// GCM tag 固定 16 字节。
    static let gcmTagLength = 16

    // MARK: - base64 / hex 编解码（原语边界用）

    static func dataFromBase64(_ s: String) -> Data? {
        // 容忍缺 "=" 填充（视频站常省略）：按 4 对齐补 "="。
        var t = s
        let rem = t.count % 4
        if rem != 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }

    static func dataFromBase64URL(_ s: String) -> Data? {
        // Base64URL：- → +，_ → /，再按 base64 解。
        let t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return dataFromBase64(t)
    }

    static func dataFromHex(_ s: String) -> Data? {
        var t = s
        if t.hasPrefix("0x") || t.hasPrefix("0X") { t = String(t.dropFirst(2)) }
        guard t.count % 2 == 0 else { return nil }
        var data = Data(capacity: t.count / 2)
        var idx = t.startIndex
        while idx < t.endIndex {
            let next = t.index(idx, offsetBy: 2)
            guard let byte = UInt8(t[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
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
        if isECB {
            // ECB 传非空 iv 直接错（JS 胶水已拦，这里是防线）。
            if let iv = iv, !iv.isEmpty {
                throw CryptoError.invalidParameter("ECB must not carry an iv")
            }
        } else {
            guard let iv = iv, iv.count == 16 else {
                throw CryptoError.invalidParameter("CBC iv must be 16 bytes")
            }
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

        let algorithm = CCAlgorithm(kCCAlgorithmAES)
        let op: CCOperation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        // 输出 buffer：加密 pkcs7 时最多 +16；解密不超过输入。
        let outCapacity = data.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var outLength: Int = 0
        // 空 Data 传 C API 可能为 nil 指针：用 1 字节 dummy 兜底。
        let dataBytes: [UInt8] = data.isEmpty ? [0] : [UInt8](data)
        let keyBytes: [UInt8] = [UInt8](key)
        let ivBytes: [UInt8]? = (isECB ? nil : (iv.map { [UInt8]($0) } ?? [UInt8](repeating: 0, count: 16)))
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
        guard status == kCCSuccess else {
            // 坏 padding 是 kCCDecodeError；对齐错是 kCCAlignmentError；其余（参数/内存/缓冲）
            // 不是 padding 问题，报 CRYPTO_OS_ERROR，别一律扣成 BAD_PADDING。
            let code: String
            switch status {
            case kCCAlignmentError: code = "CRYPTO_ALIGNMENT_ERROR"
            case kCCDecodeError: code = "CRYPTO_BAD_PADDING"
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
        var out = Data(capacity: data.count)
        for i in 0..<data.count {
            out.append(data[i] ^ keystream[i])
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
            throw CryptoError.invalidParameter("invalid GCM nonce: \(error)")
        }
        do {
            let sealed = try AES.GCM.seal(data, using: symKey, nonce: nonce, authenticating: aad ?? Data())
            return (sealed.ciphertext, sealed.tag)
        } catch {
            throw CryptoError.failure(code: "CRYPTO_OS_ERROR", message: "GCM seal failed: \(error)")
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
            throw CryptoError.invalidParameter("invalid GCM nonce: \(error)")
        }
        // SealedBox 手工拆分（不用 combined：16 字节 nonce 时 combined 为 nil）。
        let box = AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: tag)
        do {
            return try AES.GCM.open(box, using: symKey, authenticating: aad ?? Data())
        } catch {
            // 认证失败：不返回任何明文，统一报 CRYPTO_AUTH_FAILED（不区分细节）。
            throw CryptoError.failure(code: "CRYPTO_AUTH_FAILED", message: "GCM authentication failed")
        }
    }

    // MARK: XOR

    static func xor(data: Data, key: Data) throws -> Data {
        // 空 key 取模会除零崩溃；且空 key 时原样返回数据是静默失败，必须抛错。
        // （JS 胶水已拦空 key，这里是最后一道防线。）
        guard !key.isEmpty else {
            throw CryptoError.invalidParameter("key must not be empty")
        }
        var out = Data(capacity: data.count)
        for (i, byte) in data.enumerated() {
            out.append(byte ^ key[i % key.count])
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
            return hmacCC(algorithm: kCCHmacAlgMD5, data: data, key: key)
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
        let aesEncrypt: @convention(block) (String, String, String?, String, String, String?) -> NSDictionary = { dataB64, keyB64, ivB64, mode, padding, aadB64 in
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
                let (ct, tag) = try aesEncrypt(data: data, key: key, iv: iv, mode: mode, padding: padding, aad: aad)
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
        let aesDecrypt: @convention(block) (String, String, String?, String, String, String?, String?) -> NSDictionary = { dataB64, keyB64, ivB64, mode, padding, tagB64, aadB64 in
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
                let pt = try aesDecrypt(data: data, key: key, iv: iv, mode: mode, padding: padding, tag: tag, aad: aad)
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

        context.setObject(aesEncrypt as @convention(block) (String, String, String?, String, String, String?) -> NSDictionary, forKeyedSubscript: "__fwCryptoAESEncrypt" as NSString)
        context.setObject(aesDecrypt as @convention(block) (String, String, String?, String, String, String?, String?) -> NSDictionary, forKeyedSubscript: "__fwCryptoAESDecrypt" as NSString)
        context.setObject(xorBlock as @convention(block) (String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoXOR" as NSString)
        context.setObject(hashBlock as @convention(block) (String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoHash" as NSString)
        context.setObject(hmacBlock as @convention(block) (String, String, String) -> NSDictionary, forKeyedSubscript: "__fwCryptoHMAC" as NSString)
        context.setObject(randomBlock as @convention(block) (Int) -> NSDictionary, forKeyedSubscript: "__fwCryptoRandomBytes" as NSString)

        // JS 胶水（Core/WidgetCrypto.js.txt）：组装 Widget.crypto.* 友好 API。
        // 读不到胶水时打日志（全构建，不只 DEBUG）——否则模块调 Widget.crypto 才报
        // "不可用"，根因难查。胶水评完后删掉全局上的 6 个原语：胶水已把它们收进闭包
        // 局部变量，删全局不影响胶水内部调用，但模块就调不到原语、绕不过胶水的校验。
        if let url = Bundle.main.url(forResource: "WidgetCrypto", withExtension: "js.txt"),
           let glue = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(glue, withSourceURL: URL(string: "host://WidgetCrypto.js.txt"))
            context.evaluateScript("delete this.__fwCryptoAESEncrypt; delete this.__fwCryptoAESDecrypt; delete this.__fwCryptoXOR; delete this.__fwCryptoHash; delete this.__fwCryptoHMAC; delete this.__fwCryptoRandomBytes;")
        } else {
            print("[WidgetCrypto] WidgetCrypto.js.txt 读不到，Widget.crypto 不可用")
        }
    }
}
