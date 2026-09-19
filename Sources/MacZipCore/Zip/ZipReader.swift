import Foundation
import Darwin

/// MacZip 自研多线程 ZIP 读取器。
///
/// - 定位 EOCD / ZIP64 EOCD → 解析中央目录 → 并行解压各条目;
/// - 支持 method 0 (store) / 8 (deflate)、ZipCrypto 传统加密、UTF-8 文件名、数据描述符;
/// - 解压、测试完整性、列目录共用同一套解析与校验管线;
/// - 并发条目各自持有独立 FileHandle,规避 seek 竞态。
public final class ZipReader {
    /// 多文件解压的默认并发度。
    ///
    /// 每个文件至少持有输入/输出各一个 1 MiB 缓冲区。限制默认并发度既
    /// 避免小文件场景产生过多文件系统操作,也给 SSD/网络盘留出 I/O 队列空间。
    public static let defaultMaxConcurrency = max(
        1,
        min(ProcessInfo.processInfo.activeProcessorCount, 4)
    )

    /// 解析出的中央目录。
    public struct CentralDirectory {
        public var entries: [ZipEntryInfo]
        public var comment: String?
    }

    /// 解压选项。
    public struct ExtractOptions {
        /// 单条目出错时的处理策略。
        public enum ErrorPolicy {
            /// 首个错误即中止 (默认容忍策略见 skipCorrupt)。
            case abortFirst
            /// 跳过损坏/无法读取的条目继续解压,结束后抛 partialFailure 汇总。
            case skipCorrupt
        }

        /// 解压目标根目录。
        public var destination: URL
        /// 明确指定的密码;nil 时先试密码本。
        public var password: String?
        /// 密码本候选 (自动尝试);解密失败时逐个回退。
        public var passwordCandidates: [String]
        /// 仍无法解密时的用户交互回调 (返回用户输入的密码,可重试)。
        public var passwordPrompt: ((String, Int) -> String?)?
        /// 冲突策略。
        public var conflictPolicy: ConflictPolicy
        /// 条目级错误策略 (取消与 I/O 错误在任何策略下都中止)。
        public var errorPolicy: ErrorPolicy
        public var maxConcurrency: Int

        public init(
            destination: URL,
            password: String? = nil,
            passwordCandidates: [String] = [],
            passwordPrompt: ((String, Int) -> String?)? = nil,
            conflictPolicy: ConflictPolicy = .rename,
            errorPolicy: ErrorPolicy = .skipCorrupt,
            maxConcurrency: Int = ZipReader.defaultMaxConcurrency
        ) {
            self.destination = destination
            self.password = password
            self.passwordCandidates = passwordCandidates
            self.passwordPrompt = passwordPrompt
            self.conflictPolicy = conflictPolicy
            self.errorPolicy = errorPolicy
            self.maxConcurrency = maxConcurrency
        }
    }

    /// 解压冲突策略。
    public enum ConflictPolicy: String, Codable, CaseIterable {
        case rename     // 自动重命名 (name 2.zip)
        case overwrite  // 直接覆盖
        case skip       // 跳过同名

        public var localizedName: String {
            switch self {
            case .rename: return "自动重命名"
            case .overwrite: return "覆盖旧文件"
            case .skip: return "跳过同名文件"
            }
        }
    }

    private let archiveURL: URL
    private let fm = FileManager.default
    /// entry index → 中央目录中的 local header offset。解析后只读。
    /// 数组比 Dictionary 少一层哈希表和节点分配,对几十万条目更省内存。
    private var localOffsets: [UInt64] = []
    private var cachedCentralDirectory: CentralDirectory?

    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    // MARK: - 中央目录解析

    /// 解析中央目录 (只读文件列表,供 QuickLook 预览与解压共用)。
    public func readCentralDirectory() throws -> CentralDirectory {
        if let cachedCentralDirectory {
            return cachedCentralDirectory
        }

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 22 else { throw ZipError.centralDirectoryNotFound }

        // 回扫窗口:EOCD 最长 22 + 65535 (注释) 字节。
        let scanWindow = Int(min(fileSize, 22 + 65535))
        try handle.seek(toOffset: fileSize - UInt64(scanWindow))
        let tail = handle.readDataToEndOfFile()

        guard let eocdOffset = findEOCDOffset(in: tail) else {
            throw ZipError.centralDirectoryNotFound
        }

        var entriesTotal = Int(tail.readLE16(at: eocdOffset + 10))
        var cdSize = UInt64(tail.readLE32(at: eocdOffset + 12))
        var cdOffset = UInt64(tail.readLE32(at: eocdOffset + 16))
        var comment: String?
        let commentLength = Int(tail.readLE16(at: eocdOffset + 20))
        if commentLength > 0 {
            let start = eocdOffset + 22
            if start + commentLength <= tail.count {
                comment = ZipEntryNameDecoder.decode(
                    tail.subdata(in: start..<(start + commentLength)),
                    isUTF8Declared: false
                )
            }
        }

        // ZIP64:计数/大小/偏移任一饱和即查 ZIP64 EOCD 定位器。
        if entriesTotal == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            if let (z64Entries, z64Size, z64Offset) = locateZip64EOCD(in: tail, eocdOffset: eocdOffset, fileSize: fileSize) {
                entriesTotal = z64Entries
                cdSize = z64Size
                cdOffset = z64Offset
            }
        }

        guard cdSize <= UInt64(Int.max) else {
            throw ZipError.corruptEntry(reason: "中央目录超过当前系统可寻址大小")
        }
        let cdData: Data
        if cdSize == 0 {
            cdData = Data()
        } else if let mapped = mapCentralDirectory(
            fileDescriptor: handle.fileDescriptor,
            offset: cdOffset,
            length: Int(cdSize)
        ) {
            // Data 持有 mmap 的自定义释放闭包,解析期间不会提前解除映射。
            cdData = mapped
        } else {
            try handle.seek(toOffset: cdOffset)
            cdData = handle.readData(ofLength: Int(cdSize))
        }
        guard cdData.count == Int(cdSize) else { throw ZipError.truncatedEntry }

