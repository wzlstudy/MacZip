import Foundation

/// 支持的压缩包格式识别 (扩展名优先,魔数兜底)。
public enum ArchiveFormat: String, CaseIterable {
    case zip
    case jar
    case tar
    case tarGz = "tar.gz"
    case tarBz2 = "tar.bz2"
    case tarXz = "tar.xz"
    case gzip          // 单文件 .gz
    case sevenZip = "7z"
    case rar
    case splitVolume   // .zip.001 / .7z.001 等分卷首段

    public var fileExtension: String { rawValue }

    public var localizedName: String {
        switch self {
        case .zip: return "ZIP 压缩包"
        case .jar: return "JAR 压缩包"
        case .tar: return "TAR 归档"
        case .tarGz: return "TAR.GZ 压缩包"
        case .tarBz2: return "TAR.BZ2 压缩包"
        case .tarXz: return "TAR.XZ 压缩包"
        case .gzip: return "GZIP 压缩文件"
        case .sevenZip: return "7Z 压缩包"
        case .rar: return "RAR 压缩包"
        case .splitVolume: return "分卷压缩包"
        }
    }

    /// JAR 本质是 ZIP。
    public var isZipFamily: Bool {
        self == .zip || self == .jar
    }

    /// 是否支持在预览窗口内列出条目并预览单个文件内容。
    /// (tar 系走内建 tar 解析,tar.gz 先 gunzip 再解析)
    public var supportsContentPreview: Bool {
        switch self {
        case .zip, .jar, .tar, .tarGz: return true
        default: return false
        }
    }

    /// 是否支持内容编辑 (增加/删除/清理)。目前仅 ZIP 系。
    public var supportsEditing: Bool {
        isZipFamily
    }

    /// 由文件路径识别格式。分卷判定优先于普通扩展名。
    public static func detect(url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        // WinZip 分卷末卷: xxx.zip 且同目录存在 xxx.z01 → 须按分卷整包解压。
        // (该探测仅对 .zip 文件多一次 stat,右键菜单等高频路径可接受)
        if name.hasSuffix(".zip"),
           let info = SplitVolumes.volumeInfo(of: url),
           info.style == .winZip, info.isFinalPart {
            return .splitVolume
        }
        for format in ArchiveFormat.allCases where format != .splitVolume {
            if name.hasSuffix("." + format.fileExtension) { return format }
        }
        // 分卷: xxx.zip.001 / xxx.7z.001 / xxx.z01
        if SplitVolumes.volumeInfo(of: url) != nil { return .splitVolume }
        // 单字符扩展 gz/bz2/xz 未命中 tar 前缀时按单文件压缩处理。
        if name.hasSuffix(".gz") { return .gzip }
        if name.hasSuffix(".bz2") || name.hasSuffix(".xz") { return .gzip }
        return nil
    }

    /// 该格式是否由 MacZip 内建引擎直接处理 (不经外部工具)。
    public var isBuiltIn: Bool {
        switch self {
        case .zip, .jar, .gzip, .splitVolume, .tar, .tarGz: return true
        default: return false
        }
    }
}

/// 分卷切分与合并 (FastZip "分卷压缩" 功能)。
/// 支持两种行业惯例:
/// - 数字号: <name>.zip.001 / .002 … (好压 / Bandizip 等,本引擎切分也产出此格式)
/// - WinZip: <name>.z01 / .z02 … + <name>.zip 末卷 (中央目录在末卷内)
public enum SplitVolumes {
    public enum Style: Equatable {
        /// <base>.NNN,base 含一级扩展 (photos.zip.001 → base "photos.zip")。
        case numeric
        /// <base>.zNN + 末卷 <base>.zip (data.z01 → base "data")。
        case winZip
    }

    public struct VolumeInfo: Equatable {
        public var baseName: String
        public var sequence: Int
        public var directory: URL
        public var style: Style
        /// 是否末卷 (WinZip 的 .zip;numeric 风格恒 false)。
        public var isFinalPart: Bool

        /// 合并产物的文件名 (数字号 base 自带扩展;WinZip 补 .zip)。
        public var mergedFileName: String {
            switch style {
            case .numeric: return baseName
            case .winZip: return baseName + ".zip"
            }
        }
    }

    /// 识别分卷。数字号: xxx.zip.001;WinZip: xxx.z01~z9999 (大小写不敏感) 或
    /// xxx.zip 且同目录存在 xxx.z01。仅接受 1~9999 序号。
    public static func volumeInfo(of url: URL) -> VolumeInfo? {
        let name = url.lastPathComponent
        let directory = url.deletingLastPathComponent()
        guard let dotIndex = name.lastIndex(of: ".") else { return nil }
        let ext = String(name[name.index(after: dotIndex)...])
        let base = String(name[..<dotIndex])
        guard !base.isEmpty else { return nil }

        // 数字号: base 须含一级扩展,避免把普通编号文件误判为分卷。
        if ext.count >= 2, ext.count <= 4, ext.allSatisfy(\.isNumber),
           let sequence = Int(ext), sequence >= 1, base.contains(".") {
            return VolumeInfo(
                baseName: base, sequence: sequence, directory: directory,
                style: .numeric, isFinalPart: false
            )
        }
        // WinZip 中间卷: z + 2~4 位数字。
        let lower = ext.lowercased()
        if lower.count >= 3, lower.count <= 5, lower.hasPrefix("z"),
           lower.dropFirst().allSatisfy(\.isNumber),
           let sequence = Int(lower.dropFirst()), sequence >= 1 {
            return VolumeInfo(
                baseName: base, sequence: sequence, directory: directory,
                style: .winZip, isFinalPart: false
            )
        }
        // WinZip 末卷: xxx.zip 且同目录存在 xxx.z01。
        if lower == "zip" {
            let firstPart = directory.appendingPathComponent(base + ".z01")
            if FileManager.default.fileExists(atPath: firstPart.path) {
                return VolumeInfo(
                    baseName: base, sequence: 0, directory: directory,
                    style: .winZip, isFinalPart: true
                )
            }
        }
        return nil
    }

