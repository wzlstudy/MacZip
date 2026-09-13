import Foundation

/// MacZip 自研多线程 ZIP 写入器。
///
/// 两阶段流水线:
/// 1. 并行压缩阶段 — 每个输入文件独立 deflate 到临时分片文件 (crc + 大小同步得出),
///    线程池规模 = CPU 核心数,这是"多线程压缩引擎"的核心;
/// 2. 串行装配阶段 — 按顺序写 local header + 分片负载 + 中央目录,天然支持 ZIP64;
///    ZipCrypto 加密在此时对负载分块流式加密 (明文分片不读回内存)。
///
/// 加密 (ZipCrypto) 的 12 字节加密头 + 密文负载在装配阶段写入,内存占用与文件大小无关。
public final class ZipWriter {
    /// 写入选项,与设置页字段一一映射。
    public struct Options {
        public var level: ZlibCodec.Level
        public var password: String?
        /// 分卷大小 (字节);nil 表示不分卷。
        public var volumeSize: UInt64?
        /// 是否排除 .DS_Store / __MACOSX 等系统杂质。
        public var excludeSystemJunk: Bool
        public var comment: String?
        /// 分块并行压缩的块大小;nil = 默认 64 MiB。文件 ≥ 2×块大小时启用分块并行
        /// (单文件多线程 deflate);测试可用小值 (如 1 MiB) 触发。
        public var parallelBlockSize: UInt64?
        /// 加密方式:true = WinZip AES-256 (强,Windows 资源管理器不识别),
        /// false = ZipCrypto 传统加密 (弱,兼容性最好)。
        public var useAES: Bool
        /// 自定义排除规则 (glob,语义见 ExcludeMatcher);在系统杂质过滤之后叠加。
        public var excludePatterns: [String]

        public init(
            level: ZlibCodec.Level = .standard,
            password: String? = nil,
            volumeSize: UInt64? = nil,
            excludeSystemJunk: Bool = true,
            comment: String? = nil,
            parallelBlockSize: UInt64? = nil,
            useAES: Bool = false,
            excludePatterns: [String] = []
        ) {
            self.level = level
            self.password = password
            self.volumeSize = volumeSize
            self.excludeSystemJunk = excludeSystemJunk
            self.comment = comment
            self.parallelBlockSize = parallelBlockSize
            self.useAES = useAES
            self.excludePatterns = excludePatterns
        }
    }

    /// 默认分块大小:64 MiB。比值损失 (每块起点缺 32KB 窗口上下文) < 0.1%,
    /// 64 MiB 块足以让并行度在常见文件规模下饱和。
    static let defaultParallelBlockSize: UInt64 = 64 * 1024 * 1024
    /// 块数上限:块图写入 extra field (u16 容量),4096 块 × 4B ≈ 16KB。
    static let maxBlockCount = 4096

    /// 内部路径的根行为:如何映射相对路径。
    public enum RootBehavior {
        case auto          // 单文件 → 平铺;单目录/多选 → 保留最外层名
        case flatten       // 全部平铺到根
        case keepOuter     // 每个输入保留其最外层目录名
    }

    /// 分片产物:并行阶段完成后的每文件元数据。
    private struct FragmentPiece {
        var url: URL
        var size: UInt64
    }

    private struct Fragment {
        var entry: ZipPendingEntry
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        /// 压缩负载分片 (普通条目 1 片;分块条目为各块顺序拼接)。
        var pieces: [FragmentPiece]
        /// 分块并行布局;nil = 单流。
        var blockMap: ZipBlockMap?
        /// WinWin AES extra field (含实际压缩方法);nil = 非 AES。
        var aesExtra: Data?
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private let options: Options
    private let reporter: ArchiveProgressReporting
    private let fm = FileManager.default
    /// 保护 fragments 槽位写入与首错误聚合。
    private let resultLock = NSLock()

    public init(options: Options, reporter: ArchiveProgressReporting) {
        self.options = options
        self.reporter = reporter
    }

    // MARK: - 公开入口