        var entries: [ZipEntryInfo] = []
        entries.reserveCapacity(min(entriesTotal, 1_000_000))
        var offsets: [UInt64] = []
        offsets.reserveCapacity(min(entriesTotal, 1_000_000))
        var cursor = 0
        while cursor + 46 <= cdData.count {
            guard cdData.readLE32(at: cursor) == 0x02014b50 else { break }
            let flags = cdData.readLE16(at: cursor + 8)
            let method = cdData.readLE16(at: cursor + 10)
            let dosTime = cdData.readLE16(at: cursor + 12)
            let dosDate = cdData.readLE16(at: cursor + 14)
            let crc = cdData.readLE32(at: cursor + 16)
            var csize = UInt64(cdData.readLE32(at: cursor + 20))
            var usize = UInt64(cdData.readLE32(at: cursor + 24))
            let nameLen = Int(cdData.readLE16(at: cursor + 28))
            let extraLen = Int(cdData.readLE16(at: cursor + 30))
            let commentLen = Int(cdData.readLE16(at: cursor + 32))
            let localOffset = UInt64(cdData.readLE32(at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= cdData.count else { throw ZipError.corruptEntry(reason: "中央目录文件名越界") }
            let nameData = cdData.subdata(in: nameStart..<nameEnd)
            let rawName = ZipEntryNameDecoder.decode(nameData, isUTF8Declared: (flags & 0x0800) != 0)

            // ZIP64 extra:扫描 id=0x0001,按哨兵字段顺次取 64 位值。
            var extraCursor = nameEnd
            let extraEnd = nameEnd + extraLen
            while extraCursor + 4 <= extraEnd {
                let extraID = cdData.readLE16(at: extraCursor)
                let extraSize = Int(cdData.readLE16(at: extraCursor + 2))
                if extraID == 0x0001 {
                    var fieldCursor = extraCursor + 4
                    let fieldEnd = min(extraCursor + 4 + extraSize, extraEnd)
                    if usize == 0xFFFFFFFF && fieldCursor + 8 <= fieldEnd {
                        usize = cdData.readLE64(at: fieldCursor); fieldCursor += 8
                    }
                    if csize == 0xFFFFFFFF && fieldCursor + 8 <= fieldEnd {
                        csize = cdData.readLE64(at: fieldCursor); fieldCursor += 8
                    }
                }
                extraCursor += 4 + extraSize
            }

            let isDirectory = rawName.hasSuffix("/")
            let isEncrypted = (flags & 0x0001) != 0
            // 自研分块并行布局 (0x6D7A);外部包无此字段,parse 返回 nil。
            let blockMap = ZipBlockMap.parse(from: cdData, range: nameEnd..<extraEnd)

            offsets.append(localOffset)
            entries.append(ZipEntryInfo(
                name: rawName,
                isDirectory: isDirectory,
                compressedSize: csize,
                uncompressedSize: usize,
                crc: crc,
                method: method,
                isEncrypted: isEncrypted,
                lastModified: DOSTime.toDate(dosTime: dosTime, dosDate: dosDate),
                index: entries.count,
                blockMap: blockMap
            ))
            cursor = nameEnd + extraLen + commentLen
        }

        localOffsets = offsets
        let directory = CentralDirectory(entries: entries, comment: comment)
        cachedCentralDirectory = directory
        return directory
    }

    /// 将中央目录映射为只读 Data,避免先分配一份与中央目录等大的堆缓冲。
    /// 映射失败时由调用方回退到 FileHandle 分块读取路径。
    private func mapCentralDirectory(
        fileDescriptor: Int32,
        offset: UInt64,
        length: Int
    ) -> Data? {
        guard length > 0 else { return Data() }
        let pageSize = Int(getpagesize())
        guard pageSize > 0 else { return nil }

        let alignedOffset = offset - (offset % UInt64(pageSize))
        let delta = Int(offset - alignedOffset)
        guard length <= Int.max - delta else { return nil }
        let mappedLength = length + delta
        guard alignedOffset <= UInt64(Int64.max) else { return nil }

        let mapped = mmap(
            nil,
            mappedLength,
            PROT_READ,
            MAP_PRIVATE,
            fileDescriptor,
            off_t(alignedOffset)
        )
        guard mapped != MAP_FAILED, let base = mapped else { return nil }

        let visible = base.advanced(by: delta)
        return Data(
            bytesNoCopy: visible,
            count: length,
            deallocator: .custom { _, _ in
                _ = munmap(base, mappedLength)
            }
        )
    }

    private func localOffset(for entry: ZipEntryInfo) -> UInt64? {
        guard entry.index >= 0, entry.index < localOffsets.count else { return nil }
        return localOffsets[entry.index]
    }

    private func findEOCDOffset(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x06054b50 {
                // 一致性校验:注释长度必须恰好补齐到数据末尾。
                let commentLen = Int(tail.readLE16(at: i + 20))
                if i + 22 + commentLen == tail.count {
                    return i
                }
            }
            i -= 1
        }
        // 容错:个别工具写的注释长度不一致,回退取最后一个命中。
        i = tail.count - 22
        while i >= 0 {
            if tail.readLE32(at: i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private func locateZip64EOCD(
        in tail: Data,
        eocdOffset: Int,
        fileSize: UInt64
    ) -> (entries: Int, cdSize: UInt64, cdOffset: UInt64)? {
        // 定位器紧贴 EOCD 之前 (20 字节)。
        let locatorOffset = eocdOffset - 20
        guard locatorOffset >= 0 else { return nil }
        guard tail.readLE32(at: locatorOffset) == 0x07064b50 else { return nil }
        let z64EOCDOffset = tail.readLE64(at: locatorOffset + 8)
        // ZIP64 EOCD 可能不在回扫窗口内,单独读取。
        guard z64EOCDOffset + 56 <= fileSize else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: archiveURL) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: z64EOCDOffset)
        let data = handle.readData(ofLength: 56)
        guard data.count == 56, data.readLE32(at: 0) == 0x06064b50 else { return nil }
        let entries = Int(data.readLE64(at: 32))
        let cdSize = data.readLE64(at: 40)
        let cdOffset = data.readLE64(at: 48)
        return (entries, cdSize, cdOffset)
    }

    // MARK: - 文件列表 (QuickLook 预览用)

    public func listEntries() throws -> [ZipEntryInfo] {
        try readCentralDirectory().entries
    }

    // MARK: - 单条目按需解压 (预览用)

    /// 解压单个条目到目标文件 (预览窗口按需读取内容)。加密条目需提供可用密码,
    /// 否则抛 `ZipError.wrongPassword`。返回写出字节数;目录条目返回 0。
    ///
    /// 与批量解压共用同一套 inflate / ZipCrypto / CRC 校验管线,不做路径穿越决策
    /// (调用方负责给出安全的落盘路径)。
    @discardableResult
    public func extractEntry(
        _ entry: ZipEntryInfo,
        to destination: URL,
        password: String?,
        passwordCandidates: [String] = []
    ) throws -> UInt64 {
        guard !entry.isDirectory else { return 0 }

        // 极端情况:调用方未曾列目录 (localOffsets 为空) 时补解析一次。
        if localOffset(for: entry) == nil {
            _ = try readCentralDirectory()
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        fm.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)

        do {
            let resolver = PasswordResolver(
                explicit: password,
                candidates: passwordCandidates,
                prompt: nil
            )
            let resolved = try resolver.resolveIfNeeded(isEncrypted: entry.isEncrypted) { candidate in
                (try? self.verifyPassword(candidate: candidate, for: entry)) ?? false
            }
            try inflateEntry(
                entry,
                password: resolved,
                output: output,
                reporter: NullProgressReporter()
            )
            try? output.close()
            if let modified = entry.lastModified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: destination)
            throw error
        }
        return entry.uncompressedSize
    }

