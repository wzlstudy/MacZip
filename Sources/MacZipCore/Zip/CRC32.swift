import Foundation
import zlib

/// 标准 CRC-32 (IEEE 802.3,多项式 0xEDB88320)。
/// ZIP 规范中所有 entry 的校验值均使用该算法;本地实现保证与外部工具解耦、可单测。
public enum CRC32 {
    /// 查表。`rawStep` 亦复用,故设为 internal 而非 private。
    @usableFromInline
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 == 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// 从 0 开始计算一段数据的 CRC32。
    public static func checksum(_ data: UnsafeBufferPointer<UInt8>) -> UInt32 {
        update(0, data)
    }

    /// 增量计算:在已有 crc 基础上追加一段数据。crc 初值必须为 0。
    /// 链式调用满足 update(update(0, A), B) == crc(A+B)。
    ///
    /// 直接调用系统 libz 的 crc32 (切片式查表实现,通常比逐字节快数倍);
    /// 语义与本地查表完全一致,已由测试向量的分块链接校验覆盖。
    public static func update(_ crc: UInt32, _ data: UnsafeBufferPointer<UInt8>) -> UInt32 {
        guard let base = data.baseAddress, !data.isEmpty else { return crc }
        var value = crc
        var offset = 0
        // 单次调用长度受 uInt (32 位) 限制,按 1 MiB 分段以防超大缓冲。
        while offset < data.count {
            let n = min(data.count - offset, 1 << 20)
            value = UInt32(truncatingIfNeeded: crc32(uLong(value), base + offset, uInt(n)))
            offset += n
        }
        return value
    }

    /// 合并两段相邻数据的 CRC:crc1 为前段结果,crc2 为后段结果,len2 为后段
    /// 字节数,返回两段拼接后的 CRC。并行分块压缩/解压时各块独立算 CRC,
    /// 按序 combine 还原整条 CRC。系统 libz 的 crc32_combine (GF(2) 矩阵实现)。
    public static func combine(_ crc1: UInt32, _ crc2: UInt32, _ len2: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32_combine(uLong(crc1), uLong(crc2), Int(len2)))
    }

    /// PKWARE ZipCrypto 密钥更新使用的原始单步 (无首尾取反语义)。
    /// C 参考实现: key = (key >> 8) ^ crctable[(key ^ byte) & 0xff]。
    @inlinable
    static func rawStep(_ state: UInt32, _ byte: UInt8) -> UInt32 {
        table[Int((state ^ UInt32(byte)) & 0xFF)] ^ (state >> 8)
    }
}
