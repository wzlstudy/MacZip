import Foundation

/// 大文件分块 I/O 基元:POSIX read/write + 单块预分配缓冲。
///
/// 不用 `FileHandle.readData(ofLength:)` / 逐块构造 `Data` 的原因:实测 (macOS 12,
/// 默认 malloc) 1 MiB 级 Data 分配在进程生命周期内不会被回收复用,进程 RSS 随处理
/// 字节数线性增长——循环读 512MB 文件峰值 ~537MB,改用单块预分配缓冲后 ~3MB。
/// 压缩 / 解压 / 加密 / 负载搬运 / 分卷切分合并等长流水线统一经由本文件的缓冲方案,
/// 内存占用因此与文件大小无关。
enum ChunkedIO {
    /// 标准分块大小。
    static let bufferSize = 1 << 20

    /// 顺序读一块 (至多 want 字节,遇 EOF 返回已读量)。EINTR 自动重试。
    static func read(fd: Int32, into buffer: UnsafeMutableRawBufferPointer, want: Int) throws -> Int {
        var done = 0
        while done < want {
            let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: done), want - done)
            if n > 0 { done += n; continue }
            if n == 0 { break }
            if errno == EINTR { continue }
            throw ZipError.ioFailure(detail: "read: \(String(cString: strerror(errno)))")
        }
        return done
    }

    /// 读满 want 字节;EOF 提前到达抛 truncatedEntry。
    static func readFull(fd: Int32, into buffer: UnsafeMutableRawBufferPointer, want: Int) throws {
        let n = try read(fd: fd, into: buffer, want: want)
        guard n == want else { throw ZipError.truncatedEntry }
    }

    /// 写满一整段;部分写继续推进,EINTR 自动重试。
    static func write(fd: Int32, from buffer: UnsafeRawBufferPointer) throws {
        guard buffer.count > 0 else { return }
        var done = 0
        while done < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done)
            if n >= 0 { done += n; continue }
            if errno == EINTR { continue }
            throw ZipError.ioFailure(detail: "write: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - 定位读写 (分块并行基元)

    /// 定位读满 want 字节 (pread,不移动文件偏移,多线程共享同一 fd 安全)。
    /// EOF 提前到达抛 truncatedEntry。
    static func readFullAt(
        fd: Int32,
        into buffer: UnsafeMutableRawBufferPointer,
        want: Int,
        atOffset offset: UInt64
    ) throws {
        var done = 0
        while done < want {
            let n = pread(fd, buffer.baseAddress!.advanced(by: done), want - done, off_t(offset) + off_t(done))
            if n > 0 { done += n; continue }
            if n == 0 { throw ZipError.truncatedEntry }
            if errno == EINTR { continue }
            throw ZipError.ioFailure(detail: "pread: \(String(cString: strerror(errno)))")
        }
    }

    /// 定位写满一整段 (pwrite,不移动文件偏移)。各线程写互不重叠区间即可并行。
    static func write(
        fd: Int32,
        from buffer: UnsafeRawBufferPointer,
        atOffset offset: UInt64
    ) throws {
        guard buffer.count > 0 else { return }
        var done = 0
        while done < buffer.count {
            let n = pwrite(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(offset) + off_t(done))
            if n >= 0 { done += n; continue }
            if errno == EINTR { continue }
            throw ZipError.ioFailure(detail: "pwrite: \(String(cString: strerror(errno)))")
        }
    }
}