    // MARK: - 解压

    /// 并行解压全部条目到目标目录。返回解压出的文件数。
    @discardableResult
    public func extractAll(
        entries: [ZipEntryInfo]? = nil,
        options: ExtractOptions,
        reporter: ArchiveProgressReporting
    ) throws -> Int {
        let cd = try readCentralDirectory()
        let targets = entries ?? cd.entries
        guard !targets.isEmpty else { return 0 }

        try fm.createDirectory(at: options.destination, withIntermediateDirectories: true)
        let plan = try buildExtractionPlan(for: targets, options: options)
        try prepareDirectories(
            destinations: plan.destinations,
            entries: targets,
            destination: options.destination
        )

        reporter.begin(
            totalBytes: plan.totalBytes,
            title: "正在解压 \(plan.fileCount) 个文件"
        )

        // 预解析密码策略。
        let resolver = PasswordResolver(
            explicit: options.password,
            candidates: options.passwordCandidates,
            prompt: options.passwordPrompt
        )

        var firstError: Error?
        var skippedEntries: [String] = []
        let lock = NSLock()
        // 自研分块条目内部会按 CPU 核数并行 inflate。此时只允许一个条目
        // 进入解压管线,避免文件级与块级并发相乘,造成线程/缓冲区和磁盘争用。
        let concurrency = plan.hasParallelBlock
            ? 1
            : max(1, min(options.maxConcurrency, max(1, plan.fileCount)))
        let semaphore = DispatchSemaphore(value: concurrency)
        let group = DispatchGroup()

        for (index, entry) in targets.enumerated() {
            let outputPath = plan.destinations[index]
            lock.lock()
            let shouldStop = firstError != nil
            lock.unlock()
            if shouldStop || reporter.isCancelled { break }
            semaphore.wait()
            lock.lock()
            let shouldStopAfterWait = firstError != nil
            lock.unlock()
            if shouldStopAfterWait || reporter.isCancelled {
                semaphore.signal()
                break
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    group.leave()
                    semaphore.signal()
                }
                guard let self else { return }
                do {
                    try self.extractEntry(
                        entry,
                        destination: outputPath,
                        resolver: resolver,
                        reporter: reporter
                    )
                } catch {
                    lock.lock()
                    // 取消与 I/O 错误任何策略下都中止;仅数据类错误可跳过。
                    if Self.isCancellable(error) {
                        if firstError == nil { firstError = error }
                    } else if options.errorPolicy == .skipCorrupt, Self.isSkippable(error) {
                        skippedEntries.append(entry.name)
                    } else if firstError == nil {
                        firstError = error
                    }
                    lock.unlock()
                }
            }
        }
        group.wait()