    /// 把一组文件/目录压缩为 zip。
    /// 返回最终产物 URL (分卷时为第一个分卷,即 ".zip.001")。
    @discardableResult
    public func write(
        inputs: [URL],
        to outputURL: URL,
        rootBehavior: RootBehavior = .auto
    ) throws -> URL {
        // 1. 收集条目并确定内部路径。
        let pending = try collectEntries(inputs: inputs, rootBehavior: rootBehavior)
        let totalBytes = pending.reduce(UInt64(0)) { $0 + $1.fileSize }
        reporter.begin(totalBytes: totalBytes, title: "正在压缩 \(pending.count) 个项目")

        // 2. 并行压缩到分片目录。
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("MacZip-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let fragments = try compressInParallel(pending: pending, stagingDir: stagingDir)

        // 3. 串行装配 (把各文件分片按序写入最终压缩包)。此阶段还在读写磁盘,
        //    提示用户"正在写入",避免进度到 100% 后界面看起来卡住。
        reporter.willFinalize(message: "正在写入压缩包…")
        let assemblyURL = options.volumeSize == nil
            ? outputURL
            : stagingDir.appendingPathComponent("assembly.zip")
        try assemble(fragments: fragments, to: assemblyURL)

        // 4. 分卷切分。
        if let volumeSize = options.volumeSize, volumeSize > 0 {
            reporter.willFinalize(message: "正在切分分卷…")
            return try SplitVolumes.split(
                fileAt: assemblyURL,
                firstVolumeURL: outputURL,
                volumeSize: volumeSize
            )
        }
        return assemblyURL
    }

    // MARK: - 条目收集

    private func isSystemJunk(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base == ".DS_Store" || base == ".localized"
            || name.contains("__MACOSX/")
            || (base.hasPrefix("._") && base.count > 2)
    }

    private func collectEntries(
        inputs: [URL],
        rootBehavior: RootBehavior
    ) throws -> [ZipPendingEntry] {
        var standardized: [URL] = []
        for input in inputs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: input.standardizedFileURL.path, isDirectory: &isDir) else { continue }
            standardized.append(input.standardizedFileURL)
        }

        let singleInputIsDirectory: Bool = {
            guard standardized.count == 1 else { return false }
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: standardized[0].path, isDirectory: &isDir)
            return isDir.boolValue
        }()
        let useOuter: Bool
        switch rootBehavior {
        case .flatten: useOuter = false
        case .keepOuter: useOuter = true
        case .auto: useOuter = standardized.count > 1 || singleInputIsDirectory
        }

        // 匹配用前缀:外层目录名不参与排除规则匹配 (规则相对"内容根")。
        let rootPrefix = useOuter ? (standardized[0].lastPathComponent + "/") : ""
        var result: [ZipPendingEntry] = []
        for input in standardized {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: input.path, isDirectory: &isDir)
            if isDir.boolValue {
                let outerName = input.lastPathComponent
                if useOuter {
                    result.append(ZipPendingEntry(
                        kind: .directory, name: outerName + "/",
                        fileURL: input, fileSize: 0
                    ))
                }
                try collectDirectory(
                    at: input,
                    prefix: useOuter ? outerName + "/" : "",
                    rootPrefix: rootPrefix,
                    into: &result
                )
            } else {
                if options.excludeSystemJunk && isSystemJunk(input.lastPathComponent) { continue }
                if ExcludeMatcher.isExcluded(relativePath: input.lastPathComponent, patterns: options.excludePatterns) { continue }
                let size = UInt64((try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                result.append(ZipPendingEntry(
                    kind: .file, name: input.lastPathComponent,
                    fileURL: input, fileSize: size
                ))
            }
        }
        return result
    }

    private func collectDirectory(
        at dirURL: URL,
        prefix: String,
        rootPrefix: String,
        into result: inout [ZipPendingEntry]
    ) throws {
        let children = try fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if options.excludeSystemJunk && isSystemJunk(child.lastPathComponent) { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let relative = prefix + child.lastPathComponent
            // 自定义排除:目录命中即整棵剪枝,文件命中即跳过。
            // 匹配路径剥掉外层目录前缀 (规则相对内容根,而非压缩包外壳名)。
            let matchPath = relative.hasPrefix(rootPrefix)
                ? String(relative.dropFirst(rootPrefix.count))
                : relative
            if ExcludeMatcher.isExcluded(relativePath: matchPath, patterns: options.excludePatterns) { continue }
            if values.isDirectory ?? false {
                result.append(ZipPendingEntry(kind: .directory, name: relative + "/", fileURL: child, fileSize: 0))
                try collectDirectory(at: child, prefix: relative + "/", rootPrefix: rootPrefix, into: &result)
            } else {
                result.append(ZipPendingEntry(
                    kind: .file,
                    name: relative,
                    fileURL: child,
                    fileSize: UInt64(values.fileSize ?? 0)
                ))
            }
        }
    }

