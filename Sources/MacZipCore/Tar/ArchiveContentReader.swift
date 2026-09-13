import Foundation

/// 归档内容读取的统一入口:为预览窗口/QuickLook 提供"列出条目 + 抽取单条"能力,
/// 屏蔽底层是 ZIP 家族还是 TAR 家族 (tar.gz 会先解压到临时 tar 再解析)。
///
/// 加密/密码只对 ZIP 家族有意义;TAR 无加密概念。
public final class ArchiveContentReader {
    public let format: ArchiveFormat
    /// 实际参与解析的文件 (tar.gz 场景下为解压后的临时 tar)。
    private let workingURL: URL
    private let isZipFamily: Bool

    private let zipReader: ZipReader?
    private let tarReader: TarReader?

    /// tar.gz 解出的临时文件所在目录,关闭时清理。
    private let stagingDir: URL?

    private init(
        format: ArchiveFormat,
        workingURL: URL,
        zipReader: ZipReader?,
        tarReader: TarReader?,
        stagingDir: URL?
    ) {
        self.format = format
        self.workingURL = workingURL
        self.isZipFamily = zipReader != nil
        self.zipReader = zipReader
        self.tarReader = tarReader
        self.stagingDir = stagingDir
    }

    deinit {
        if let stagingDir {
            try? FileManager.default.removeItem(at: stagingDir)
        }
    }

    // MARK: - 构造

    /// 打开一个归档。仅对 `ArchiveFormat.supportsContentPreview` 的格式可用。
    public static func open(url: URL) throws -> ArchiveContentReader {
        guard let format = ArchiveFormat.detect(url: url) else {
            throw ZipError.unsupportedArchiveFormat
        }
        switch format {
        case .zip, .jar:
            return ArchiveContentReader(
                format: format,
                workingURL: url,
                zipReader: ZipReader(archiveURL: url),
                tarReader: nil,
                stagingDir: nil
            )
        case .tar:
            return ArchiveContentReader(
                format: format,
                workingURL: url,
                zipReader: nil,
                tarReader: TarReader(archiveURL: url),
                stagingDir: nil
            )
        case .tarGz:
            // 解压到临时 tar 再解析 (gzip 无随机访问,需先落地)。
            let fm = FileManager.default
            let dir = fm.temporaryDirectory
                .appendingPathComponent("MacZip-targz-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let tarURL = dir.appendingPathComponent("content.tar")
            fm.createFile(atPath: tarURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: tarURL)
            do {
                _ = try ZlibCodec.gunzipFile(input: url, to: out)
                try? out.close()
            } catch {
                try? out.close()
                try? fm.removeItem(at: dir)
                throw error
            }
            return ArchiveContentReader(
                format: format,
                workingURL: tarURL,
                zipReader: nil,
                tarReader: TarReader(archiveURL: tarURL),
                stagingDir: dir
            )
        default:
            throw ZipError.unsupportedArchiveFormat
        }
    }

    /// 是否含加密条目 (仅 ZIP 家族可能为真)。
    public var mayBeEncrypted: Bool {
        isZipFamily
    }

    // MARK: - 读写

    public func listEntries() throws -> [ZipEntryInfo] {
        if let zipReader { return try zipReader.listEntries() }
        if let tarReader { return try tarReader.listEntries() }
        throw ZipError.unsupportedArchiveFormat
    }

    /// 抽取单个条目。ZIP 家族支持密码;TAR 忽略密码参数。
    public func extractEntry(
        _ entry: ZipEntryInfo,
        to destination: URL,
        password: String?,
        passwordCandidates: [String] = []
    ) throws {
        if let zipReader {
            try zipReader.extractEntry(entry, to: destination, password: password, passwordCandidates: passwordCandidates)
            return
        }
        if let tarReader {
            try tarReader.extractEntry(entry, to: destination)
            return
        }
        throw ZipError.unsupportedArchiveFormat
    }

    /// 校验密码 (仅 ZIP 家族;TAR 恒为 true)。
    public func verifyPassword(_ password: String, for entry: ZipEntryInfo) throws -> Bool {
        guard let zipReader else { return true }
        return try zipReader.verifyPassword(password, for: entry)
    }
}