        if reporter.isCancelled && firstError == nil { throw ZipError.cancelled }
        if let error = firstError { throw error }
        if !skippedEntries.isEmpty {
            throw ZipError.partialFailure(skipped: skippedEntries.sorted())
        }
        reporter.finish(message: "解压完成", subtitle: archiveURL.lastPathComponent)
        return plan.fileCount
    }

    /// 取消类错误:任何策略下都中止。
    private static func isCancellable(_ error: Error) -> Bool {
        error is CancellationError || (error as? ZipError) == .cancelled
    }

    /// 可跳过的数据类错误 (损坏 / 截断 / 方法不支持 / 口令无法确定)。
    private static func isSkippable(_ error: Error) -> Bool {
        switch error as? ZipError {
        case .corruptEntry, .truncatedEntry, .unsupportedMethod, .wrongPassword:
            return true
        default:
            return false
        }
    }

    // MARK: - 完整性测试

    /// 逐条目解压校验 (不落盘)。错误密码/损坏数据即失败。
    public func test(options: ExtractOptions, reporter: ArchiveProgressReporting) throws {
        let cd = try readCentralDirectory()
        let targets = cd.entries.filter { !$0.isDirectory }
        guard !targets.isEmpty else {
            throw ZipError.corruptEntry(reason: "压缩包内没有可测试的文件")
        }
        let totalBytes = targets.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        reporter.begin(totalBytes: totalBytes, title: "正在测试 \(targets.count) 个文件")

        let resolver = PasswordResolver(
            explicit: options.password,
            candidates: options.passwordCandidates,
            prompt: options.passwordPrompt
        )

        var firstError: Error?
        let lock = NSLock()
        let hasParallelBlock = targets.contains {
            ($0.blockMap?.segmentSizes.count ?? 0) > 1
        }
        let concurrency = hasParallelBlock
            ? 1
            : max(1, min(options.maxConcurrency, targets.count))
        let semaphore = DispatchSemaphore(value: concurrency)
        let group = DispatchGroup()

        for entry in targets {
            lock.lock()
            let shouldStop = firstError != nil
            lock.unlock()
            if shouldStop || reporter.isCancelled { break }

            semaphore.wait()
            lock.lock()
            let shouldStopAfterWait = firstError != nil
            lock.unlock()
            if shouldStopAfterWait || reporter.isCancelled {
                semaphore.signal()
                break
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    group.leave()
                    semaphore.signal()
                }
                guard let self else { return }
                do {
                    try self.inflateEntryForTest(entry, resolver: resolver, reporter: reporter)
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        group.wait()
        if reporter.isCancelled && firstError == nil { throw ZipError.cancelled }
        if let error = firstError { throw error }
        reporter.finish(message: "压缩包完好", subtitle: archiveURL.lastPathComponent)
    }

    // MARK: - 单条目处理

    private struct ExtractionPlan {
        /// 与输入 entries 按索引对应。nil 表示该条目被 skip 策略跳过。
        var destinations: [String?]
        var fileCount: Int
        var totalBytes: UInt64
        var hasParallelBlock: Bool
    }

    /// 规范化 ZIP 相对路径。保持现有兼容行为:剥掉根符号、盘符和 .. 组件,
    /// 空路径仍视为非法条目。
    private func safePathComponents(for entryName: String) throws -> [String] {
        // 防路径穿越:剥掉盘符/根符号与 .. 组件。
        let components = entryName.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { $0 != ".." && $0 != "." && !$0.hasSuffix(":") }
        guard !components.isEmpty else {
            throw ZipError.pathTraversalDetected(entryName: entryName)
        }
        return components
    }

    private func url(
        for components: [String],
        destination: URL
    ) -> URL {
        components.reduce(destination) { $0.appendingPathComponent($1) }
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 串行生成唯一落盘路径,将冲突决策从 worker 中移出。
    private func buildExtractionPlan(
        for entries: [ZipEntryInfo],
        options: ExtractOptions
    ) throws -> ExtractionPlan {
        // 只保留路径字符串,不复制 ZipEntryInfo 或长期持有 URL 对象。
        var destinations = Array<String?>(repeating: nil, count: entries.count)
        var occupied = Set<String>()

        // 先登记目录,防止归档内同名文件与目录在并发时互相覆盖。
        for (index, entry) in entries.enumerated() where entry.isDirectory {
            let components = try safePathComponents(for: entry.name)
            let directoryURL = url(for: components, destination: options.destination)
            destinations[index] = directoryURL.path
            occupied.insert(pathKey(directoryURL))
        }

        var fileCount = 0
        var totalBytes: UInt64 = 0
        var hasParallelBlock = false
        for (index, entry) in entries.enumerated() where !entry.isDirectory {
            let components = try safePathComponents(for: entry.name)
            let baseComponents = Array(components.dropLast())
            let baseDir = url(for: baseComponents, destination: options.destination)
            let originalName = components[components.count - 1]
            var fileName = originalName
            var candidate: URL? = baseDir.appendingPathComponent(fileName)

            switch options.conflictPolicy {
            case .overwrite:
                break
            case .skip:
                if let current = candidate,
                   fm.fileExists(atPath: current.path) || occupied.contains(pathKey(current)) {
                    candidate = nil
                }
            case .rename:
                let stem = (originalName as NSString).deletingPathExtension
                let ext = (originalName as NSString).pathExtension
                var counter = 1
                while let current = candidate,
                      fm.fileExists(atPath: current.path) || occupied.contains(pathKey(current)) {
                    counter += 1
                    fileName = ext.isEmpty
                        ? "\(stem) \(counter)"
                        : "\(stem) \(counter).\(ext)"
                    candidate = baseDir.appendingPathComponent(fileName)
                }
            }

            if let candidate {
                destinations[index] = candidate.path
                occupied.insert(pathKey(candidate))
                fileCount += 1
                totalBytes += entry.uncompressedSize
                hasParallelBlock = hasParallelBlock
                    || (entry.blockMap?.segmentSizes.count ?? 0) > 1
            }
        }

        return ExtractionPlan(
            destinations: destinations,
            fileCount: fileCount,
            totalBytes: totalBytes,
            hasParallelBlock: hasParallelBlock
        )
    }

    /// 去重后一次性创建目录。worker 不再为每个文件重复 stat/createDirectory。
    private func prepareDirectories(
        destinations: [String?],
        entries: [ZipEntryInfo],
        destination: URL
    ) throws {
        var directories: Set<String> = [pathKey(destination)]
        for (index, outputPath) in destinations.enumerated() {
            guard let outputPath else { continue }
            let outputURL = URL(fileURLWithPath: outputPath)
            let directoryURL = entries[index].isDirectory
                ? outputURL
                : outputURL.deletingLastPathComponent()
            directories.insert(pathKey(directoryURL))
        }

        let ordered = directories.sorted {
            $0.count < $1.count
        }
        for directoryPath in ordered {
            try fm.createDirectory(
                at: URL(fileURLWithPath: directoryPath),
                withIntermediateDirectories: true
            )
        }
    }

    private func extractEntry(
        _ entry: ZipEntryInfo,
        destination outputPath: String?,
        resolver: PasswordResolver,
        reporter: ArchiveProgressReporting
    ) throws {
        guard !entry.isDirectory, let outputPath else { return }
        let outputURL = URL(fileURLWithPath: outputPath)

        reporter.willProcessFile(entry.name)

        let password = try resolver.resolveIfNeeded(isEncrypted: entry.isEncrypted) { candidate in
            (try? self.verifyPassword(candidate: candidate, for: entry)) ?? false
        }

        fm.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)

        do {
            try inflateEntry(entry, password: password, output: output, reporter: reporter)
            try? output.close()
            // 保留修改时间。
            if let modified = entry.lastModified {
                try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: outputURL.path)
            }
        } catch {
            try? output.close()
            try? fm.removeItem(at: outputURL)
            throw error
        }
    }

    private func inflateEntryForTest(
        _ entry: ZipEntryInfo,
        resolver: PasswordResolver,
        reporter: ArchiveProgressReporting
    ) throws {
        reporter.willProcessFile(entry.name)
        let password = try resolver.resolveIfNeeded(isEncrypted: entry.isEncrypted) { candidate in
            (try? self.verifyPassword(candidate: candidate, for: entry)) ?? false
        }
        try inflateEntry(entry, password: password, output: nil, reporter: reporter)
    }

    /// 校验某候选密码是否可用于该条目 (仅读 12 字节加密头,开销极小),供 UI 在做
    /// 增加/加密写入前确认密码。
    public func verifyPassword(_ password: String, for entry: ZipEntryInfo) throws -> Bool {
        try verifyPassword(candidate: password, for: entry)
    }

    /// 校验某候选密码是否可用于该条目。AES 条目比对盐后的 2 字节口令校验值
    /// (PBKDF2 派生);ZipCrypto 条目解密 12 字节头比对校验字节。
    private func verifyPassword(candidate: String, for entry: ZipEntryInfo) throws -> Bool {
        guard let offset = localOffset(for: entry) else { return false }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let header = try readLocalHeader(offset: offset, handle: handle)
        try handle.seek(toOffset: header.dataStartOffset)
        if let aes = header.aes {
            let head = handle.readData(ofLength: aes.headerLength)
            guard head.count == aes.headerLength else { return false }
            let salt = Array(head[0..<aes.saltLength])
            let verifier = Array(head[aes.saltLength..<aes.headerLength])
            return WinZipAES.verifierMatches(
                password: Array(candidate.utf8),
                salt: salt,
                verifier: verifier,
                keyLength: aes.keyLength
            )
        }
        let head = handle.readData(ofLength: ZipCrypto.headerLength)
        guard head.count == ZipCrypto.headerLength else { return false }
        var crypto = ZipCrypto.Context(password: Array(candidate.utf8))
        var decrypted = head
        decrypted.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            crypto.decryptInPlace(buf)
        }
        let expected: UInt8 = (header.flags & 0x0008) != 0
            ? ZipCrypto.checkByte(dosTime: header.dosTime)
            : ZipCrypto.checkByte(crc: entry.crc)
        return decrypted[ZipCrypto.headerLength - 1] == expected
    }

    private struct LocalHeaderInfo {
        var flags: UInt16
        var method: UInt16
        var dosTime: UInt16
        var dataStartOffset: UInt64
        /// 本地头的分块并行布局 (比中央目录更权威;nil = 单流)。
        var blockMap: ZipBlockMap?
        /// WinZip AES 加密信息 (本地头 method 99 时存在)。
        var aes: WinZipAESInfo?
    }

    private func readLocalHeader(offset: UInt64, handle: FileHandle) throws -> LocalHeaderInfo {
        try handle.seek(toOffset: offset)
        let fixed = handle.readData(ofLength: 30)
        guard fixed.count == 30, fixed.readLE32(at: 0) == 0x04034b50 else {
            throw ZipError.corruptEntry(reason: "local header 签名不符")
        }
        let flags = fixed.readLE16(at: 6)
        let method = fixed.readLE16(at: 8)
        let dosTime = fixed.readLE16(at: 10)
        let nameLen = Int(fixed.readLE16(at: 26))
        let extraLen = Int(fixed.readLE16(at: 28))

        var blockMap: ZipBlockMap?
        var aes: WinZipAESInfo?
        if extraLen > 0 {
            let nameAndExtra = handle.readData(ofLength: nameLen + extraLen)
            guard nameAndExtra.count == nameLen + extraLen else { throw ZipError.truncatedEntry }
            blockMap = ZipBlockMap.parse(from: nameAndExtra, range: nameLen..<nameAndExtra.count)
            aes = WinZipAES.parseInfo(from: nameAndExtra, range: nameLen..<nameAndExtra.count)
        }

        let dataStart = offset + 30 + UInt64(nameLen) + UInt64(extraLen)
        return LocalHeaderInfo(
            flags: flags,
            method: method,
            dosTime: dosTime,
            dataStartOffset: dataStart,
            blockMap: blockMap,
            aes: aes
        )
    }

    private func inflateEntry(
        _ entry: ZipEntryInfo,
        password: String?,
        output: FileHandle?,
        reporter: ArchiveProgressReporting
    ) throws {
        guard let offset = localOffset(for: entry) else {
            throw ZipError.corruptEntry(reason: "缺少条目定位信息")
        }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let header = try readLocalHeader(offset: offset, handle: handle)
        // 累计值 → 增量的换算器 (zlib 流回报累计输出,store 分支回报累计写入)。
        let counter = ProgressAccumulator { delta in reporter.advance(by: UInt64(delta)) }
        defer { counter.flush() }

        // WinWin AES 条目 (本地头 method 99 + extra 0x9901) 走独立解密管线。
        if let aes = header.aes {
            try inflateAESEntry(
                entry, aes: aes, handle: handle, header: header,
                password: password, output: output, reporter: reporter, counter: counter
            )
            return
        }

        // local header 缺 method 时回退中央目录记录 (个别流式写入器如此)。
        let method = header.method != 0 ? header.method : entry.method
        guard method == ZipMethod.store || method == ZipMethod.deflate else {
            throw ZipError.unsupportedMethod(method: method)
        }

        try handle.seek(toOffset: header.dataStartOffset)

        if method == ZipMethod.store {
            var crypto = makeCrypto(password: password)
            var crc: UInt32 = 0
            var written: UInt64 = 0
            let chunkSize = ChunkedIO.bufferSize
            var remaining = entry.compressedSize
            // ZipCrypto 加密头位于解密后字节流的最前端,写入与 CRC 前必须剔除。
            var headerBytesToSkip = crypto != nil ? ZipCrypto.headerLength : 0
            let inFD = handle.fileDescriptor
            let outFD = output?.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            try buffer.withUnsafeMutableBufferPointer { buf in
                while remaining > 0 {
                    if reporter.isCancelled { throw ZipError.cancelled }
                    let want = Int(min(UInt64(chunkSize), remaining))
                    try ChunkedIO.readFull(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: chunkSize),
                        want: want
                    )
                    remaining -= UInt64(want)
                    // 缓冲内就地解密,密钥流状态跨 chunk 连续。
                    crypto?.decryptInPlace(UnsafeMutableBufferPointer(start: buf.baseAddress, count: want))
                    var chunkStart = buf.baseAddress!
                    var chunkCount = want
                    if headerBytesToSkip > 0 {
                        let skip = min(headerBytesToSkip, chunkCount)
                        chunkStart = chunkStart.advanced(by: skip)
                        chunkCount -= skip
                        headerBytesToSkip -= skip
                    }
                    crc = CRC32.update(crc, UnsafeBufferPointer(start: chunkStart, count: chunkCount))
                    if let outFD {
                        try ChunkedIO.write(fd: outFD, from: UnsafeRawBufferPointer(start: chunkStart, count: chunkCount))
                    }
                    written += UInt64(chunkCount)
                    counter.add(written)
                }
            }
            guard crc == entry.crc else { throw ZipError.corruptEntry(reason: "store 条目 CRC 不符") }
        } else {
            let crypto = makeCrypto(password: password)
            var payloadSize = entry.compressedSize

            if let crypto {
                // ZipCrypto:12 字节加密头随负载一起解密。先单独解密头并验证校验字节,
                // 剩余负载分块边解密边喂 inflate——超大条目不再整段读入内存、不再落临时盘,
                // 内存占用恒定为分块大小。
                guard payloadSize >= UInt64(ZipCrypto.headerLength) else {
                    throw ZipError.corruptEntry(reason: "加密条目负载不足 12 字节加密头")
                }
                var mutableCrypto = crypto
                var head = handle.readData(ofLength: ZipCrypto.headerLength)
                guard head.count == ZipCrypto.headerLength else { throw ZipError.truncatedEntry }
                head.withUnsafeMutableBytes { raw in
                    let buf = raw.bindMemory(to: UInt8.self)
                    mutableCrypto.decryptInPlace(buf)
                }
                let expected: UInt8 = (header.flags & 0x0008) != 0
                    ? ZipCrypto.checkByte(dosTime: header.dosTime)
                    : ZipCrypto.checkByte(crc: entry.crc)
                guard head[ZipCrypto.headerLength - 1] == expected else {
                    throw ZipError.wrongPassword
                }
                payloadSize -= UInt64(ZipCrypto.headerLength)

                // 密钥流状态跨分块连续,分块解密与整段解密结果逐字节一致。
                var payloadRemaining = payloadSize
                let inFD = handle.fileDescriptor
                let result = try ZlibCodec.inflateStream(
                    compressedSize: payloadSize,
                    to: output,
                    progress: { counter.add($0) },
                    isCancelled: { [reporter] in reporter.isCancelled }
                ) { buffer in
                    // 外层按剩余压缩量给出缓冲,剩余量与缓冲大小同步递减,
                    // 因此这里总是恰好读满 buffer.count。
                    let want = buffer.count
                    try ChunkedIO.readFull(fd: inFD, into: buffer, want: want)
                    payloadRemaining -= UInt64(want)
                    mutableCrypto.decryptInPlace(
                        UnsafeMutableBufferPointer(
                            start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            count: want
                        )
                    )
                    return want
                }
                guard result.crc == entry.crc else { throw ZipError.corruptEntry(reason: "CRC 校验失败") }
            } else if let map = header.blockMap, map.segmentSizes.count > 1,
                      map.segmentSizes.reduce(0, +) == payloadSize,
                      map.matches(uncompressedSize: entry.uncompressedSize) {
                // 自研分块并行:各块独立解压 (本地头块图为准,段长合计须与负载吻合),
                // 加密条目不走此路径 (ZipCrypto 密钥流不可寻址,上方串行分支处理)。
                let crc = try inflateParallel(
                    entry,
                    header: header,
                    map: map,
                    output: output,
                    reporter: reporter,
                    counter: counter
                )
                guard crc == entry.crc else { throw ZipError.corruptEntry(reason: "CRC 校验失败") }
            } else {
                let result = try ZlibCodec.inflateFile(
                    input: handle,
                    compressedSize: payloadSize,
                    to: output,
                    progress: { counter.add($0) },
                    isCancelled: { [reporter] in reporter.isCancelled }
                )
                guard result.crc == entry.crc else { throw ZipError.corruptEntry(reason: "CRC 校验失败") }
            }
        }
    }

    /// WinWin AES 条目解压 (AE-1/AE-2):解密后按实际方法走 store / deflate 流式管线。
    /// 布局: [盐][2 字节口令校验值][密文][10 字节认证码],HMAC 仅覆盖密文。
    /// 完整性: AE-1 (version 1) 校验 CRC;两版本均校验认证码。
    private func inflateAESEntry(
        _ entry: ZipEntryInfo,
        aes: WinZipAESInfo,
        handle: FileHandle,
        header: LocalHeaderInfo,
        password: String?,
        output: FileHandle?,
        reporter: ArchiveProgressReporting,
        counter: ProgressAccumulator
    ) throws {
        guard let password, !password.isEmpty else { throw ZipError.wrongPassword }
        try handle.seek(toOffset: header.dataStartOffset)

        // 1. 读取盐 + 口令校验值,派生密钥并验证口令 (不匹配即 wrongPassword,
        //    供 PasswordResolver 逐个候选尝试)。
        let head = handle.readData(ofLength: aes.headerLength)
        guard head.count == aes.headerLength else { throw ZipError.truncatedEntry }
        let salt = Array(head[0..<aes.saltLength])
        let verifier = Array(head[aes.saltLength..<aes.headerLength])
        guard let keys = WinZipAES.deriveKeys(password: Array(password.utf8), salt: salt, keyLength: aes.keyLength),
              keys.verifier == verifier else {
            throw ZipError.wrongPassword
        }
        guard let cryptor = WinZipAES.CTRCryptor(key: keys.encrypt) else {
            throw ZipError.corruptEntry(reason: "AES 密码机初始化失败")
        }
        let hmac = WinZipAES.SHA1HMAC(key: keys.mac)

        let cipherLen = Int(entry.compressedSize) - aes.headerLength - WinZipAESInfo.authLength
        guard cipherLen >= 0 else {
            throw ZipError.corruptEntry(reason: "AES 负载长度异常")
        }

        // 2. 分块解密 (HMAC 先于解密更新,与 pyzipper / WinZip 一致)。
        //    CRC 仅 AE-1 且中央目录 CRC 非零时校验 (AE-2 按规范 CRC 恒 0)。
        var crc: UInt32 = 0
        let chunkSize = ChunkedIO.bufferSize
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let outFD = output?.fileDescriptor

        func decryptChunk(_ buf: UnsafeMutableBufferPointer<UInt8>, count: Int) {
            hmac.update(UnsafeRawBufferPointer(start: buf.baseAddress, count: count))
            _ = cryptor.cryptInPlace(buf, count: count)
        }

        if aes.method == ZipMethod.deflate {
            var remaining = cipherLen
            let result = try ZlibCodec.inflateStream(
                compressedSize: UInt64(cipherLen),
                to: output,
                progress: { counter.add($0) },
                isCancelled: { [reporter] in reporter.isCancelled }
            ) { buffer in
                let want = buffer.count
                try ChunkedIO.readFull(fd: handle.fileDescriptor, into: buffer, want: want)
                remaining -= want
                hmac.update(UnsafeRawBufferPointer(start: buffer.baseAddress, count: want))
                _ = cryptor.cryptInPlace(
                    UnsafeMutableBufferPointer(
                        start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        count: want
                    ),
                    count: want
                )
                return want
            }
            if aes.version == WinZipAES.versionAE1 && entry.crc != 0 {
                guard result.crc == entry.crc else { throw ZipError.corruptEntry(reason: "AES 条目 CRC 不符") }
            }
        } else {
            let inFD = handle.fileDescriptor
            var written: UInt64 = 0
            try buffer.withUnsafeMutableBufferPointer { buf in
                var remaining = UInt64(cipherLen)
                while remaining > 0 {
                    if reporter.isCancelled { throw ZipError.cancelled }
                    let want = Int(min(UInt64(chunkSize), remaining))
                    try ChunkedIO.readFull(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: chunkSize),
                        want: want
                    )
                    remaining -= UInt64(want)
                    decryptChunk(buf, count: want)
                    crc = CRC32.update(crc, UnsafeBufferPointer(start: buf.baseAddress, count: want))
                    if let outFD {
                        try ChunkedIO.write(
                            fd: outFD,
                            from: UnsafeRawBufferPointer(start: buf.baseAddress, count: want)
                        )
                    }
                    written += UInt64(want)
                    counter.add(written)
                }
            }
            if aes.version == WinZipAES.versionAE1 && entry.crc != 0 {
                guard crc == entry.crc else { throw ZipError.corruptEntry(reason: "AES 条目 CRC 不符") }
            }
        }

        // 3. 末尾 10 字节认证码 (HMAC 覆盖全部密文)。
        let readAuth = handle.readData(ofLength: WinZipAESInfo.authLength)
        guard readAuth.count == WinZipAESInfo.authLength else { throw ZipError.truncatedEntry }
        guard Array(readAuth) == hmac.authenticationCode() else {
            throw ZipError.corruptEntry(reason: "AES 认证码不符 (数据损坏或被篡改)")
        }
    }

    private func makeCrypto(password: String?) -> ZipCrypto.Context? {
        guard let password, !password.isEmpty else { return nil }
        return ZipCrypto.Context(password: Array(password.utf8))
    }

    // MARK: - 分块并行解压

    /// 分块并行解压编排:每块独立 raw inflate,输入 pread (共享 fd 不移动偏移),
    /// 输出 pwrite 到各自互不重叠的区间;输出文件先截断到全尺寸 (稀疏分配)。
    /// 输出为 nil 时仅校验 (测试压缩包路径)。
    /// 块级工作线程数受核数与块数约束;与条目级并行 (extractAll) 叠加时由全局队列调度。
    private func inflateParallel(
        _ entry: ZipEntryInfo,
        header: LocalHeaderInfo,
        map: ZipBlockMap,
        output: FileHandle?,
        reporter: ArchiveProgressReporting,
        counter: ProgressAccumulator
    ) throws -> UInt32 {
        let blockCount = map.segmentSizes.count
        let archive = try FileHandle(forReadingFrom: archiveURL)
        defer { try? archive.close() }
        let inFD = archive.fileDescriptor
        let outFD = output?.fileDescriptor
        if let out = output {
            try out.truncate(atOffset: entry.uncompressedSize)
        }

        // 各块压缩段在文件中的起始偏移。
        var inputOffsets: [UInt64] = []
        inputOffsets.reserveCapacity(blockCount)
        var segmentAcc = header.dataStartOffset
        for size in map.segmentSizes {
            inputOffsets.append(segmentAcc)
            segmentAcc += size
        }

        var crcs = [UInt32](repeating: 0, count: blockCount)
        var firstError: Error?
        let lock = NSLock()
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, blockCount))
        let semaphore = DispatchSemaphore(value: workers)
        let group = DispatchGroup()

        for i in 0..<blockCount {
            semaphore.wait()
            lock.lock()
            let hasError = firstError != nil
            lock.unlock()
            if reporter.isCancelled || hasError {
                semaphore.signal()
                break
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [reporter] in
                defer { group.leave(); semaphore.signal() }
                var pendingProgress: UInt64 = 0
                do {
                    let outputOffset = UInt64(i) * map.blockSize
                    let expectedOutput = min(map.blockSize, entry.uncompressedSize - outputOffset)
                    let result = try ZlibCodec.inflateBlock(
                        inputFD: inFD,
                        inputOffset: inputOffsets[i],
                        segmentLength: map.segmentSizes[i],
                        to: outFD,
                        outputOffset: outputOffset,
                        expectedOutput: expectedOutput,
                        isFinalSegment: i == blockCount - 1,
                        isCancelled: { [reporter] in reporter.isCancelled },
                        onOutputProduced: { bytes in
                            pendingProgress += bytes
                            if pendingProgress >= ProgressAccumulator.batchSize {
                                counter.addDelta(pendingProgress)
                                pendingProgress = 0
                            }
                        }
                    )
                    if pendingProgress > 0 {
                        counter.addDelta(pendingProgress)
                    }
                    lock.lock()
                    crcs[i] = result.crc
                    lock.unlock()
                } catch {
                    if pendingProgress > 0 {
                        counter.addDelta(pendingProgress)
                    }
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        group.wait()

        if reporter.isCancelled && firstError == nil { throw ZipError.cancelled }
        if let error = firstError { throw error }

        // 各块 CRC 按序合并还原整条 CRC。
        var crc: UInt32 = 0
        for i in 0..<blockCount {
            let outputOffset = UInt64(i) * map.blockSize
            let outputLength = min(map.blockSize, entry.uncompressedSize - outputOffset)
            crc = CRC32.combine(crc, crcs[i], outputLength)
        }
        return crc
    }
}

/// 累计值 → 增量换算器 (线程安全):接收累计字节数,向上回报增量。
final class ProgressAccumulator {
    static let batchSize: UInt64 = 4 * 1024 * 1024

    private let emit: (UInt64) -> Void
    private var lastValue: UInt64 = 0
    private var pending: UInt64 = 0
    private let lock = NSLock()

    init(emit: @escaping (UInt64) -> Void) {
        self.emit = emit
    }

    func add(_ cumulative: UInt64) {
        lock.lock()
        let delta = cumulative >= lastValue ? cumulative - lastValue : 0
        lastValue = max(lastValue, cumulative)
        pending += delta
        let shouldEmit = pending >= Self.batchSize
        let value = shouldEmit ? pending : 0
        if shouldEmit { pending = 0 }
        lock.unlock()
        if value > 0 { emit(value) }
    }

    func addDelta(_ delta: UInt64) {
        guard delta > 0 else { return }
        lock.lock()
        pending += delta
        let shouldEmit = pending >= Self.batchSize
        let value = shouldEmit ? pending : 0
        if shouldEmit { pending = 0 }
        lock.unlock()
        if value > 0 { emit(value) }
    }

    func flush() {
        lock.lock()
        let value = pending
        pending = 0
        lock.unlock()
        if value > 0 { emit(value) }
    }
}

/// 密码解析策略:显式密码 → 候选列表逐个试 → 交互提示 (最多 3 轮)。
/// 弹窗穷尽后置位 promptExhausted,同一批解压里后续条目不再重复打扰
/// (配合容错解压:该条目按 wrongPassword 跳过)。
final class PasswordResolver {
    private let explicit: String?
    private let candidates: [String]
    private let prompt: ((String, Int) -> String?)?
    private var cachedPassword: String?
    private var promptExhausted = false
    private let lock = NSLock()
    private let promptLock = NSLock()

    init(explicit: String?, candidates: [String], prompt: ((String, Int) -> String?)?) {
        self.explicit = explicit
        self.candidates = candidates
        self.prompt = prompt
    }

    /// 返回可用密码 (未加密时 nil);全部失败抛 wrongPassword / cancelled。
    func resolveIfNeeded(
        isEncrypted: Bool,
        verifier: (String) throws -> Bool
    ) throws -> String? {
        guard isEncrypted else { return nil }

        // 密码验证可能包含文件 I/O 或 AES PBKDF2。不要把这些耗时操作放在
        // 状态锁内,否则多文件加密归档会被全局串行化。
        lock.lock()
        let cached = cachedPassword
        lock.unlock()

        if let cached {
            if try verifier(cached) { return cached }
        }
        if let explicit, !explicit.isEmpty {
            if try verifier(explicit) {
                lock.lock()
                cachedPassword = explicit
                lock.unlock()
                return explicit
            }
        }
        for candidate in candidates where !candidate.isEmpty {
            if try verifier(candidate) {
                lock.lock()
                cachedPassword = candidate
                lock.unlock()
                return candidate
            }
        }

        guard let prompt else {
            throw ZipError.wrongPassword
        }

        // 同一归档只允许一个线程弹出密码提示。等待中的线程先重新检查
        // 已缓存密码,避免前一个线程成功后再次打扰用户。
        promptLock.lock()
        defer { promptLock.unlock() }

        lock.lock()
        let promptAlreadyExhausted = promptExhausted
        let cachedAfterWait = cachedPassword
        lock.unlock()
        if let cachedAfterWait, try verifier(cachedAfterWait) {
            return cachedAfterWait
        }
        guard !promptAlreadyExhausted else {
            throw ZipError.wrongPassword
        }

        defer {
            lock.lock()
            promptExhausted = true
            lock.unlock()
        }
        for round in 1...3 {
            guard let entered = prompt("该压缩包已加密", round), !entered.isEmpty else {
                throw CancellationError()
            }
            if try verifier(entered) {
                lock.lock()
                cachedPassword = entered
                lock.unlock()
                return entered
            }
        }
        throw ZipError.wrongPassword
    }
}