    // MARK: - 并行压缩阶段

    private func compressInParallel(
        pending: [ZipPendingEntry],
        stagingDir: URL
    ) throws -> [Fragment] {
        var slots = [Fragment?](repeating: nil, count: pending.count)
        var firstError: Error?

        let fileIndices = pending.indices.filter { pending[$0].kind == .file }

        // concurrentPerform 在线程池上分片执行;每个文件独立压缩,互不共享 zlib 状态。
        DispatchQueue.concurrentPerform(iterations: fileIndices.count) { poolIndex in
            if reporter.isCancelled { return }
            let index = fileIndices[poolIndex]
            do {
                let fragment = try compressOne(pending[index], stagingDir: stagingDir)
                resultLock.lock()
                slots[index] = fragment
                resultLock.unlock()
            } catch {
                resultLock.lock()
                if firstError == nil { firstError = error }
                resultLock.unlock()
            }
        }

        if reporter.isCancelled { throw ZipError.cancelled }
        if let error = firstError { throw error }

        // 目录条目占位 (无分片)。
        for index in pending.indices where pending[index].kind == .directory {
            slots[index] = Fragment(
                entry: pending[index],
                method: ZipMethod.store,
                crc: 0,
                compressedSize: 0,
                uncompressedSize: 0,
                pieces: [],
                blockMap: nil,
                aesExtra: nil,
                dosTime: 0,
                dosDate: 0
            )
        }
        return slots.compactMap { $0 }
    }

