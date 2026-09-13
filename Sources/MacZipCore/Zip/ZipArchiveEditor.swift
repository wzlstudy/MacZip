import Foundation

/// 归档内容编辑:增加 / 删除 / 清理。
///
/// 删除与清理采用「原样搬运」策略:把保留条目的 local header + 压缩负载(含 ZipCrypto
/// 密文、data descriptor)逐字节复制进新包,仅重建中央目录。由此获得两个关键性质:
/// - 删除加密归档里的条目**无需密码**(密文原样搬);
/// - 保留原有压缩方法 / 压缩率 / 加密状态,不解压重压,大包也快。
/// 增加则先用 `ZipWriter` 生成一个只含新文件的临时包,再把这些条目原样并入。
public enum ZipArchiveEditor {

    // MARK: - 条目模型

    /// 中央目录 + 定位信息;`sourceURL` 标明负载所在文件 (原包或临时新包)。
    private struct RawEntry {
        var sourceURL: URL
        var localOffset: UInt64
        var name: String
        var nameBytes: Data
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var csize: UInt64
        var usize: UInt64
        var dosTime: UInt16
        var dosDate: UInt16
        var externalAttrs: UInt32
        var versionMadeBy: UInt16
        var commentBytes: Data

        var isDirectory: Bool { name.hasSuffix("/") }

        /// 重命名 (增加文件到指定子目录时用),同步刷新 UTF-8 名称字节。
        func renamed(prefix: String, forceUTF8: Bool) -> RawEntry {
            var copy = self
            let newName = prefix.isEmpty ? name : prefix + "/" + name
            copy.name = newName
            copy.nameBytes = Data(newName.utf8)
            if forceUTF8 { copy.flags |= 0x0800 }
            return copy
        }
    }

    private static let fm = FileManager.default

    // MARK: - 公开入口

    /// 删除给定路径集合(目录会连同其下所有条目)。返回删除的条目数。
    /// 加密归档无需密码。
    @discardableResult
    public static func delete(
        paths: Set<String>,
        from archive: URL,
        reporter: ArchiveProgressReporting
    ) throws -> Int {
        let targets = Set(paths.map(normalize))
        guard !targets.isEmpty else { return 0 }

        let parsed = try readCentralDirectory(archive)
        let kept = parsed.entries.filter { entry in
            let path = normalize(entry.name)
            for target in targets {
                let probe = entry.isDirectory ? path + "/" : path
                if entry.name == target || probe == target
                    || entry.name.hasPrefix(target + "/") { return false }
            }
            return true
        }
        let removed = parsed.entries.count - kept.count
        guard removed > 0 else { return 0 }

        try rewrite(entries: kept, commentBytes: parsed.comment, to: archive, reporter: reporter)
        reporter.finish(message: "已删除 \(removed) 项", subtitle: archive.lastPathComponent)
        return removed
    }

    /// 移除系统杂质 (.DS_Store / __MACOSX / ._* / .localized)。返回移除条目数。
    @discardableResult
    public static func cleanSystemJunk(
        in archive: URL,
        reporter: ArchiveProgressReporting
    ) throws -> Int {
        let parsed = try readCentralDirectory(archive)
        let kept = parsed.entries.filter { !isSystemJunk($0.name) }
        let removed = parsed.entries.count - kept.count
        guard removed > 0 else { return 0 }

        try rewrite(entries: kept, commentBytes: parsed.comment, to: archive, reporter: reporter)
        reporter.finish(message: "已清理 \(removed) 项", subtitle: archive.lastPathComponent)
        return removed
    }

