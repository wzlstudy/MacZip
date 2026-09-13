import Foundation
import zlib

/// zlib 流式封装 (Apple 系统自带 libz)。
/// - raw deflate (windowBits = -15):ZIP method 8 的负载格式;
/// - gzip 模式 (windowBits = 15 + 16):单文件 .gz;
/// - 压缩等级真实映射 zlib level 0/1/6/9,支撑 FastZip 同款"仅存储/快速/标准/极限"四档。
public enum ZlibCodec {
    public enum CodecError: Error, LocalizedError {
        case initFailed(code: Int32)
        case streamFailed(code: Int32, message: String)

        public var errorDescription: String? {
            switch self {
            case .initFailed(let code): return "zlib 初始化失败 (z_err=\(code))"
            case .streamFailed(let code, let message): return "zlib 流处理失败 (z_err=\(code)): \(message)"
            }
        }
    }

    /// 压缩等级档位,与 FastZip 设置页的"压缩等级"一一对应。
    public enum Level: String, Codable, CaseIterable, Identifiable {
        case store      // 仅存储
        case fast       // 快速
        case standard   // 标准
        case best       // 极限

        public var id: String { rawValue }

        public var localizedName: String {
            switch self {
            case .store: return "仅存储 (最快)"
            case .fast: return "快速"
            case .standard: return "标准"
            case .best: return "极限压缩比"
            }
        }

        /// zlib deflate level。store 档在 ZIP 层直接落 method 0,不走 zlib。
        public var zlibLevel: Int32 {
            switch self {
            case .store: return 0
            case .fast: return 1
            case .standard: return 6
            case .best: return 9
            }
        }
    }

    private static let chunkSize = 1 << 20 // 1 MiB

