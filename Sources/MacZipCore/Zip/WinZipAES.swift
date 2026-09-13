import Foundation
import CommonCrypto

/// WinZip AES 加密 (ZIP APPNOTE "AES Encryption Information", AE-1/AE-2):
/// - PBKDF2-HMAC-SHA1 (1000 轮) 派生 2×keyLen+2 字节材料:
///   [加密钥 keyLen | MAC 钥 keyLen | 2 字节口令校验值];
/// - AES-CTR:128 位**小端**计数器,初始值 1;
/// - HMAC-SHA1 (MAC 钥) 覆盖**密文**,认证码 = 摘要前 10 字节,位于条目数据末尾;
/// - 盐长 = 密钥长的一半 (128/192/256 → 8/12/16 字节)。
///
/// 条目数据布局: [盐][2 字节校验值][密文][10 字节认证码]。
/// 头部压缩方法字段写 99,实际方法在 AES extra field (0x9901) 内。
/// AE-1 版本 CRC 照常存储并校验;AE-2 版本 CRC 恒为 0 (由 HMAC 保障完整性)。
public struct WinZipAESInfo: Equatable {
    /// 加密强度编码:1 = 128 位,2 = 192 位,3 = 256 位。
    public var strength: UInt8
    /// extra field 里的版本:1 = AE-1,2 = AE-2。
    public var version: UInt16
    /// 实际压缩方法 (0 / 8)。
    public var method: UInt16

    public var keyLength: Int { WinZipAES.keyLength(for: strength) }
    public var saltLength: Int { WinZipAES.saltLength(for: strength) }
    /// 盐 + 校验值的头部字节数。
    public var headerLength: Int { saltLength + 2 }
    /// 末尾认证码字节数。
    public static let authLength = 10
}

/// WinZip AES 密码学原语 (全部基于系统 CommonCrypto,无第三方依赖)。
public enum WinZipAES {
    static let versionAE1: UInt16 = 1
    static let versionAE2: UInt16 = 2
    static let pbkdf2Rounds: UInt32 = 1000
    /// kCCModeOptionCTR_LE (C 宏不导入 Swift,此处硬编码;1 = 小端计数器)。
    static let modeOptionCTRLE: UInt32 = 1

    public static func keyLength(for strength: UInt8) -> Int {
        switch strength {
        case 1: return 16
        case 2: return 24
        case 3: return 32
        default: return 0
        }
    }

    public static func saltLength(for strength: UInt8) -> Int {
        keyLength(for: strength) / 2
    }

    /// 序列化 AES extra field (含 id + size 头)。
    public static func extraFieldData(strength: UInt8, version: UInt16, method: UInt16) -> Data {
        var d = Data()
        d.appendLE(UInt16(0x9901))
        d.appendLE(UInt16(7))
        d.appendLE(version)
        d.append(contentsOf: [0x41, 0x45]) // "AE"
        d.append(strength)
        d.appendLE(method)
        return d
    }

    /// 从 extra 字节区间解析;ID / 长度 / vendor 不符返回 nil。
    /// 注意:入口复制归零索引 (Data 切片保留原 startIndex,直接下标会越界)。
    public static func parseInfo(from data: Data, range: Range<Int>) -> WinZipAESInfo? {
        let data = Data(data)
        var cursor = range.lowerBound
        let end = range.upperBound
        while cursor + 4 <= end {
            let id = data.readLE16(at: cursor)
            let size = Int(data.readLE16(at: cursor + 2))
            let next = cursor + 4 + size
            guard next <= end else { break }
            if id == 0x9901, size == 7 {
                let version = data.readLE16(at: cursor + 4)
                let vendor = (data[cursor + 6], data[cursor + 7])
                let strength = data[cursor + 8]
                let method = data.readLE16(at: cursor + 9)
                guard vendor == (0x41, 0x45), keyLength(for: strength) > 0,
                      method == ZipMethod.store || method == ZipMethod.deflate else { return nil }
                return WinZipAESInfo(strength: strength, version: version, method: method)
            }
            cursor = next
        }
        return nil
    }

