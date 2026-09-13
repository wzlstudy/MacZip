import Foundation

/// 高层压缩/解压编排:格式路由、密码本联动、分卷识别、进度与取消。
/// 主 App 动作消费与 CLI 测试工具共用这一层。
public final class ArchiveService {
    public static let shared = ArchiveService()

    public init() {}

    // MARK: - 压缩

    public enum CompressFormat: String, CaseIterable, Codable {
        case zip
        case tarGz = "tar.gz"
        case sevenZip = "7z"

        public var fileExtension: String { rawValue }
        public var localizedName: String {
            switch self {
            case .zip: return "ZIP"
            case .tarGz: return "TAR.GZ"
            case .sevenZip: return "7Z"
            }
        }
    }

    /// 压缩一组路径。返回产物 URL (zip 分卷时为第一个分卷)。
    @discardableResult
    public func compress(
        inputs: [URL],
        output: URL,
        format: CompressFormat,
        level: ZlibCodec.Level = .standard,
        password: String? = nil,
        volumeSizeMB: Int? = nil,
        solid: Bool = false,
        excludeSystemJunk: Bool = true,
        parallelBlockSizeMB: Int? = nil,
        useAES: Bool = false,
        excludePatterns: [String] = [],
        reporter: ArchiveProgressReporting
    ) throws -> URL {
        // 输出重名自动避让:archive.zip → archive 2.zip。
        let finalOutput = Self.uniqueOutputURL(for: output)

        switch format {
        case .zip:
            let writer = ZipWriter(
                options: .init(
                    level: level,
                    password: password,
                    volumeSize: (volumeSizeMB ?? 0) > 0 ? UInt64(volumeSizeMB!) * 1024 * 1024 : nil,
                    excludeSystemJunk: excludeSystemJunk,
                    parallelBlockSize: parallelBlockSizeMB.map { UInt64($0) * 1024 * 1024 },
                    useAES: useAES,
                    excludePatterns: excludePatterns
                ),
                reporter: reporter
            )
            return try writer.write(inputs: inputs, to: finalOutput)
        case .tarGz:
            reporter.begin(totalBytes: 0, title: "正在创建 TAR.GZ")
            try ExternalArchiver.shared.tarCompress(inputs: inputs, output: finalOutput)
            reporter.finish(message: "压缩完成", subtitle: finalOutput.lastPathComponent)
            return finalOutput
        case .sevenZip:
            reporter.begin(totalBytes: 0, title: "正在创建 7Z")
            try ExternalArchiver.shared.sevenZipCompress(
                inputs: inputs,
                output: finalOutput,
                level: level.zlibLevel == 9 ? 9 : (level.zlibLevel == 1 ? 1 : 6),
                solid: solid,
                password: password,
                volumeSizeMB: volumeSizeMB
            )
            reporter.finish(message: "压缩完成", subtitle: finalOutput.lastPathComponent)
            return finalOutput
        }
    }