    /// 把一个完整 zip 切分为定长分卷。firstVolumeURL 形如 …/photos.zip,
    /// 实际产出 photos.zip.001 / .002 / …,并移除源文件。返回第一个分卷 URL。
    @discardableResult
    public static func split(fileAt source: URL, firstVolumeURL: URL, volumeSize: UInt64) throws -> URL {
        let fm = FileManager.default
        guard volumeSize > 0 else { return source }

        let volumeTemplate = firstVolumeURL.path + ".%03d" // photos.zip → photos.zip.001
        let chunkSize = max(64 * 1024, Int(volumeSize))
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let sourceFD = reader.fileDescriptor

        var index = 1
        var remainingInVolume = 0
        var currentHandle: FileHandle?
        var currentFD: Int32 = -1
        defer { try? currentHandle?.close() }

        func openNextVolume() throws {
            try? currentHandle?.close()
            currentFD = -1
            let volumePath = String(format: volumeTemplate, index)
            fm.createFile(atPath: volumePath, contents: nil)
            currentHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: volumePath))
            currentFD = currentHandle?.fileDescriptor ?? -1
            remainingInVolume = chunkSize
            index += 1
        }

        var buffer = [UInt8](repeating: 0, count: ChunkedIO.bufferSize)
        try buffer.withUnsafeMutableBufferPointer { buf in
            while true {
                let n = try ChunkedIO.read(
                    fd: sourceFD,
                    into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                    want: buf.count
                )
                if n == 0 { break }
                var offset = 0
                while offset < n {
                    if currentFD < 0 || remainingInVolume == 0 {
                        try openNextVolume()
                    }
                    let take = min(remainingInVolume, n - offset)
                    try ChunkedIO.write(
                        fd: currentFD,
                        from: UnsafeRawBufferPointer(start: buf.baseAddress!.advanced(by: offset), count: take)
                    )
                    remainingInVolume -= take
                    offset += take
                }
            }
        }
        try? currentHandle?.close()

        guard index > 1 else { throw ZipError.volumeMissing(expected: firstVolumeURL.path) }
        try? fm.removeItem(at: source)
        return URL(fileURLWithPath: String(format: volumeTemplate, 1))
    }

    /// 合并分卷为完整压缩包 (解压前调用)。firstVolume 可为任意一个分卷
    /// (数字号按其序号向后收集;WinZip 恒从 z01 收集到末卷)。
    /// 返回合并产物 (临时目录内) 的 URL。
    public static func merge(firstVolume: URL, stagingDirectory: URL) throws -> URL {
        let fm = FileManager.default
        guard let info = volumeInfo(of: firstVolume) else {
            throw ZipError.unsupportedArchiveFormat
        }
        guard let volumes = allVolumes(forFirst: firstVolume), !volumes.isEmpty else {
            throw ZipError.volumeMissing(expected: firstVolume.path)
        }

        let mergedURL = stagingDirectory.appendingPathComponent(info.mergedFileName)
        fm.createFile(atPath: mergedURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: mergedURL)
        defer { try? writer.close() }
        let outFD = writer.fileDescriptor

        var buffer = [UInt8](repeating: 0, count: ChunkedIO.bufferSize)
        try buffer.withUnsafeMutableBufferPointer { buf in
            for volume in volumes {
                let reader = try FileHandle(forReadingFrom: volume)
                defer { try? reader.close() }
                let inFD = reader.fileDescriptor
                while true {
                    let n = try ChunkedIO.read(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                        want: buf.count
                    )
                    if n == 0 { break }
                    try ChunkedIO.write(
                        fd: outFD,
                        from: UnsafeRawBufferPointer(start: buf.baseAddress, count: n)
                    )
                }
            }
        }
        return mergedURL
    }

    /// 目录内全部分卷 (按拼接顺序);序列不完整时返回 nil。
    public static func allVolumes(forFirst firstVolume: URL) -> [URL]? {
        guard let info = volumeInfo(of: firstVolume) else { return nil }
        let fm = FileManager.default
        var parts: [URL] = []

        switch info.style {
        case .numeric:
            var sequence = info.sequence
            while sequence <= 9999 {
                let volumeURL = info.directory
                    .appendingPathComponent("\(info.baseName).\(String(format: "%03d", sequence))")
                guard fm.fileExists(atPath: volumeURL.path) else { break }
                parts.append(volumeURL)
                sequence += 1
            }
            return parts.isEmpty ? nil : parts
        case .winZip:
            var sequence = 1
            while sequence <= 9999 {
                let volumeURL = info.directory
                    .appendingPathComponent("\(info.baseName).z\(String(format: "%02d", sequence))")
                guard fm.fileExists(atPath: volumeURL.path) else { break }
                parts.append(volumeURL)
                sequence += 1
            }
            // 末卷 (含中央目录) 必须存在,否则无法还原完整压缩包。
            let finalURL = info.directory.appendingPathComponent(info.mergedFileName)
            guard !parts.isEmpty, fm.fileExists(atPath: finalURL.path) else { return nil }
            parts.append(finalURL)
            return parts
        }
    }
}