    /// raw deflate 压缩一个文件:边读边压,输出写入 outHandle,同步返回 (crc, 压缩后大小)。
    /// 返回 usize == 输入总字节数,csize == 输出总字节数。
    public static func deflateFile(
        input inputURL: URL,
        to output: FileHandle,
        level: Level,
        progress: ((UInt64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> (crc: UInt32, compressedSize: UInt64, uncompressedSize: UInt64) {
        guard level != .store else {
            // store 档:字节直通,与 deflate 语义一致 (method 0)。
            return try passthrough(input: inputURL, to: output, progress: progress, isCancelled: isCancelled)
        }
        var stream = z_stream()
        // windowBits = -15:ZIP method 8 要求 raw deflate (无 zlib 头/Adler32 尾)。
        let initResult = deflateInit2_(
            &stream, level.zlibLevel, Z_DEFLATED, -15, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { deflateEnd(&stream) }

        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let inFD = input.fileDescriptor
        let outFD = output.fileDescriptor

        var crc: UInt32 = 0
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var reachedEnd = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while !reachedEnd {
                    if isCancelled?() == true { throw CancellationError() }
                    let n = try ChunkedIO.read(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: chunkSize),
                        want: chunkSize
                    )
                    if n == 0 {
                        reachedEnd = true
                        stream.next_in = nil
                        stream.avail_in = 0
                    } else {
                        crc = CRC32.update(crc, UnsafeBufferPointer(start: inBuf.baseAddress, count: n))
                        totalIn += UInt64(n)
                        stream.next_in = inBuf.baseAddress
                        stream.avail_in = UInt32(n)
                    }

                    let flush: Int32 = reachedEnd ? Z_FINISH : Z_NO_FLUSH
                    repeat {
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = UInt32(chunkSize)
                        let result = deflate(&stream, flush)
                        guard result >= Z_OK else {
                            throw CodecError.streamFailed(code: result, message: stream.msg != nil ? String(cString: stream.msg!) : "unknown")
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0 {
                            try ChunkedIO.write(
                                fd: outFD,
                                from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: produced)
                            )
                            totalOut += UInt64(produced)
                        }
                        if !reachedEnd { progress?(totalIn) }
                    } while stream.avail_out == 0
                }
            }
        }
        return (crc, totalOut, totalIn)
    }

    /// store 直通 (ZIP method 0)。
    static func passthrough(
        input inputURL: URL,
        to output: FileHandle,
        progress: ((UInt64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> (crc: UInt32, compressedSize: UInt64, uncompressedSize: UInt64) {
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let inFD = input.fileDescriptor
        let outFD = output.fileDescriptor

        var crc: UInt32 = 0
        var total: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        try buffer.withUnsafeMutableBufferPointer { buf in
            while true {
                if isCancelled?() == true { throw CancellationError() }
                let n = try ChunkedIO.read(
                    fd: inFD,
                    into: UnsafeMutableRawBufferPointer(start: buf.baseAddress, count: chunkSize),
                    want: chunkSize
                )
                if n == 0 { break }
                crc = CRC32.update(crc, UnsafeBufferPointer(start: buf.baseAddress, count: n))
                try ChunkedIO.write(
                    fd: outFD,
                    from: UnsafeRawBufferPointer(start: buf.baseAddress, count: n)
                )
                total += UInt64(n)
                progress?(total)
            }
        }
        return (crc, total, total)
    }

    /// gzip 模式压缩整个文件 (输出含 gzip 头尾,用于单文件 .gz)。
    public static func gzipCompressFile(input: URL, output: URL, level: Level) throws {        guard level != .store else {
            // gzip 没有 store 档,退化为 level 1。
            return try gzipCompressFile(input: input, output: output, level: .fast)
        }
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream, level.zlibLevel, Z_DEFLATED, 15 + 16, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { deflateEnd(&stream) }

        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        let inFD = source.fileDescriptor
        let outFD = out.fileDescriptor

        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var reachedEnd = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while !reachedEnd {
                    let n = try ChunkedIO.read(
                        fd: inFD,
                        into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: chunkSize),
                        want: chunkSize
                    )
                    if n == 0 {
                        reachedEnd = true
                        stream.next_in = nil
                        stream.avail_in = 0
                    } else {
                        stream.next_in = inBuf.baseAddress
                        stream.avail_in = UInt32(n)
                    }

                    let flush: Int32 = reachedEnd ? Z_FINISH : Z_NO_FLUSH
                    repeat {
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = UInt32(chunkSize)
                        let result = deflate(&stream, flush)
                        guard result >= Z_OK else {
                            throw CodecError.streamFailed(code: result, message: stream.msg != nil ? String(cString: stream.msg!) : "unknown")
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0 {
                            try ChunkedIO.write(
                                fd: outFD,
                                from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: produced)
                            )
                        }
                    } while stream.avail_out == 0
                }
            }
        }
    }

    /// gzip 解压整个文件 (windowBits = 15 + 32:自动识别 gzip / zlib 头),
    /// 输出写入 output。用于 tar.gz 的透明读取。
    public static func gunzipFile(
        input inputURL: URL,
        to output: FileHandle,
        progress: ((UInt64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> UInt64 {
        let source = try FileHandle(forReadingFrom: inputURL)
        defer { try? source.close() }
        let inFD = source.fileDescriptor
        let outFD = output.fileDescriptor

        var stream = z_stream()
        // 15 + 32:zlib 自动检测 gzip 与 zlib 包装头。
        let initResult = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { inflateEnd(&stream) }

        var totalOut: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var streamEnded = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while !streamEnded {
                    if isCancelled?() == true { throw CancellationError() }
                    if stream.avail_in == 0 {
                        let n = try ChunkedIO.read(
                            fd: inFD,
                            into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: chunkSize),
                            want: chunkSize
                        )
                        if n == 0 {
                            stream.next_in = nil
                            stream.avail_in = 0
                        } else {
                            stream.next_in = inBuf.baseAddress
                            stream.avail_in = UInt32(n)
                        }
                    }

                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    if result == Z_STREAM_END { streamEnded = true }
                    guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                        throw ZipError.corruptEntry(reason: "gunzip z_err=\(result)")
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        try ChunkedIO.write(
                            fd: outFD,
                            from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: produced)
                        )
                        totalOut += UInt64(produced)
                        progress?(totalOut)
                    }
                    if result == Z_BUF_ERROR && stream.avail_in == 0 && produced == 0 {
                        // 输入耗尽且无输出推进:流异常结束,避免死循环。
                        if try ChunkedIO.read(
                            fd: inFD,
                            into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: 1),
                            want: 1
                        ) == 0 { streamEnded = true }
                    }
                }
            }
        }
        return totalOut
    }

    /// raw inflate 解压:从 inputHandle 当前位置读取 compressedSize 字节,
    /// 输出写入 output (nil 时仅校验,用于"测试压缩包"),返回 (crc, 解压后大小)。
    public static func inflateFile(
        input inputHandle: FileHandle,
        compressedSize: UInt64,
        to output: FileHandle?,
        progress: ((UInt64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> (crc: UInt32, outputSize: UInt64) {
        let fd = inputHandle.fileDescriptor
        return try inflateStream(
            compressedSize: compressedSize,
            to: output,
            progress: progress,
            isCancelled: isCancelled
        ) { buffer in
            try ChunkedIO.read(fd: fd, into: buffer, want: buffer.count)
        }
    }

    /// 流式 raw inflate 核心:readChunk 向给定缓冲填充至多 buffer.count 字节并返回
    /// 实际字节数 (返回 0 表示输入耗尽,流未结束即抛 truncatedEntry)。数据来源由
    /// 调用方决定——FileHandle 直读,或 ZipCrypto 边解密边供给 (超大加密条目不再
    /// 整段落临时盘/进内存,内存占用恒定为分块大小)。
    public static func inflateStream(
        compressedSize: UInt64,
        to output: FileHandle?,
        progress: ((UInt64) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil,
        readChunk: (_ buffer: UnsafeMutableRawBufferPointer) throws -> Int
    ) throws -> (crc: UInt32, outputSize: UInt64) {
        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { inflateEnd(&stream) }

        var crc: UInt32 = 0
        var totalOut: UInt64 = 0
        var consumed: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var streamEnded = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while !streamEnded {
                    if isCancelled?() == true { throw CancellationError() }
                    let want = Int(min(UInt64(chunkSize), compressedSize - consumed))
                    if want > 0 {
                        let supplied = try readChunk(
                            UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: want)
                        )
                        guard supplied > 0 else { throw ZipError.truncatedEntry }
                        consumed += UInt64(supplied)
                        stream.next_in = inBuf.baseAddress
                        stream.avail_in = UInt32(supplied)
                    } else {
                        stream.next_in = nil
                        stream.avail_in = 0
                    }

                    repeat {
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = UInt32(chunkSize)
                        let result = inflate(&stream, Z_NO_FLUSH)
                        if result == Z_STREAM_END { streamEnded = true }
                        guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                            throw ZipError.corruptEntry(reason: "inflate z_err=\(result)")
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0 {
                            let chunk = UnsafeBufferPointer(start: outBuf.baseAddress, count: produced)
                            crc = CRC32.update(crc, chunk)
                            if let output {
                                try ChunkedIO.write(
                                    fd: output.fileDescriptor,
                                    from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: produced)
                                )
                            }
                            totalOut += UInt64(produced)
                        }
                        progress?(totalOut)
                        if result == Z_BUF_ERROR && stream.avail_in == 0 && produced == 0 {
                            // 输入耗尽且无输出推进:流提前结束。
                            streamEnded = true
                        }
                    } while stream.avail_out == 0
                }
            }
        }
        return (crc, totalOut)
    }

    // MARK: - 分块并行基元

    /// 并行 deflate 单块:压缩 inFD 的 [inputOffset, inputOffset+inputLength) 区间,
    /// 输出顺序写入 pieceFD。`isFinal` 为 true 时以 Z_FINISH 收尾 (整条流最后一块),
    /// 否则 Z_SYNC_FLUSH (块间衔接,拼接后仍是合法 raw deflate 流)。
    /// 返回 (本块 crc, 压缩字节数);onInputRead 回调增量回报已读明文字节数。
    static func deflateBlock(
        inputFD: Int32,
        inputOffset: UInt64,
        inputLength: UInt64,
        to pieceFD: Int32,
        level: Level,
        isFinal: Bool,
        isCancelled: (() -> Bool)? = nil,
        onInputRead: ((UInt64) -> Void)? = nil
    ) throws -> (crc: UInt32, compressedSize: UInt64) {
        guard inputLength > 0 else { throw ZipError.corruptEntry(reason: "空分块") }
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream, level.zlibLevel, Z_DEFLATED, -15, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { deflateEnd(&stream) }

        var crc: UInt32 = 0
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var inputDone = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while !inputDone {
                    if isCancelled?() == true { throw CancellationError() }
                    let want = Int(min(UInt64(chunkSize), inputLength - totalIn))
                    try ChunkedIO.readFullAt(
                        fd: inputFD,
                        into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: chunkSize),
                        want: want,
                        atOffset: inputOffset + totalIn
                    )
                    crc = CRC32.update(crc, UnsafeBufferPointer(start: inBuf.baseAddress, count: want))
                    totalIn += UInt64(want)
                    stream.next_in = inBuf.baseAddress
                    stream.avail_in = UInt32(want)
                    let flush: Int32
                    if totalIn == inputLength {
                        inputDone = true
                        flush = isFinal ? Z_FINISH : Z_SYNC_FLUSH
                    } else {
                        flush = Z_NO_FLUSH
                    }

                    while true {
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = UInt32(chunkSize)
                        let result = deflate(&stream, flush)
                        guard result >= Z_OK else {
                            throw CodecError.streamFailed(code: result, message: stream.msg != nil ? String(cString: stream.msg!) : "unknown")
                        }
                        let produced = chunkSize - Int(stream.avail_out)
                        if produced > 0 {
                            try ChunkedIO.write(
                                fd: pieceFD,
                                from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: produced)
                            )
                            totalOut += UInt64(produced)
                        }
                        if isFinal && inputDone {
                            if result == Z_STREAM_END { break }
                        } else if stream.avail_out > 0 {
                            // NO_FLUSH 无待输出,或 SYNC_FLUSH 已写出对齐标记:本轮完成。
                            break
                        }
                    }
                    onInputRead?(UInt64(want))
                }
            }
        }
        return (crc, totalOut)
    }

    /// 并行 inflate 单块:从 inFD 的 inputOffset 起解压 segmentLength 字节压缩段,
    /// 输出 pwrite 到 outFD 的 outputOffset 起 (outFD 为 nil 时仅算 CRC,供"测试
    /// 压缩包"使用)。期望产出 expectedOutput 字节,末段还须见到 Z_STREAM_END。
    /// 返回 (本块 crc, 实际输出字节数);onOutputProduced 回调增量回报产出。
    static func inflateBlock(
        inputFD: Int32,
        inputOffset: UInt64,
        segmentLength: UInt64,
        to outputFD: Int32?,
        outputOffset: UInt64,
        expectedOutput: UInt64,
        isFinalSegment: Bool,
        isCancelled: (() -> Bool)? = nil,
        onOutputProduced: ((UInt64) -> Void)? = nil
    ) throws -> (crc: UInt32, outputSize: UInt64) {
        guard segmentLength > 0, expectedOutput > 0 else { throw ZipError.corruptEntry(reason: "空分块") }
        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw CodecError.initFailed(code: initResult) }
        defer { inflateEnd(&stream) }

        var crc: UInt32 = 0
        var consumed: UInt64 = 0
        var producedTotal: UInt64 = 0
        let chunkSize = ChunkedIO.bufferSize
        var inputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)
        var sawStreamEnd = false

        try inputBuffer.withUnsafeMutableBufferPointer { inBuf in
            try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                while true {
                    if isCancelled?() == true { throw CancellationError() }
                    if stream.avail_in == 0 && consumed < segmentLength {
                        let want = Int(min(UInt64(chunkSize), segmentLength - consumed))
                        try ChunkedIO.readFullAt(
                            fd: inputFD,
                            into: UnsafeMutableRawBufferPointer(start: inBuf.baseAddress, count: chunkSize),
                            want: want,
                            atOffset: inputOffset + consumed
                        )
                        consumed += UInt64(want)
                        stream.next_in = inBuf.baseAddress
                        stream.avail_in = UInt32(want)
                    }

                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    if result == Z_STREAM_END { sawStreamEnd = true }
                    guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                        throw ZipError.corruptEntry(reason: "分块 inflate z_err=\(result)")
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        crc = CRC32.update(crc, UnsafeBufferPointer(start: outBuf.baseAddress, count: produced))
                        // 超出本块期望产出的部分不落盘 (异常块图下的防御),最终由
                        // producedTotal 校验判为损坏,避免污染相邻块的输出区间。
                        let space = expectedOutput - producedTotal
                        if let outputFD, space > 0 {
                            let written = min(produced, Int(min(UInt64(produced), space)))
                            try ChunkedIO.write(
                                fd: outputFD,
                                from: UnsafeRawBufferPointer(start: outBuf.baseAddress, count: written),
                                atOffset: outputOffset + producedTotal
                            )
                        }
                        producedTotal += UInt64(produced)
                        onOutputProduced?(UInt64(produced))
                    }

                    if result == Z_BUF_ERROR && stream.avail_in == 0 && produced == 0 {
                        break // 输入耗尽且无推进:段结束
                    }
                    if consumed == segmentLength && stream.avail_in == 0 && produced == 0 {
                        break // 输入耗尽且无更多输出:非末段在 SYNC_FLUSH 边界正常收尾
                    }
                }
            }
        }
        guard producedTotal == expectedOutput else {
            throw ZipError.corruptEntry(reason: "分块输出 \(producedTotal) 字节 ≠ 期望 \(expectedOutput)")
        }
        if isFinalSegment && !sawStreamEnd {
            throw ZipError.corruptEntry(reason: "分块流未正常终结")
        }
        return (crc, producedTotal)
    }

    /// 内存版 raw deflate (小数据,测试与元数据用)。
    public static func deflateData(_ data: Data, level: Level) -> Data {
        guard level != .store else { return data }
        var stream = z_stream()
        guard deflateInit2_(
            &stream, level.zlibLevel, Z_DEFLATED, -15, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            return data
        }
        defer { deflateEnd(&stream) }
        var output = Data()
        let chunkOut = 1 << 16
        var outBuffer = [UInt8](repeating: 0, count: chunkOut)
        data.withUnsafeBytes { raw in
            let inBuf = raw.bindMemory(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.avail_in = UInt32(inBuf.count)
            repeat {
                outBuffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkOut)
                    _ = deflate(&stream, Z_FINISH)
                    let produced = chunkOut - Int(stream.avail_out)
                    output.append(contentsOf: outBuf[0..<produced])
                }
            } while stream.avail_out == 0
        }
        return output
    }

    /// 内存版 raw inflate (测试用)。
    public static func inflateData(_ data: Data, expectedSize: Int) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        output.reserveCapacity(expectedSize)
        let chunkOut = 1 << 16
        var outBuffer = [UInt8](repeating: 0, count: chunkOut)
        var ended = false
        data.withUnsafeBytes { raw in
            let inBuf = raw.bindMemory(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
            stream.avail_in = UInt32(inBuf.count)
            while !ended && stream.avail_in > 0 {
                outBuffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkOut)
                    let result = inflate(&stream, Z_FINISH)
                    if result == Z_STREAM_END { ended = true }
                    guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else { return }
                    let produced = chunkOut - Int(stream.avail_out)
                    output.append(contentsOf: outBuf[0..<produced])
                    if result == Z_BUF_ERROR && produced == 0 && !ended {
                        // 无输入无输出推进:流残缺,终止避免死循环。
                        return
                    }
                }
            }
        }
        return ended ? output : nil
    }
}