    /// 追加文件/目录。`into` 非空时挂到该子目录下。`password` 用于加密新增条目
    /// (归档本身加密时必须传入同一密码,由调用方校验)。
    @discardableResult
    public static func add(
        inputs: [URL],
        to archive: URL,
        into folder: String? = nil,
        password: String?,
        level: ZlibCodec.Level,
        useAES: Bool = false,
        reporter: ArchiveProgressReporting
    ) throws -> Int {
        guard !inputs.isEmpty else { return 0 }
        let parsed = try readCentralDirectory(archive)

        // 1. 先用写入器把新文件压成一个临时包 (复用成熟的多线程压缩流水线)。
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("MacZip-add-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let tempZip = stagingDir.appendingPathComponent("additions.zip")
        let writer = ZipWriter(
            options: .init(level: level, password: password, excludeSystemJunk: false, useAES: useAES),
            reporter: reporter
        )
        try writer.write(inputs: inputs, to: tempZip)

        // 2. 解析临时包条目,按目标子目录前缀改名后并入。
        let additionsRaw = try readCentralDirectory(tempZip).entries
        let prefix = normalize(folder ?? "")
        let additions = additionsRaw.map { $0.renamed(prefix: prefix, forceUTF8: true) }
        guard !additions.isEmpty else { return 0 }

        try rewrite(
            entries: parsed.entries + additions,
            commentBytes: parsed.comment,
            to: archive,
            reporter: reporter
        )
        reporter.finish(message: "已增加 \(additions.count) 项", subtitle: archive.lastPathComponent)
        return additions.count
    }

    // MARK: - 写包 (搬运 + 重建中央目录)

    private static func rewrite(
        entries: [RawEntry],
        commentBytes: Data,
        to outputURL: URL,
        reporter: ArchiveProgressReporting
    ) throws {
        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.csize }
        reporter.begin(totalBytes: totalBytes, title: "正在更新压缩包")

        // 写到同目录临时文件后原子替换,避免中途失败损坏原包。
        let tmpURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".maczip-edit-\(UUID().uuidString).tmp")
        fm.createFile(atPath: tmpURL.path, contents: nil)

        do {
            try assemble(entries: entries, to: tmpURL, commentBytes: commentBytes, reporter: reporter)
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        // 保留原文件权限。
        if let attrs = try? fm.attributesOfItem(atPath: outputURL.path),
           let permissions = attrs[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmpURL.path)
        }

