import Foundation

/// ZIP 引擎统一错误域。
public enum ZipError: Error, LocalizedError, Equatable {
    case unsupportedMethod(method: UInt16)
    case corruptEntry(reason: String)
    case truncatedEntry
    case wrongPassword
    case centralDirectoryNotFound
    case unsupportedArchiveFormat
    case destinationExists(path: String)
    case pathTraversalDetected(entryName: String)
    case volumeMissing(expected: String)
    case ioFailure(detail: String)
    /// 容错解压:部分条目损坏/无法读取已跳过,其余条目解压成功。
    case partialFailure(skipped: [String])
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedMethod(let m): return "不支持的压缩方法 (method=\(m))"
        case .corruptEntry(let reason): return "压缩包数据损坏:\(reason)"
        case .truncatedEntry: return "压缩包不完整或被截断"
        case .wrongPassword: return "解压密码错误或未提供"
        case .centralDirectoryNotFound: return "找不到 ZIP 中央目录,文件可能已损坏"
        case .unsupportedArchiveFormat: return "不支持的压缩包格式"
        case .destinationExists(let path): return "目标已存在:\(path)"
        case .pathTraversalDetected(let entry): return "检测到路径穿越攻击,条目:\(entry)"
        case .volumeMissing(let expected): return "缺少分卷:\(expected)"
        case .ioFailure(let detail): return "文件读写失败:\(detail)"
        case .partialFailure(let skipped):
            let names = skipped.prefix(3).joined(separator: "、")
            let suffix = skipped.count > 3 ? " 等" : ""
            return "已跳过 \(skipped.count) 个损坏或无法读取的条目:\(names)\(suffix)"
        case .cancelled: return "操作已取消"
        }
    }
}

/// ZIP 压缩方法常量。
enum ZipMethod {
    static let store: UInt16 = 0
    static let deflate: UInt16 = 8
}

/// ZIP 版本常量。
enum ZipVersion {
    static let madeBy: UInt16 = 20
    static let zip64: UInt16 = 45
}

/// ZIP 文件名 / 注释的字节解码。
///
/// ZIP 规范用通用标志位 bit 11 (EFS) 声明文件名按 UTF-8 存储;但大量中文 Windows
/// 打包工具(好压 / 快压 / 部分国产压缩软件)直接写 GBK 字节却不置该位。若按 UTF-8
/// 失败后回退 MacRoman,中文就会变成乱码。策略:
/// 1. EFS 置位或字节是合法 UTF-8 → 按 UTF-8 (许多工具不置位也写 UTF-8);
/// 2. 否则按 GB18030 解 (GBK / GB2312 均为其子集,覆盖绝大多数简体中文压缩包);
/// 3. 再退 MacRoman (旧式 Mac 工具) 与宽松 UTF-8 兜底。
enum ZipEntryNameDecoder {
    /// GB18030 编解码器 (GBK 超集)。
    static let gb18030: String.Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    static func decode(_ data: Data, isUTF8Declared: Bool) -> String {
        if isUTF8Declared, let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        return String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }
}

/// 单个待压缩输入文件的收集结果 (写入器内部流转模型)。
public struct ZipPendingEntry {
    public enum Kind: Equatable {
        case file
        case directory
    }

    var kind: Kind
    /// ZIP 内部使用的相对路径 (目录以 / 结尾),UTF-8。
    var name: String
    var fileURL: URL?
    var fileSize: UInt64
}

/// 自研分块并行布局 (extra field 0x6D7A,外部工具按未知字段跳过):
/// 记录单个条目的 deflate 分块边界,读取端据此并行 inflate。
/// - 各块独立 deflate,块间 Z_SYNC_FLUSH 衔接 (拼接后仍是合法 raw deflate 流,
///   只有不带 BFINAL 的差别),任何标准解压器都能顺序解开整条流;
/// - segmentSizes 为"明文压缩流"上的各段长度;整包 ZipCrypto 加密时 12 字节
///   加密头在段 0 之前 (加密条目走串行流式路径,不消费此图)。
public struct ZipBlockMap: Equatable {
    public static let extraFieldID: UInt16 = 0x6D7A
    static let version: UInt8 = 1
    /// 每个满块的未压缩字节数 (末块可小于此值)。
    public var blockSize: UInt64
    /// 各块压缩段长度 (按流顺序)。
    public var segmentSizes: [UInt64]

    public init(blockSize: UInt64, segmentSizes: [UInt64]) {
        self.blockSize = blockSize
        self.segmentSizes = segmentSizes
    }

    /// 各块压缩段长度合计。
    public var totalSegments: UInt64 { segmentSizes.reduce(0, +) }

    /// 块图与未压缩总尺寸是否自洽 (前 n-1 块为满块,末块 ≤ blockSize)。
    func matches(uncompressedSize total: UInt64) -> Bool {
        let count = UInt64(segmentSizes.count)
        return blockSize > 0
            && (count - 1) * blockSize < total
            && total <= count * blockSize
    }

