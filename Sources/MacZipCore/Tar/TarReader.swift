import Foundation

/// 内建 TAR 读取器 (ustar / GNU / pax 三种变体)。
///
/// 仅做两件事:顺序解析条目头以列出清单,以及按需抽取单个条目内容(供预览)。
/// 输出统一为 `ZipEntryInfo`,让预览窗口/QuickLook 复用同一套树模型与单元格渲染。
/// `.tar.gz` 由调用方先用 `ZlibCodec.gunzipFile` 解出临时 tar 再交给本类。
public final class TarReader {
    private let archiveURL: URL
    private let fm = FileManager.default

    /// 条目名 → 数据块起始偏移,listEntries 时建立,供抽取时直接定位。
    private var dataOffsets: [String: UInt64] = [:]
    /// 条目名 → 数据字节数。
    private var dataSizes: [String: UInt64] = [:]

    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    private static let blockSize = 512
    /// 单个条目大小上限保护 (16 GiB),避免畸形头导致越界读取。
    private static let maxEntrySize: UInt64 = 16 * 1024 * 1024 * 1024

    // MARK: - 列表

    /// 解析全部条目 (目录 / 普通文件 / 符号链接)。返回顺序与归档内一致。
    public func listEntries() throws -> [ZipEntryInfo] {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        dataOffsets.removeAll()
        dataSizes.removeAll()

        var result: [ZipEntryInfo] = []
        var pendingLongName: String?
        var pendingPax: [String: String] = [:]

        while true {
            guard let block = try readBlock(handle) else { break }
            if block.allSatisfy({ $0 == 0 }) { break } // 两个零块即归档结束

            let typeflag = block[156]
            let rawSize = Self.parseSize(block)

            // GNU 长名 / 长链接:载荷即名称,不产出条目。
            if typeflag == 0x4C { // 'L'
                pendingLongName = try readPayloadString(handle, size: rawSize)
                continue
            }
            // GNU 长链接:载荷即目标路径,当前不做硬链接重建,直接跳过。
            if typeflag == 0x4B { // 'K'
                _ = try readPayloadString(handle, size: rawSize)
                continue
            }
            // pax 扩展头:载荷为 "len key=value\n" 记录串。
            if typeflag == 0x78 || typeflag == 0x67 { // 'x' / 'g'
                let text = try readPayloadString(handle, size: rawSize) ?? ""
                let records = Self.parsePax(text)
                if typeflag == 0x78 { pendingPax.merge(records) { _, new in new } }
                continue
            }

            let name = resolveName(
                block: block,
                longName: pendingLongName,
                pax: pendingPax
            )
            pendingLongName = nil
            let size = UInt64(pendingPax["size"] ?? "") ?? rawSize
            pendingPax.removeAll()

            let dataOffset = try currentOffset(handle)
            // 跳过载荷 (按 512 对齐)。
            let padded = (size + UInt64(Self.blockSize) - 1) / UInt64(Self.blockSize) * UInt64(Self.blockSize)
            if size > Self.maxEntrySize { throw ZipError.corruptEntry(reason: "TAR 条目过大") }
            try handle.seek(toOffset: dataOffset + padded)

            guard !name.isEmpty else { continue }
            let normalized = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            let isDirectory = (typeflag == 0x35) || normalized.hasSuffix("/")
            let isLink = (typeflag == 0x31 || typeflag == 0x32) // '1' hardlink, '2' symlink

            dataOffsets[normalized] = dataOffset
            dataSizes[normalized] = isLink ? 0 : size

            result.append(ZipEntryInfo(
                name: normalized,
                isDirectory: isDirectory,
                compressedSize: isLink ? 0 : size,
                uncompressedSize: isLink ? 0 : size,
                crc: 0,
                method: 0, // store
                isEncrypted: false,
                lastModified: Self.parseMTime(block),
                index: result.count
            ))
        }
        return result
    }

    // MARK: - 抽取