    private func compressOne(_ entry: ZipPendingEntry, stagingDir: URL) throws -> Fragment {
        let fileURL = entry.fileURL!
        let attrs = try fm.attributesOfItem(atPath: fileURL.path)
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let (dosTime, dosDate) = DOSTime.from(date: modified)

        reporter.willProcessFile(entry.name)

        var crc: UInt32 = 0
        var csize: UInt64 = 0
        var usize: UInt64 = 0
        var method: UInt16 = ZipMethod.store
        var pieces: [FragmentPiece] = []
        var blockMap: ZipBlockMap?
        var aesExtra: Data?

        // 大文件分块并行判定:≥ 2 块且块尺寸可用 u32 表达 (块图容量限制)。
        let blockThreshold = max(64 * 1024, options.parallelBlockSize ?? ZipWriter.defaultParallelBlockSize)
        var useParallelBlocks = false
        var parallelBlockSize: UInt64 = 0
        var parallelBlockCount = 0
        if options.level != .store && entry.fileSize > blockThreshold {
            let rawCount = Int((entry.fileSize + blockThreshold - 1) / blockThreshold)
            let clampedCount = min(rawCount, ZipWriter.maxBlockCount)
            let size = (entry.fileSize + UInt64(clampedCount) - 1) / UInt64(clampedCount)
            if size <= UInt64(UInt32.max) {
                useParallelBlocks = true
                parallelBlockSize = size
                parallelBlockCount = clampedCount
            }
        }

        if useParallelBlocks {
            // 分块并行 deflate:各块独立压缩,块间 SYNC_FLUSH 衔接 (拼接后仍是
            // 合法 raw deflate 流,外部工具照常可解)。跳过"压缩后反而更大回退
            // store"——zlib 对不可压数据内部自产 stored 块 (膨胀 ~0.008%),
            // 省去对超大文件的第二遍全量读。
            let result = try deflateParallel(
                inputURL: fileURL,
                fileSize: entry.fileSize,
                stagingDir: stagingDir,
                blockSize: parallelBlockSize,
                blockCount: parallelBlockCount
            )
            crc = result.crc
            usize = entry.fileSize
            csize = result.pieces.reduce(0) { $0 + $1.size }
            method = ZipMethod.deflate
            pieces = result.pieces
            blockMap = ZipBlockMap(blockSize: parallelBlockSize, segmentSizes: result.pieces.map { $0.size })
        } else {
            // 单流路径。
            let fragmentURL = stagingDir
                .appendingPathComponent("frag-\(UUID().uuidString)", isDirectory: false)
            fm.createFile(atPath: fragmentURL.path, contents: nil)
            // forWritingTo (O_WRONLY):分片只写;deflate 结果反而更大时 truncate 后重跑 store 直通。
            let fragmentHandle = try FileHandle(forWritingTo: fragmentURL)
            defer { try? fragmentHandle.close() }

            if entry.fileSize == 0 {
                method = ZipMethod.store
            } else if options.level == .store {
                method = ZipMethod.store
                let result = try ZlibCodec.passthrough(
                    input: fileURL,
                    to: fragmentHandle,
                    progress: { [reporter] bytes in reporter.advance(by: bytes) },
                    isCancelled: { [reporter] in reporter.isCancelled }
                )
                crc = result.crc
                csize = result.compressedSize
                usize = result.uncompressedSize
            } else {
                let result = try ZlibCodec.deflateFile(
                    input: fileURL,
                    to: fragmentHandle,
                    level: options.level,
                    progress: { [reporter] bytes in reporter.advance(by: bytes) },
                    isCancelled: { [reporter] in reporter.isCancelled }
                )
                // deflate 结果反而更大时回退 store,保持小文件体积最优。
                if result.compressedSize >= result.uncompressedSize {
                    try fragmentHandle.truncate(atOffset: 0)
                    try fragmentHandle.seek(toOffset: 0)
                    let passthrough = try ZlibCodec.passthrough(
                        input: fileURL,
                        to: fragmentHandle,
                        progress: nil,
                        isCancelled: { [reporter] in reporter.isCancelled }
                    )
                    crc = passthrough.crc
                    csize = passthrough.compressedSize
                    usize = passthrough.uncompressedSize
                    method = ZipMethod.store
                } else {
                    crc = result.crc
                    csize = result.compressedSize
                    usize = result.uncompressedSize
                    method = ZipMethod.deflate
                }
            }
            pieces = [FragmentPiece(url: fragmentURL, size: csize)]
        }

        // 加密条目的头部收尾:
        // - ZipCrypto:12 字节加密头计入 csize,方法不变;
        // - AES:盐 16 + 校验 2 + 认证码 10 计入 csize,头部方法改写为 99,
        //   实际方法 (0/8) 记入 AES extra field。加密本体在装配阶段流式进行。
        if let password = options.password, !password.isEmpty {
            if options.useAES {
                csize += UInt64(WinZipAES.saltLength(for: 3) + 2 + WinZipAESInfo.authLength)
                aesExtra = WinZipAES.extraFieldData(strength: 3, version: WinZipAES.versionAE1, method: method)
                method = 99
            } else {
                csize += UInt64(ZipCrypto.headerLength)
            }
        }

        return Fragment(
            entry: entry,
            method: method,
            crc: crc,
            compressedSize: csize,
            uncompressedSize: usize,
            pieces: pieces,
            blockMap: blockMap,
            aesExtra: aesExtra,
            dosTime: dosTime,
            dosDate: dosDate
        )
    }

    /// 分块并行 deflate 编排:各块独立压缩到分片文件 (输入 pread 共享 fd),
    /// CRC 按块序合并还原整条 CRC。工作线程数受核数与块数约束。
    private func deflateParallel(
        inputURL: URL,
        fileSize: UInt64,
        stagingDir: URL,
        blockSize: UInt64,
        blockCount: Int
    ) throws -> (crc: UInt32, pieces: [FragmentPiece]) {
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let inFD = input.fileDescriptor

        var pieceURLs: [URL] = []
        var handles: [FileHandle] = []
        pieceURLs.reserveCapacity(blockCount)
        handles.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            let url = stagingDir.appendingPathComponent("frag-\(UUID().uuidString)", isDirectory: false)
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            pieceURLs.append(url)
            handles.append(handle)
        }
        defer { for handle in handles { try? handle.close() } }