    /// 输出路径避让。
    public static func uniqueOutputURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        var counter = 1
        while true {
            counter += 1
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(stem) \(counter)")
                : dir.appendingPathComponent("\(stem) \(counter).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
    }

    /// 依据输入推断默认压缩产物名 (FastZip 行为:单选保留名称,多选用父目录名)。
    public static func defaultOutputURL(for inputs: [URL], format: CompressFormat) -> URL {
        let fm = FileManager.default
        guard let first = inputs.first else {
            return fm.temporaryDirectory.appendingPathComponent("Archive.\(format.fileExtension)")
        }
        var name: String
        if inputs.count == 1 {
            name = first.deletingPathExtension().lastPathComponent
            if fm.fileExists(atPath: first.path) && Self.isDirectory(first) {
                // 目录压缩:去掉原扩展名即可,如 Photos.dmg → Photos.zip。
                name = first.lastPathComponent
                name = (name as NSString).deletingPathExtension
            }
        } else {
            name = first.deletingLastPathComponent().lastPathComponent
        }
        if name.isEmpty { name = "Archive" }
        let parent = first.deletingLastPathComponent()
        return parent.appendingPathComponent("\(name).\(format.fileExtension)")
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - 解压

    /// 解压一个压缩包 (自动路由格式;分卷自动合并)。
    /// - Parameters:
    ///   - destination: 显式目标目录;nil 时解到压缩包同级 (zip 多根条目时建 "<名称>" 子目录)。
    public func extract(
        archive: URL,
        destination: URL?,
        password: String? = nil,
        preferPasswordBook: Bool = true,
        conflictPolicy: ZipReader.ConflictPolicy = .rename,
        passwordPrompt: ((String, Int) -> String?)? = nil,
        reporter: ArchiveProgressReporting
    ) throws -> URL {
        let fm = FileManager.default
        var workingArchive = archive

        // 1. 分卷:合并到临时区再解压。
        if ArchiveFormat.detect(url: archive) == .splitVolume,
           let volumes = SplitVolumes.allVolumes(forFirst: archive) {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("MacZip-merge-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            workingArchive = try SplitVolumes.merge(firstVolume: volumes[0], stagingDirectory: staging)
            reporter.begin(totalBytes: 0, title: "分卷合并完成,开始解压")
        }

        let candidates = preferPasswordBook ? PasswordBook.shared.passwords : []

        func runExtract(to destination: URL) throws {
            switch ArchiveFormat.detect(url: workingArchive) {
            case .zip, .jar, .splitVolume, nil:
                let reader = ZipReader(archiveURL: workingArchive)
                try reader.extractAll(
                    options: .init(
                        destination: destination,
                        password: password,
                        passwordCandidates: candidates,
                        passwordPrompt: passwordPrompt,
                        conflictPolicy: conflictPolicy
                    ),
                    reporter: reporter
                )
            case .gzip:
                reporter.begin(totalBytes: 0, title: "正在解压 GZIP")
                try ExternalArchiver.shared.gzipExtract(archive: workingArchive, destination: destination)
                reporter.finish(message: "解压完成", subtitle: destination.lastPathComponent)
            case .tar, .tarGz, .tarBz2, .tarXz:
                reporter.begin(totalBytes: 0, title: "正在解压 TAR 系归档")
                try ExternalArchiver.shared.tarExtract(archive: workingArchive, destination: destination)
                reporter.finish(message: "解压完成", subtitle: destination.lastPathComponent)
            case .sevenZip, .rar:
                reporter.begin(totalBytes: 0, title: "正在解压 \(workingArchive.pathExtension.uppercased())")
                try ExternalArchiver.shared.sevenZipExtract(
                    archive: workingArchive,
                    destination: destination,
                    password: password,
                    passwordCandidates: candidates,
                    passwordPrompt: passwordPrompt
                )
                reporter.finish(message: "解压完成", subtitle: destination.lastPathComponent)
            }
        }

        // 2. 目标目录策略:
        //    显式 destination → 直接使用;
        //    zip 且归档根下有多个顶层条目 → 建 "<压缩包名>" 子目录 (FastZip 体验);
        //    其余 → 解到压缩包同级目录。
        //    注意:分卷场景下父目录与命名取"原始分卷",而非合并临时文件所在目录。
        let actualDestination: URL
        if let destination {
            actualDestination = destination
        } else {
            let parent = archive.deletingLastPathComponent()
            var needsSubfolder = false
            switch ArchiveFormat.detect(url: workingArchive) {
            case .zip, .jar, .splitVolume, nil:
                if let entries = try? ZipReader(archiveURL: workingArchive).listEntries() {
                    let top = Set(entries.map { topLevelComponent($0.name) })
                    needsSubfolder = top.count > 1
                }
            default:
                needsSubfolder = false
            }
            if needsSubfolder {
                let folderName = (archive.lastPathComponent as NSString).deletingPathExtension
                actualDestination = Self.uniqueOutputURL(for: parent.appendingPathComponent(folderName))
                try fm.createDirectory(at: actualDestination, withIntermediateDirectories: true)
            } else {
                actualDestination = parent
            }
        }

        try runExtract(to: actualDestination)
        return actualDestination
    }

    private func topLevelComponent(_ name: String) -> String {
        let parts = name.split(separator: "/").map(String.init)
        return parts.first ?? name
    }

    /// 仅解压指定条目 (预览窗口"提取选中项"用)。目标路径按条目相对路径还原。
    public func extract(
        archive: URL,
        entries: [ZipEntryInfo],
        destination: URL,
        password: String? = nil,
        preferPasswordBook: Bool = true,
        conflictPolicy: ZipReader.ConflictPolicy = .rename,
        passwordPrompt: ((String, Int) -> String?)? = nil,
        reporter: ArchiveProgressReporting
    ) throws {
        guard !entries.isEmpty else { return }
        let candidates = preferPasswordBook ? PasswordBook.shared.passwords : []
        let reader = ZipReader(archiveURL: archive)
        try reader.extractAll(
            entries: entries,
            options: .init(
                destination: destination,
                password: password,
                passwordCandidates: candidates,
                passwordPrompt: passwordPrompt,
                conflictPolicy: conflictPolicy
            ),
            reporter: reporter
        )
    }

    // MARK: - 测试

    /// 测试压缩包完整性 (zip 内建引擎;7z/rar 走外部工具)。
    public func test(
        archive: URL,
        password: String? = nil,
        preferPasswordBook: Bool = true,
        passwordPrompt: ((String, Int) -> String?)? = nil,
        reporter: ArchiveProgressReporting
    ) throws {
        let fm = FileManager.default
        let candidates = preferPasswordBook ? PasswordBook.shared.passwords : []
        switch ArchiveFormat.detect(url: archive) {
        case .sevenZip, .rar:
            try ExternalArchiver.shared.sevenZipTest(archive: archive, password: password)
            // 收尾 (finish/关进度窗) 由调用方统一处理,避免双重提示。
        default:
            try ZipReader(archiveURL: archive).test(
                options: .init(
                    destination: fm.temporaryDirectory,
                    password: password,
                    passwordCandidates: candidates,
                    passwordPrompt: passwordPrompt
                ),
                reporter: reporter
            )
        }
    }
}