        _ = try fm.replaceItemAt(outputURL, withItemAt: tmpURL)
    }

    private static func assemble(
        entries: [RawEntry],
        to outputURL: URL,
        commentBytes: Data,
        reporter: ArchiveProgressReporting
    ) throws {
        let out = try FileHandle(forWritingTo: outputURL)
        defer { try? out.close() }
        try out.truncate(atOffset: 0)

        var centralRecords: [Data] = []
        var currentOffset: UInt64 = 0
        var anyZip64 = false

        // 每条目的源文件句柄缓存,减少反复 open。
        var handles: [URL: FileHandle] = [:]
        defer { for handle in handles.values { try? handle.close() } }

        for entry in entries {
            if reporter.isCancelled { throw ZipError.cancelled }
            reporter.willProcessFile(entry.name)

            let source = try handle(for: entry.sourceURL, cache: &handles)

            // 读 local header 固定段 + 变长名称/扩展,确定负载起点。
            try source.seek(toOffset: entry.localOffset)
            let fixed = source.readData(ofLength: 30)
            guard fixed.count == 30, fixed.readLE32(at: 0) == 0x04034b50 else {
                throw ZipError.corruptEntry(reason: "local header 签名不符:\(entry.name)")
            }
            let localNameLen = Int(fixed.readLE16(at: 26))
            let localExtraLen = Int(fixed.readLE16(at: 28))
            let headerLen = 30 + localNameLen + localExtraLen
            let dataStart = entry.localOffset + UInt64(headerLen)

            // 1) 原样写 local header。
            try source.seek(toOffset: entry.localOffset)
            try copyBytes(from: source, count: headerLen, to: out, reporter: reporter)
            // 2) 原样写压缩负载。
            try copyBytes(from: source, count: Int(entry.csize), to: out, reporter: reporter)
            // 3) data descriptor (流式写入器,flags bit 3) 也要一并搬走。
            var descriptorLen = 0
            if (entry.flags & 0x0008) != 0 {
                try source.seek(toOffset: dataStart + entry.csize)
                let sig = source.readData(ofLength: 4)
                let hasSig = sig.count == 4 && sig.readLE32(at: 0) == 0x08074b50
                descriptorLen = hasSig ? 16 : 12
                try source.seek(toOffset: dataStart + entry.csize)
                try copyBytes(from: source, count: descriptorLen, to: out, reporter: reporter)
            }

            centralRecords.append(try centralRecord(
                for: entry,
                localOffset: currentOffset,
                anyZip64: &anyZip64
            ))
            currentOffset += UInt64(headerLen) + entry.csize + UInt64(descriptorLen)
        }

        let cdOffset = currentOffset
        var cdSize: UInt64 = 0
        for record in centralRecords {
            try out.write(contentsOf: record)
            cdSize += UInt64(record.count)
        }

        let entryCount = UInt64(centralRecords.count)
        let needsZip64 = anyZip64 || entryCount >= 0xFFFF || cdSize >= 0xFFFFFFFF || cdOffset >= 0xFFFFFFFF
        if needsZip64 {
            var z64 = Data()
            z64.appendLE(UInt32(0x06064b50))
            z64.appendLE(UInt64(44))
            z64.appendLE(ZipVersion.zip64)
            z64.appendLE(ZipVersion.zip64)
            z64.appendLE(UInt32(0))
            z64.appendLE(UInt32(0))
            z64.appendLE(entryCount)
            z64.appendLE(entryCount)
            z64.appendLE(cdSize)
            z64.appendLE(cdOffset)
            try out.write(contentsOf: z64)

            var locator = Data()
            locator.appendLE(UInt32(0x07064b50))
            locator.appendLE(UInt32(0))
            locator.appendLE(cdOffset + cdSize)
            locator.appendLE(UInt32(1))
            try out.write(contentsOf: locator)
        }

        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(needsZip64 ? UInt16(0xFFFF) : UInt16(truncatingIfNeeded: entryCount))
        eocd.appendLE(needsZip64 ? UInt16(0xFFFF) : UInt16(truncatingIfNeeded: entryCount))
        eocd.appendLE(needsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: cdSize))
        eocd.appendLE(needsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: cdOffset))
        eocd.appendLE(UInt16(commentBytes.count))
        eocd.append(commentBytes)
        try out.write(contentsOf: eocd)
    }

    /// 重建一条中央目录记录;尺寸/偏移任一越界时补 ZIP64 扩展字段。
    private static func centralRecord(
        for entry: RawEntry,
        localOffset: UInt64,
        anyZip64: inout Bool
    ) throws -> Data {
        let sizeZip64 = entry.csize >= 0xFFFFFFFF || entry.usize >= 0xFFFFFFFF
        let offsetZip64 = localOffset >= 0xFFFFFFFF
        let needsZip64 = sizeZip64 || offsetZip64
        if needsZip64 { anyZip64 = true }

        // ZIP64 extra 字段按 usize / csize / offset 中"被哨兵化"的顺序依次出现。
        var extra = Data()
        if needsZip64 {
            var body = Data()
            var fieldCount = 0
            if entry.usize >= 0xFFFFFFFF { body.appendLE(entry.usize); fieldCount += 1 }
            if entry.csize >= 0xFFFFFFFF { body.appendLE(entry.csize); fieldCount += 1 }
            if offsetZip64 { body.appendLE(localOffset); fieldCount += 1 }
            extra.appendLE(UInt16(0x0001))
            extra.appendLE(UInt16(fieldCount * 8))
            extra.append(body)
        }

        var central = Data()
        central.appendLE(UInt32(0x02014b50))
        central.appendLE(entry.versionMadeBy == 0 ? ZipVersion.madeBy : entry.versionMadeBy)
        central.appendLE(needsZip64 ? ZipVersion.zip64 : ZipVersion.madeBy)
        central.appendLE(entry.flags)
        central.appendLE(entry.method)
        central.appendLE(entry.dosTime)
        central.appendLE(entry.dosDate)
        central.appendLE(entry.crc)
        central.appendLE(sizeZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: entry.csize))
        central.appendLE(sizeZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: entry.usize))
        central.appendLE(UInt16(truncatingIfNeeded: entry.nameBytes.count))
        central.appendLE(UInt16(truncatingIfNeeded: extra.count))
        central.appendLE(UInt16(truncatingIfNeeded: entry.commentBytes.count))
        central.appendLE(UInt16(0))                       // disk number
        central.appendLE(UInt16(0))                       // internal attrs
        central.appendLE(entry.externalAttrs)
        central.appendLE(offsetZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: localOffset))
        central.append(entry.nameBytes)
        central.append(extra)
        central.append(entry.commentBytes)
        return central
    }

    // MARK: - 底层 IO

    private static func handle(for url: URL, cache: inout [URL: FileHandle]) throws -> FileHandle {
        if let existing = cache[url] { return existing }
        let handle = try FileHandle(forReadingFrom: url)
        cache[url] = handle
        return handle
    }

    private static func copyBytes(
        from source: FileHandle,
        count: Int,
        to output: FileHandle,
        reporter: ArchiveProgressReporting
    ) throws {
        let sourceFD = source.fileDescriptor
        let outputFD = output.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: ChunkedIO.bufferSize)
        try buffer.withUnsafeMutableBufferPointer { buf in
            var remaining = count
            while remaining > 0 {
                if reporter.isCancelled { throw ZipError.cancelled }
                let want = min(remaining, buf.count)
                try ChunkedIO.readFull(
                    fd: sourceFD,
                    into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                    want: want
                )
                try ChunkedIO.write(
                    fd: outputFD,
                    from: UnsafeRawBufferPointer(start: buf.baseAddress, count: want)
                )
                remaining -= want
                reporter.advance(by: UInt64(want))
            }
        }
    }

    // MARK: - 中央目录解析

    private static func readCentralDirectory(
        _ archive: URL
    ) throws -> (entries: [RawEntry], comment: Data) {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 22 else { throw ZipError.centralDirectoryNotFound }

        let scanWindow = Int(min(fileSize, 22 + 65535))
        try handle.seek(toOffset: fileSize - UInt64(scanWindow))
        let tail = handle.readDataToEndOfFile()
        guard let eocd = findEOCD(in: tail) else { throw ZipError.centralDirectoryNotFound }

        var count = Int(tail.readLE16(at: eocd + 10))
        var cdSize = UInt64(tail.readLE32(at: eocd + 12))
        var cdOffset = UInt64(tail.readLE32(at: eocd + 16))
        let commentLen = Int(tail.readLE16(at: eocd + 20))
        var comment = Data()
        if commentLen > 0, eocd + 22 + commentLen <= tail.count {
            comment = tail.subdata(in: (eocd + 22)..<(eocd + 22 + commentLen))
        }

        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            let locator = eocd - 20
            if locator >= 0, tail.readLE32(at: locator) == 0x07064b50 {
                let z64Offset = tail.readLE64(at: locator + 8)
                if let z64Handle = try? FileHandle(forReadingFrom: archive) {
                    defer { try? z64Handle.close() }
                    try? z64Handle.seek(toOffset: z64Offset)
                    let d = z64Handle.readData(ofLength: 56)
                    if d.count == 56, d.readLE32(at: 0) == 0x06064b50 {
                        count = Int(d.readLE64(at: 32))
                        cdSize = d.readLE64(at: 40)
                        cdOffset = d.readLE64(at: 48)
                    }
                }
            }
        }

        try handle.seek(toOffset: cdOffset)
        let cd = handle.readData(ofLength: Int(cdSize))
        guard cd.count == Int(cdSize) else { throw ZipError.truncatedEntry }

        var entries: [RawEntry] = []
        entries.reserveCapacity(min(count, 1_000_000))
        var cursor = 0
        while cursor + 46 <= cd.count, cd.readLE32(at: cursor) == 0x02014b50 {
            let versionMadeBy = cd.readLE16(at: cursor + 4)
            let flags = cd.readLE16(at: cursor + 8)
            let method = cd.readLE16(at: cursor + 10)
            let dosTime = cd.readLE16(at: cursor + 12)
            let dosDate = cd.readLE16(at: cursor + 14)
            let crc = cd.readLE32(at: cursor + 16)
            var csize = UInt64(cd.readLE32(at: cursor + 20))
            var usize = UInt64(cd.readLE32(at: cursor + 24))
            let nameLen = Int(cd.readLE16(at: cursor + 28))
            let extraLen = Int(cd.readLE16(at: cursor + 30))
            let commLen = Int(cd.readLE16(at: cursor + 32))
            let externalAttrs = cd.readLE32(at: cursor + 38)
            var offset = UInt64(cd.readLE32(at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLen <= cd.count else {
                throw ZipError.corruptEntry(reason: "中央目录文件名越界")
            }
            let nameBytes = cd.subdata(in: nameStart..<(nameStart + nameLen))

            var extraCursor = nameStart + nameLen
            let extraEnd = extraCursor + extraLen
            while extraCursor + 4 <= extraEnd {
                let extraID = cd.readLE16(at: extraCursor)
                let extraSize = Int(cd.readLE16(at: extraCursor + 2))
                if extraID == 0x0001 {
                    var fieldCursor = extraCursor + 4
                    if usize == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd { usize = cd.readLE64(at: fieldCursor); fieldCursor += 8 }
                    if csize == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd { csize = cd.readLE64(at: fieldCursor); fieldCursor += 8 }
                    if offset == 0xFFFFFFFF, fieldCursor + 8 <= extraEnd { offset = cd.readLE64(at: fieldCursor); fieldCursor += 8 }
                }
                extraCursor += 4 + extraSize
            }

            let commentStart = nameStart + nameLen + extraLen
            let commentEnd = min(commentStart + commLen, cd.count)
            entries.append(RawEntry(
                sourceURL: archive,
                localOffset: offset,
                name: ZipEntryNameDecoder.decode(nameBytes, isUTF8Declared: (flags & 0x0800) != 0),
                nameBytes: nameBytes,
                flags: flags,
                method: method,
                crc: crc,
                csize: csize,
                usize: usize,
                dosTime: dosTime,
                dosDate: dosDate,
                externalAttrs: externalAttrs,
                versionMadeBy: versionMadeBy,
                commentBytes: cd.subdata(in: commentStart..<commentEnd)
            ))
            cursor = commentStart + commLen
        }
        return (entries, comment)
    }

    private static func findEOCD(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x06054b50 {
                let commentLen = Int(tail.readLE16(at: i + 20))
                if i + 22 + commentLen == tail.count { return i }
            }
            i -= 1
        }
        i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - 注释查看 / 编辑 (仅重写 EOCD 尾部,不触碰中央目录与条目负载)

    private struct TailInfo {
        /// EOCD 在文件中的起始偏移。
        var eocdOffset: UInt64
        /// EOCD 起始前需原样保留的字节 (ZIP64 EOCD + 定位器;无 ZIP64 时为空)。
        var preservedBytes: Data
        /// EOCD 固定 22 字节 (含旧注释长度字段,重写时覆盖)。
        var eocdFixedBytes: Data
        /// 现有注释字节。
        var commentBytes: Data
    }

    private static func readTailInfo(handle: FileHandle, archive: URL) throws -> TailInfo {
        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 22 else { throw ZipError.centralDirectoryNotFound }

        let scanWindow = Int(min(fileSize, 22 + 65535))
        try handle.seek(toOffset: fileSize - UInt64(scanWindow))
        let tail = handle.readDataToEndOfFile()
        guard let eocd = findEOCD(in: tail) else { throw ZipError.centralDirectoryNotFound }
        let tailStart = fileSize - UInt64(tail.count)
        let eocdAbsolute = tailStart + UInt64(eocd)

        var commentBytes = Data()
        let commentLen = Int(tail.readLE16(at: eocd + 20))
        if commentLen > 0, eocd + 22 + commentLen <= tail.count {
            commentBytes = tail.subdata(in: (eocd + 22)..<(eocd + 22 + commentLen))
        }

        // ZIP64:计数/尺寸哨兵 → EOCD 前有 [ZIP64 EOCD][定位器],原样保留。
        var preservedBytes = Data()
        let count = Int(tail.readLE16(at: eocd + 10))
        let cdSize = UInt64(tail.readLE32(at: eocd + 12))
        let cdOffset = UInt64(tail.readLE32(at: eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            let locatorOffset = eocd - 20
            if locatorOffset >= 0, tail.readLE32(at: locatorOffset) == 0x07064b50 {
                let z64TailOffset = Int(tail.readLE64(at: locatorOffset + 8)) - Int(tailStart)
                // z64 EOCD 总长 = 12 + sizeOfRecord (含 extensible data)。
                if z64TailOffset >= 0, z64TailOffset + 12 <= locatorOffset {
                    let sizeOfRecord = Int(tail.readLE64(at: z64TailOffset + 4))
                    let z64Total = 12 + sizeOfRecord
                    if z64TailOffset >= 0, z64TailOffset + z64Total <= locatorOffset {
                        preservedBytes = tail.subdata(in: z64TailOffset..<eocd)
                    }
                }
            }
        }

        return TailInfo(
            eocdOffset: eocdAbsolute,
            preservedBytes: preservedBytes,
            eocdFixedBytes: tail.subdata(in: eocd..<(eocd + 22)),
            commentBytes: commentBytes
        )
    }

    /// 读取归档注释 (UTF-8 优先,失败按宽松解码;无注释返回空串)。
    public static func comment(of archive: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let tail = try readTailInfo(handle: handle, archive: archive)
        return String(data: tail.commentBytes, encoding: .utf8)
            ?? String(decoding: tail.commentBytes, as: UTF8.self)
    }

    /// 设置/清除归档注释 (空串即清除)。截断重写尾部,原包其余字节不动。
    public static func setComment(_ comment: String, on archive: URL) throws {
        let commentBytes = Data(comment.utf8)
        guard commentBytes.count <= 65535 else {
            throw ZipError.corruptEntry(reason: "注释超过 65535 字节上限")
        }
        let handle = try FileHandle(forUpdating: archive)
        defer { try? handle.close() }
        let tail = try readTailInfo(handle: handle, archive: archive)

        let prefixStart = tail.eocdOffset - UInt64(tail.preservedBytes.count)
        try handle.seek(toOffset: prefixStart)
        try handle.truncate(atOffset: prefixStart)

        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        // fixedBytes[4..<20] = 磁盘号/计数/CD 尺寸/CD 偏移 (不含旧注释长度字段,避免重复)。
        eocd.append(tail.eocdFixedBytes.subdata(in: 4..<20))
        eocd.appendLE(UInt16(commentBytes.count))
        eocd.append(commentBytes)

        try handle.write(contentsOf: tail.preservedBytes)
        try handle.write(contentsOf: eocd)
    }

    // MARK: - 工具

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return p == "/" ? "" : p
    }

    private static func isSystemJunk(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base == ".DS_Store" || base == ".localized"
            || name.contains("__MACOSX/")
            || (base.hasPrefix("._") && base.count > 2)
    }
}