    /// 抽取单个条目到目标路径 (目录会建目录)。符号链接按相对目标重建,不安全的链接跳过。
    public func extractEntry(_ entry: ZipEntryInfo, to destination: URL) throws {
        if entry.isDirectory {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        guard let offset = dataOffsets[entry.name], let size = dataSizes[entry.name] else {
            throw ZipError.corruptEntry(reason: "TAR 条目未在清单中:\(entry.name)")
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let inFD = handle.fileDescriptor

        fm.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        do {
            let outFD = output.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: ChunkedIO.bufferSize)
            try buffer.withUnsafeMutableBufferPointer { buf in
                var remaining = size
                while remaining > 0 {
                    let want = Int(min(UInt64(buf.count), remaining))
                    try ChunkedIO.readFull(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                        want: want
                    )
                    try ChunkedIO.write(
                        fd: outFD,
                        from: UnsafeRawBufferPointer(start: buf.baseAddress, count: want)
                    )
                    remaining -= UInt64(want)
                }
            }
            try? output.close()
            if let modified = entry.lastModified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - 头部解析

    private func readBlock(_ handle: FileHandle) throws -> [UInt8]? {
        let data = handle.readData(ofLength: Self.blockSize)
        if data.isEmpty { return nil }
        if data.count < Self.blockSize { throw ZipError.truncatedEntry }
        return [UInt8](data)
    }

    private func currentOffset(_ handle: FileHandle) throws -> UInt64 {
        try handle.offset()
    }

    private func readPayloadString(_ handle: FileHandle, size: UInt64) throws -> String? {
        guard size <= Self.maxEntrySize else { throw ZipError.corruptEntry(reason: "TAR 头部载荷过大") }
        let data = handle.readData(ofLength: Int(size))
        guard data.count == Int(size) else { throw ZipError.truncatedEntry }
        // 跳过对齐填充。
        let padded = (size + UInt64(Self.blockSize) - 1) / UInt64(Self.blockSize) * UInt64(Self.blockSize)
        try handle.seek(toOffset: try handle.offset() + (padded - size))
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private func resolveName(block: [UInt8], longName: String?, pax: [String: String]) -> String {
        if let path = pax["path"], !path.isEmpty { return path }
        if let longName, !longName.isEmpty { return longName }

        let name = Self.cString(block, 0, 100)
        let magic = Self.cString(block, 257, 6)
        // ustar:prefix(155) + "/" + name。
        if magic.hasPrefix("ustar") {
            let prefix = Self.cString(block, 345, 155)
            if !prefix.isEmpty { return prefix + "/" + name }
        }
        return name
    }

    private static func cString(_ block: [UInt8], _ offset: Int, _ length: Int) -> String {
        let end = min(offset + length, block.count)
        let slice = block[offset..<end]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 解析 size 字段:优先八进制,首字节高位置位时为 base-256 大端。
    private static func parseSize(_ block: [UInt8]) -> UInt64 {
        parseNumeric(block, offset: 124, length: 12)
    }

    private static func parseMTime(_ block: [UInt8]) -> Date? {
        let value = parseNumeric(block, offset: 136, length: 12)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private static func parseNumeric(_ block: [UInt8], offset: Int, length: Int) -> UInt64 {
        let field = block[offset..<min(offset + length, block.count)]
        guard let first = field.first else { return 0 }
        if first & 0x80 != 0 {
            // base-256:首字节去掉标志位,其余为大端无符号。
            var value: UInt64 = UInt64(first & 0x7F)
            for byte in field.dropFirst() { value = (value << 8) | UInt64(byte) }
            return value
        }
        // 八进制 ASCII,以 NUL/空格结尾。
        let text = field.prefix { $0 != 0 && $0 != 0x20 }
        return UInt64(String(decoding: text, as: UTF8.self), radix: 8) ?? 0
    }

    /// 解析 pax 记录串:"<len> <key>=<value>\n"。
    private static func parsePax(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            // 记录长度十进制数字 + 空格。
            var j = i
            while j < bytes.count, bytes[j] != 0x20 { j += 1 }
            guard j < bytes.count, let length = Int(String(decoding: bytes[i..<j], as: UTF8.self)), length > 0 else { break }
            let recordEnd = min(i + length, bytes.count)
            let bodyStart = j + 1
            if bodyStart < recordEnd {
                let body = String(decoding: bytes[bodyStart..<recordEnd], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[body.startIndex..<eq])
                    let value = String(body[body.index(after: eq)...])
                    result[key] = value
                }
            }
            i = recordEnd
        }
        return result
    }
}
