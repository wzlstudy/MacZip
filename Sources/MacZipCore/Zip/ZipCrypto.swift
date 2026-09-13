import Foundation

/// PKWARE 传统加密 (ZipCrypto),ZIP APPNOTE 第 6 章。
/// FastZip / WinZip 兼容的传统 zip 密码保护即此格式;解密端为系统 unzip、Windows 资源管理器等通用实现。
/// 注:该算法强度有限,仅用于兼容性;高安全需求用户应选用 7z (-mhe) 加密。
enum ZipCrypto {
    /// 密码派生的三字节密钥状态。流式加解密共用。密钥始终保存为"原始状态" (无首尾取反)。
    struct Context {
        private var key0: UInt32 = 0x12345678
        private var key1: UInt32 = 0x23456789
        private var key2: UInt32 = 0x34567890

        init(password: [UInt8]) {
            for byte in password {
                updateKeys(byte)
            }
        }

        private mutating func updateKeys(_ byte: UInt8) {
            key0 = CRC32.rawStep(key0, byte)
            key1 = (key1 &+ (key0 & 0xFF)) &* 134775813 &+ 1
            key2 = CRC32.rawStep(key2, UInt8(truncatingIfNeeded: key1 >> 24))
        }

        /// 生成下一个密钥流字节并更新内部状态。
        private mutating func nextKeyByte() -> UInt8 {
            let temp = UInt16(truncatingIfNeeded: key2) | 2
            return UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
        }

        /// 就地加密一个 buffer (传统加密:密文字节 = 明文字节 ^ 密钥流,再以明文更新密钥)。
        mutating func encryptInPlace(_ buffer: UnsafeMutableBufferPointer<UInt8>) {
            for i in buffer.indices {
                let plain = buffer[i]
                let cipher = plain ^ nextKeyByte()
                buffer[i] = cipher
                updateKeys(plain)
            }
        }

        /// 就地解密一个 buffer。
        mutating func decryptInPlace(_ buffer: UnsafeMutableBufferPointer<UInt8>) {
            for i in buffer.indices {
                let plain = buffer[i] ^ nextKeyByte()
                buffer[i] = plain
                updateKeys(plain)
            }
        }
    }

    /// ZipCrypto 头部长度固定 12 字节。
    static let headerLength = 12

    /// 加密头校验字节:bit3 (数据描述符) 未置位时使用 CRC32 高字节。
    static func checkByte(crc: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: crc >> 24)
    }

    /// 加密头校验字节:bit3 置位时使用 DOS 时间高字节。
    static func checkByte(dosTime: UInt16) -> UInt8 {
        UInt8(truncatingIfNeeded: dosTime >> 8)
    }

    /// 组装加密头:12 字节,其中 11 字节为随机填充,末字节为校验字节。
    static func makeHeader(checkByte: UInt8) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerLength)
        for i in 0..<(headerLength - 1) {
            header[i] = UInt8.random(in: 0...255)
        }
        header[headerLength - 1] = checkByte
        return header
    }
}