        var crcs = [UInt32](repeating: 0, count: blockCount)
        var sizes = [UInt64](repeating: 0, count: blockCount)
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
                do {
                    let inputOffset = UInt64(i) * blockSize
                    let inputLength = min(blockSize, fileSize - inputOffset)
                    let result = try ZlibCodec.deflateBlock(
                        inputFD: inFD,
                        inputOffset: inputOffset,
                        inputLength: inputLength,
                        to: handles[i].fileDescriptor,
                        level: self.options.level,
                        isFinal: i == blockCount - 1,
                        isCancelled: { [reporter] in reporter.isCancelled },
                        onInputRead: { [reporter] bytes in reporter.advance(by: bytes) }
                    )
                    lock.lock()
                    crcs[i] = result.crc
                    sizes[i] = result.compressedSize
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        group.wait()

        if reporter.isCancelled { throw ZipError.cancelled }
        if let error = firstError { throw error }

        // CRC 按块序合并 (crc32_combine 的 len2 为后段明文字节数)。
        var crc: UInt32 = 0
        for i in 0..<blockCount {
            let inputOffset = UInt64(i) * blockSize
            let inputLength = min(blockSize, fileSize - inputOffset)
            crc = CRC32.combine(crc, crcs[i], inputLength)
        }
        let pieces = (0..<blockCount).map { FragmentPiece(url: pieceURLs[$0], size: sizes[$0]) }
        return (crc, pieces)
    }

    // MARK: - 串行装配阶段