    /// PBKDF2-HMAC-SHA1 派生 (加密钥, MAC 钥, 口令校验值)。
    static func deriveKeys(
        password: [UInt8],
        salt: [UInt8],
        keyLength: Int
    ) -> (encrypt: [UInt8], mac: [UInt8], verifier: [UInt8])? {
        var derived = [UInt8](repeating: 0, count: keyLength * 2 + 2)
        let cPassword = password.map { Int8(bitPattern: $0) }
        let status = cPassword.withUnsafeBufferPointer { pwdBuf in
            salt.withUnsafeBufferPointer { saltBuf in
                derived.withUnsafeMutableBytes { raw -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBuf.baseAddress, pwdBuf.count,
                        saltBuf.baseAddress, saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        WinZipAES.pbkdf2Rounds,
                        raw.bindMemory(to: UInt8.self).baseAddress,
                        raw.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return (
            encrypt: Array(derived[0..<keyLength]),
            mac: Array(derived[keyLength..<(keyLength * 2)]),
            verifier: Array(derived[(keyLength * 2)...])
        )
    }

    /// 口令校验值快速比对 (解压 / 试密码用,不建完整解密器)。
    static func verifierMatches(
        password: [UInt8],
        salt: [UInt8],
        verifier: [UInt8],
        keyLength: Int
    ) -> Bool {
        guard let keys = deriveKeys(password: password, salt: salt, keyLength: keyLength) else { return false }
        return keys.verifier == verifier
    }

    /// AES-CTR 密码机 (加密 / 解密同一变换),128 位小端计数器,初始值 1。
    ///
    /// 系统 CommonCrypto 的 CTR 模式只支持大端计数器 (SDK 头文件注明 "now only
    /// Big Endian mode is supported"),而 WinZip 规范要求小端,故以 ECB 密码机
    /// 自行构建:批量生成小端计数器块 → ECB 加密得到密钥流 → 与数据 XOR。
    final class CTRCryptor {
        /// 每次生成的密钥流字节数 (1024 块 × 16)。
        private static let keystreamBytes = 1024 * 16
        private let ecbCryptor: CCCryptorRef?
        /// 128 位计数器 (小端序列化:low 为低 64 位)。
        private var counterLow: UInt64 = 1
        private var counterHigh: UInt64 = 0
        /// 尚未用尽的密钥流 (跨任意长度分块保持流内连续)。
        private var keystream = [UInt8]()
        private var keystreamOffset = 0

        init?(key: [UInt8]) {
            var ref: CCCryptorRef?
            let status = key.withUnsafeBytes { keyRaw in
                CCCryptorCreate(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyRaw.baseAddress, key.count,
                    nil,
                    &ref
                )
            }
            guard status == kCCSuccess, let created = ref else { return nil }
            ecbCryptor = created
        }

        deinit {
            if let cryptor = ecbCryptor { CCCryptorRelease(cryptor) }
        }

        /// 就地变换 buffer 前 count 字节 (CTR 加密 == 解密)。
        func cryptInPlace(_ buffer: UnsafeMutableBufferPointer<UInt8>, count: Int) -> Bool {
            var offset = 0
            while offset < count {
                if keystreamOffset >= keystream.count {
                    guard refillKeystream() else { return false }
                }
                let available = keystream.count - keystreamOffset
                let n = min(available, count - offset)
                for i in 0..<n {
                    buffer[offset + i] ^= keystream[keystreamOffset + i]
                }
                keystreamOffset += n
                offset += n
            }
            return true
        }

        private func refillKeystream() -> Bool {
            var counterBlocks = [UInt8](repeating: 0, count: Self.keystreamBytes)
            var low = counterLow
            var high = counterHigh
            for b in 0..<Self.keystreamBytes / 16 {
                var value = low
                for i in 0..<8 {
                    counterBlocks[b * 16 + i] = UInt8(truncatingIfNeeded: value)
                    value >>= 8
                }
                value = high
                for i in 0..<8 {
                    counterBlocks[b * 16 + 8 + i] = UInt8(truncatingIfNeeded: value)
                    value >>= 8
                }
                // 128 位小端 +1 (溢出忽略:2^128 块不可达)。
                let (newLow, overflow) = low.addingReportingOverflow(1)
                low = newLow
                if overflow { high &+= 1 }
            }
            counterLow = low
            counterHigh = high

            var moved = 0
            let status = counterBlocks.withUnsafeMutableBytes { raw in
                CCCryptorUpdate(
                    ecbCryptor,
                    raw.baseAddress, raw.count,
                    raw.baseAddress, raw.count,
                    &moved
                )
            }
            guard status == kCCSuccess, moved == counterBlocks.count else { return false }
            keystream = counterBlocks
            keystreamOffset = 0
            return true
        }
    }

    /// 流式 HMAC-SHA1。
    final class SHA1HMAC {
        private var context = CCHmacContext()

        init(key: [UInt8]) {
            CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA1), key, key.count)
        }

        func update(_ data: UnsafeRawBufferPointer) {
            CCHmacUpdate(&context, data.baseAddress, data.count)
        }

        /// 前 10 字节摘要 (认证码)。
        func authenticationCode() -> [UInt8] {
            var digest = [UInt8](repeating: 0, count: 20)
            CCHmacFinal(&context, &digest)
            return Array(digest[0..<WinZipAESInfo.authLength])
        }
    }
}