    /// 序列化为完整 extra field (含 id + size 头)。
    func extraFieldData() -> Data {
        var d = Data()
        d.appendLE(UInt16(Self.extraFieldID))
        d.appendLE(UInt16(10 + segmentSizes.count * 4))
        d.append(Self.version)
        d.append(UInt8(0)) // reserved
        d.appendLE(UInt32(truncatingIfNeeded: blockSize))
        d.appendLE(UInt32(truncatingIfNeeded: segmentSizes.count))
        for size in segmentSizes {
            d.appendLE(UInt32(truncatingIfNeeded: size))
        }
        return d
    }

    /// 从 extra 字节区间解析;ID / 版本 / 长度不符返回 nil (调用方回退串行路径)。
    /// 只有传入的 Data 不是零起始索引时才归一化,避免中央目录解析中的整段复制。
    static func parse(from data: Data, range: Range<Int>) -> ZipBlockMap? {
        let source: Data
        let normalizedRange: Range<Int>
        if data.startIndex == 0 {
            source = data
            normalizedRange = range
        } else {
            source = Data(data)
            normalizedRange = (range.lowerBound - data.startIndex)..<(range.upperBound - data.startIndex)
        }

        var cursor = normalizedRange.lowerBound
        let end = normalizedRange.upperBound
        while cursor + 4 <= end {
            let id = source.readLE16(at: cursor)
            let size = Int(source.readLE16(at: cursor + 2))
            let next = cursor + 4 + size
            guard next <= end else { break }
            if id == extraFieldID, size >= 10, source[cursor + 4] == version {
                let blockSize = UInt64(source.readLE32(at: cursor + 6))
                let count = Int(source.readLE32(at: cursor + 10))
                guard count > 0, size >= 10 + count * 4 else { break }
                var sizes: [UInt64] = []
                sizes.reserveCapacity(count)
                var field = cursor + 14
                for _ in 0..<count {
                    sizes.append(UInt64(source.readLE32(at: field)))
                    field += 4
                }
                return ZipBlockMap(blockSize: blockSize, segmentSizes: sizes)
            }
            cursor = next
        }
        return nil
    }
}

/// 写入完成的 entry 元数据 (读取器/列表视图共用)。
public struct ZipEntryInfo: Equatable {
    public var name: String
    public var isDirectory: Bool
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var crc: UInt32
    public var method: UInt16
    public var isEncrypted: Bool
    public var lastModified: Date?
    /// 中央目录里的 entry 索引 (解压/测试时定位用)。
    public var index: Int
    /// 分块并行布局 (仅自研分块条目具备,解析自中央目录 extra;nil = 单流)。
    public var blockMap: ZipBlockMap?
}

/// DOS 时间 (ZIP 格式时间戳):本地时间,2 秒精度。
enum DOSTime {
    static func from(date: Date) -> (time: UInt16, date: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let yearValue = max(comps.year ?? 1980, 1980)
        let monthValue = comps.month ?? 1
        let dayValue = comps.day ?? 1
        let hourValue = comps.hour ?? 0
        let minuteValue = comps.minute ?? 0
        let secondValue = (comps.second ?? 0) / 2
        let dateField = UInt16((yearValue - 1980) * 512 + monthValue * 32 + dayValue)
        let timeField = UInt16(hourValue * 2048 + minuteValue * 32 + secondValue)
        return (timeField, dateField)
    }

    static func toDate(dosTime: UInt16, dosDate: UInt16) -> Date? {
        let year = Int(dosDate >> 9) + 1980
        let month = Int((dosDate >> 5) & 0xF)
        let day = Int(dosDate & 0x1F)
        let hour = Int(dosTime >> 11)
        let minute = Int((dosTime >> 5) & 0x3F)
        let second = Int(dosTime & 0x1F) * 2
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

/// 跨进程共享的任务进度回报协议。
public protocol ArchiveProgressReporting: AnyObject {
    /// 任务开始:预估总字节数 (0 表示未知,进度条转菊花)。
    func begin(totalBytes: UInt64, title: String)
    /// 单个文件粒度切换 (文件名)。
    func willProcessFile(_ name: String)
    /// 字节粒度推进 (自上次调用以来的增量)。
    func advance(by bytes: UInt64)
    /// 收尾阶段提示 (如压缩时把分片写入压缩包)。用于避免进度到 100% 后界面看似卡住。
    func willFinalize(message: String)
    /// 任务正常结束。
    /// - Parameter subtitle: HUD 副标题 (压缩包名 / 目标目录名);nil 时由呈现层决定。
    func finish(message: String, subtitle: String?)
    /// 任务失败/取消。
    func fail(message: String)
    /// 是否被用户取消。
    var isCancelled: Bool { get }
}

public extension ArchiveProgressReporting {
    /// 默认空实现:CLI / 测试等实现无需关心收尾提示。
    func willFinalize(message: String) {}
}

/// 默认空实现:CLI / 测试场景用。
public final class NullProgressReporter: ArchiveProgressReporting {
    public var isCancelled: Bool = false
    public init() {}
    public func begin(totalBytes: UInt64, title: String) {}
    public func willProcessFile(_ name: String) {}
    public func advance(by bytes: UInt64) {}
    public func finish(message: String, subtitle: String?) {}
    public func fail(message: String) {}
}