    private func assemble(fragments: [Fragment], to outputURL: URL) throws {
        if !fm.fileExists(atPath: outputURL.path) {
            fm.createFile(atPath: outputURL.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: outputURL)
        defer { try? out.close() }
        try out.truncate(atOffset: 0)

        var centralRecords: [Data] = []
        var currentOffset: UInt64 = 0
        var anyEntryNeedsZip64 = false

        for fragment in fragments {
            let sizeNeedsZip64 =
                fragment.compressedSize >= 0xFFFFFFFF || fragment.uncompressedSize >= 0xFFFFFFFF
            let entryNeedsZip64 = sizeNeedsZip64
            if entryNeedsZip64 { anyEntryNeedsZip64 = true }

            var flags: UInt16 = 0x0800 // UTF-8 文件名
            // 目录条目无负载,不标加密位 (unzip 会因 csize-12 下溢报警)。
            if options.password != nil && fragment.entry.kind == .file { flags |= 0x0001 }

            let nameBytes = Data(fragment.entry.name.utf8)

            var localExtra = Data()
            if entryNeedsZip64 {
                localExtra.appendLE(UInt16(0x0001))       // ZIP64 extra id
                localExtra.appendLE(UInt16(16))
                localExtra.appendLE(fragment.uncompressedSize)
                localExtra.appendLE(fragment.compressedSize)
            }
            if let map = fragment.blockMap {
                localExtra.append(map.extraFieldData())
            }
            if let aesExtra = fragment.aesExtra {
                localExtra.append(aesExtra)
            }

            var localHeader = Data()
            localHeader.appendLE(UInt32(0x04034b50))       // local file header sig
            localHeader.appendLE(entryNeedsZip64 ? ZipVersion.zip64 : ZipVersion.madeBy)
            localHeader.appendLE(flags)
            localHeader.appendLE(fragment.method)
            localHeader.appendLE(fragment.dosTime)
            localHeader.appendLE(fragment.dosDate)
            localHeader.appendLE(fragment.crc)
            localHeader.appendLE(entryNeedsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: fragment.compressedSize))
            localHeader.appendLE(entryNeedsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: fragment.uncompressedSize))
            localHeader.appendLE(UInt16(nameBytes.count))
            localHeader.appendLE(UInt16(localExtra.count)) // extra 长度
            // 本地头变长区顺序固定:先文件名,后 extra (中央目录同序)。
            localHeader.append(nameBytes)
            localHeader.append(localExtra)

            try out.write(contentsOf: localHeader)
            if !fragment.pieces.isEmpty {
                let outFD = out.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: ChunkedIO.bufferSize)
                let encrypting = options.password != nil && !options.password!.isEmpty
                if encrypting && options.useAES && fragment.aesExtra != nil {
                    // WinZip AES:先写盐 + 口令校验值,流式 CTR 加密负载
                    // (HMAC 覆盖密文),末尾写 10 字节认证码。
                    // 明文分片按块读入,内存占用 O(分块)。
                    guard let password = options.password else { throw ZipError.corruptEntry(reason: "缺少加密口令") }
                    var salt = [UInt8](repeating: 0, count: WinZipAES.saltLength(for: 3))
                    for i in 0..<salt.count { salt[i] = UInt8.random(in: 0...255) }
                    guard let keys = WinZipAES.deriveKeys(
                        password: Array(password.utf8), salt: salt, keyLength: WinZipAES.keyLength(for: 3)
                    ) else {
                        throw ZipError.corruptEntry(reason: "AES 密钥派生失败")
                    }
                    var header = Data(salt)
                    header.append(contentsOf: keys.verifier)
                    try out.write(contentsOf: header)
                    guard let cryptor = WinZipAES.CTRCryptor(key: keys.encrypt) else {
                        throw ZipError.corruptEntry(reason: "AES 密码机初始化失败")
                    }
                    let hmac = WinZipAES.SHA1HMAC(key: keys.mac)
                    for piece in fragment.pieces {
                        let handle = try FileHandle(forReadingFrom: piece.url)
                        defer { try? handle.close() }
                        try buffer.withUnsafeMutableBufferPointer { buf in
                            var remaining = piece.size
                            while remaining > 0 {
                                if reporter.isCancelled { throw ZipError.cancelled }
                                let want = Int(min(UInt64(buf.count), remaining))
                                try ChunkedIO.readFull(
                                    fd: handle.fileDescriptor,
                                    into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                                    want: want
                                )
                                remaining -= UInt64(want)
                                _ = cryptor.cryptInPlace(buf, count: want)
                                hmac.update(UnsafeRawBufferPointer(start: buf.baseAddress, count: want))
                                try ChunkedIO.write(
                                    fd: outFD,
                                    from: UnsafeRawBufferPointer(start: buf.baseAddress, count: want)
                                )
                            }
                        }
                    }
                    try out.write(contentsOf: hmac.authenticationCode())
                } else if encrypting {
                    // ZipCrypto:先写加密后的 12 字节头,再分块流式加密负载
                    // (各分片顺序拼接,密钥流状态跨分片连续,与整段加密结果逐字节一致)。
                    guard let password = options.password else { throw ZipError.corruptEntry(reason: "缺少加密口令") }
                    var crypto = ZipCrypto.Context(password: Array(password.utf8))
                    var header = Data(ZipCrypto.makeHeader(checkByte: ZipCrypto.checkByte(crc: fragment.crc)))
                    header.withUnsafeMutableBytes { raw in
                        let buf = raw.bindMemory(to: UInt8.self)
                        crypto.encryptInPlace(buf)
                    }
                    try out.write(contentsOf: header)
                    for piece in fragment.pieces {
                        let handle = try FileHandle(forReadingFrom: piece.url)
                        defer { try? handle.close() }
                        try buffer.withUnsafeMutableBufferPointer { buf in
                            var remaining = piece.size
                            while remaining > 0 {
                                if reporter.isCancelled { throw ZipError.cancelled }
                                let want = Int(min(UInt64(buf.count), remaining))
                                try ChunkedIO.readFull(
                                    fd: handle.fileDescriptor,
                                    into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: buf.count),
                                    want: want
                                )
                                crypto.encryptInPlace(UnsafeMutableBufferPointer(start: buf.baseAddress, count: want))
                                try ChunkedIO.write(
                                    fd: outFD,
                                    from: UnsafeRawBufferPointer(start: buf.baseAddress, count: want)
                                )
                                remaining -= UInt64(want)
                            }
                        }
                    }
                } else {
                    // 明文:逐分片流式拷贝负载。
                    for piece in fragment.pieces {
                        let handle = try FileHandle(forReadingFrom: piece.url)
                        defer { try? handle.close() }
                        try buffer.withUnsafeMutableBufferPointer { buf in
                            var remaining = piece.size
                            while remaining > 0 {
                                if reporter.isCancelled { throw ZipError.cancelled }
                                let want = Int(min(UInt64(buf.count), remaining))
                                try ChunkedIO.readFull(
                                    fd: handle.fileDescriptor,
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
                    }
                }
            }

            // 中央目录记录。偏移超界时该 entry 也需要 ZIP64 extra。
            let offsetNeedsZip64 = currentOffset >= 0xFFFFFFFF
            let centralNeedsZip64 = entryNeedsZip64 || offsetNeedsZip64
            if centralNeedsZip64 { anyEntryNeedsZip64 = true }

            var centralExtra = Data()
            if centralNeedsZip64 {
                centralExtra.appendLE(UInt16(0x0001))
                centralExtra.appendLE(UInt16(24))
                centralExtra.appendLE(fragment.uncompressedSize)  // 固定 24 字节布局,读取端按需取
                centralExtra.appendLE(fragment.compressedSize)
                centralExtra.appendLE(currentOffset)
            }
            if let map = fragment.blockMap {
                centralExtra.append(map.extraFieldData())
            }
            if let aesExtra = fragment.aesExtra {
                centralExtra.append(aesExtra)
            }

            var central = Data()
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(ZipVersion.madeBy)
            central.appendLE(centralNeedsZip64 ? ZipVersion.zip64 : ZipVersion.madeBy)
            central.appendLE(flags)
            central.appendLE(fragment.method)
            central.appendLE(fragment.dosTime)
            central.appendLE(fragment.dosDate)
            central.appendLE(fragment.crc)
            central.appendLE(centralNeedsZip64 && entryNeedsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: fragment.compressedSize))
            central.appendLE(centralNeedsZip64 && entryNeedsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: fragment.uncompressedSize))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(centralExtra.count))
            central.appendLE(UInt16(0))                      // comment len
            central.appendLE(UInt16(0))                      // disk number
            central.appendLE(UInt16(0))                      // internal attrs
            central.appendLE(UInt32(fragment.entry.kind == .directory ? 0x10 : 0)) // external attrs
            central.appendLE(centralNeedsZip64 ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: currentOffset))
            central.append(nameBytes)
            central.append(centralExtra)
            centralRecords.append(central)

            currentOffset += UInt64(localHeader.count) + fragment.compressedSize
        }

        let cdOffset = currentOffset
        var cdSize: UInt64 = 0
        for record in centralRecords {
            try out.write(contentsOf: record)
            cdSize += UInt64(record.count)
        }

        let entryCount = UInt64(centralRecords.count)
        let needsZip64EOCD =
            anyEntryNeedsZip64 || entryCount >= 0xFFFF || cdSize >= 0xFFFFFFFF || cdOffset >= 0xFFFFFFFF

        if needsZip64EOCD {
            var z64 = Data()
            z64.appendLE(UInt32(0x06064b50))
            z64.appendLE(UInt64(44))
            z64.appendLE(ZipVersion.zip64)
            z64.appendLE(ZipVersion.zip64)
            z64.appendLE(UInt32(0))                          // disk
            z64.appendLE(UInt32(0))                          // cd disk
            z64.appendLE(entryCount)
            z64.appendLE(entryCount)
            z64.appendLE(cdSize)
            z64.appendLE(cdOffset)
            try out.write(contentsOf: z64)

            var locator = Data()
            locator.appendLE(UInt32(0x07064b50))
            locator.appendLE(UInt32(0))                      // eocd disk
            locator.appendLE(cdOffset + cdSize)              // z64 eocd offset
            locator.appendLE(UInt32(1))
            try out.write(contentsOf: locator)
        }

        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(needsZip64EOCD ? UInt16(0xFFFF) : UInt16(truncatingIfNeeded: entryCount))
        eocd.appendLE(needsZip64EOCD ? UInt16(0xFFFF) : UInt16(truncatingIfNeeded: entryCount))
        eocd.appendLE(needsZip64EOCD ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: cdSize))
        eocd.appendLE(needsZip64EOCD ? UInt32(0xFFFFFFFF) : UInt32(truncatingIfNeeded: cdOffset))
        let commentBytes = Data((options.comment ?? "").utf8)
        eocd.appendLE(UInt16(commentBytes.count))
        eocd.append(commentBytes)
        try out.write(contentsOf: eocd)
    }
}

// MARK: - Data 小端写入辅助

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(value & 0xFFFFFFFF))
        appendLE(UInt32((value >> 32) & 0xFFFFFFFF))
    }
}

// MARK: - Data 读取辅助 (读取器共用)

extension Data {
    func readLE16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readLE64(at offset: Int) -> UInt64 {
        UInt64(readLE32(at: offset)) | (UInt64(readLE32(at: offset + 4)) << 32)
    }
}
