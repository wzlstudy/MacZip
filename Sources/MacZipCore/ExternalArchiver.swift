import Foundation

/// 外部压缩工具桥接:7-Zip (7zz/7z) 与系统 tar。
/// 7z 负责 7z/rar 的压缩解压、固实、AES 加密;tar 负责 tar/tar.gz/tar.bz2/tar.xz。
/// 找不到 7z 时相关功能在菜单中优雅降级。
public final class ExternalArchiver {
    public static let shared = ExternalArchiver()

    private let fm = FileManager.default

    private init() {}

    // MARK: - 7-Zip 定位

    /// 候选路径:优先 bundle 内置,再 PATH 常见位置。
    public var sevenZipCandidates: [String] {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("7zz").path)
            candidates.append(resources.appendingPathComponent("7z").path)
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(execDir.appendingPathComponent("7zz").path)
            candidates.append(execDir.appendingPathComponent("7z").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/7zz",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7zz",
            "/usr/local/bin/7z"
        ])
        return candidates
    }

    /// 是否可用 (缓存一次结果,进程生命周期内 7z 不会消失)。
    public private(set) lazy var sevenZipPath: String? = {
        for candidate in sevenZipCandidates {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    public var isSevenZipAvailable: Bool {
        sevenZipPath != nil
    }

    // MARK: - tar 系

    public var isTarAvailable: Bool {
        fm.isExecutableFile(atPath: "/usr/bin/tar")
    }

    // MARK: - 7z 操作 (同步,进度由调用方以 indeterminate 呈现)

    public enum ArchiverError: Error, LocalizedError {
        case toolNotFound
        case executionFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .toolNotFound:
                return "未找到 7-Zip 引擎,请安装 7-Zip (brew install 7zz) 后重试"
            case .executionFailed(let message):
                return message.isEmpty ? "外部压缩工具执行失败" : message
            }
        }
    }

    /// 7z 压缩 (支持固实 / 加密 / 分卷)。inputs 为文件或目录。
    public func sevenZipCompress(
        inputs: [URL],
        output: URL,
        level: Int = 6,
        solid: Bool,
        password: String?,
        volumeSizeMB: Int?
    ) throws {
        guard let tool = sevenZipPath else { throw ArchiverError.toolNotFound }
        var args = ["a", "-t7z", "-mx=\(level)", "-ms=\(solid ? "on" : "off")"]
        if let password, !password.isEmpty {
            args.append("-p\(password)")
            args.append("-mhe=on")
        } else {
            args.append("-p") // 无密码占位,避免交互
        }
        if let volumeSizeMB, volumeSizeMB > 0 {
            args.append("-v\(volumeSizeMB)m")
        }
        args.append(output.path)
        args.append(contentsOf: inputs.map { $0.path })

        let result = run(tool, args: args)
        guard result.exitCode == 0 else {
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(result.output))
        }
    }

    /// 7z 解压。passwordCandidates 自动逐个尝试;全部失败抛 wrongPassword 类错误。
    public func sevenZipExtract(
        archive: URL,
        destination: URL,
        password: String?,
        passwordCandidates: [String],
        passwordPrompt: ((String, Int) -> String?)?
    ) throws {
        guard let tool = sevenZipPath else { throw ArchiverError.toolNotFound }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var attempts: [String?] = [password]
        attempts.append(contentsOf: passwordCandidates.map(Optional.init))
        attempts.append(nil) // 无密码尝试排最前候选之后的兜底

        for attempt in attempts {
            var args = ["x", "-y", "-o\(destination.path)", "-spe"]
            if let attempt, !attempt.isEmpty {
                args.append("-p\(attempt)")
            } else {
                args.append("-p")
            }
            args.append(archive.path)
            let result = run(tool, args: args)
            if result.exitCode == 0 { return }
            let output = result.output
            if output.contains("Wrong password") || output.contains("Cannot open encrypted") {
                continue
            }
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(output))
        }

        if let prompt = passwordPrompt {
            for round in 1...3 {
                guard let entered = prompt("该压缩包已加密", round), !entered.isEmpty else {
                    throw ZipError.cancelled
                }
                let result = run(tool, args: ["x", "-y", "-o\(destination.path)", "-spe", "-p\(entered)", archive.path])
                if result.exitCode == 0 { return }
            }
        }
        throw ZipError.wrongPassword
    }

    /// 7z 完整性测试。
    public func sevenZipTest(archive: URL, password: String?) throws {
        guard let tool = sevenZipPath else { throw ArchiverError.toolNotFound }
        var args = ["t"]
        if let password, !password.isEmpty {
            args.append("-p\(password)")
        } else {
            args.append("-p")
        }
        args.append(archive.path)
        let result = run(tool, args: args)
        guard result.exitCode == 0 else {
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(result.output))
        }
    }

    // MARK: - tar 系操作

    public func tarCompress(inputs: [URL], output: URL) throws {
        let flags: String
        switch ArchiveFormat.detect(url: output) {
        case .tarBz2: flags = "-cjf"
        case .tarXz: flags = "-cJf"
        case .tar: flags = "-cf"
        default: flags = "-czf" // tar.gz 兜底
        }
        let parent = output.deletingLastPathComponent()
        // tar 进入父目录打包,保持归档内相对路径干净。
        var args = [flags, output.lastPathComponent]
        args.append(contentsOf: inputs.map { $0.lastPathComponent })
        let result = run("/usr/bin/tar", args: args, currentDirectory: parent)
        guard result.exitCode == 0 else {
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(result.output))
        }
    }

    public func tarExtract(archive: URL, destination: URL) throws {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var args: [String]
        switch ArchiveFormat.detect(url: archive) {
        case .tarBz2: args = ["-xjf", archive.path]
        case .tarXz: args = ["-xJf", archive.path]
        case .tarGz, .gzip: args = ["-xzf", archive.path]
        default: args = ["-xf", archive.path]
        }
        args.append("-C")
        args.append(destination.path)
        let result = run("/usr/bin/tar", args: args, currentDirectory: nil)
        guard result.exitCode == 0 else {
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(result.output))
        }
    }

    /// 单文件 .gz 解压 (gzip -dc 的标准输出直连目标文件,流式落盘)。
    /// 解压产物不经过内存——旧实现 readDataToEndOfFile 会把整包解压结果读进 RAM。
    public func gzipExtract(archive: URL, destination: URL) throws {
        // 与 tar / 7z 提取入口一致:目标目录不存在时创建。
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let stem = archive.lastPathComponent.hasSuffix(".gz")
            ? String(archive.lastPathComponent.dropLast(3))
            : archive.lastPathComponent
        let outURL = destination.appendingPathComponent(stem.isEmpty ? archive.lastPathComponent : stem)
        let didPreExist = fm.fileExists(atPath: outURL.path)
        fm.createFile(atPath: outURL.path, contents: nil)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: outURL)
        } catch {
            throw ArchiverError.executionFailed(message: "无法创建输出文件: \(outURL.lastPathComponent)")
        }
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", archive.path]
        process.standardOutput = output
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? fm.removeItem(at: outURL)
            throw ArchiverError.executionFailed(message: "无法启动 /usr/bin/gzip: \(error.localizedDescription)")
        }
        // stdout 直写文件无管道缓冲风险;stderr 仅承载少量错误信息,同步排空不会死锁。
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // 失败清理半成品;输出文件此前已存在时不删 (避免误删用户文件)。
            if !didPreExist { try? fm.removeItem(at: outURL) }
            let message = String(data: stderrData, encoding: .utf8) ?? ""
            throw ArchiverError.executionFailed(message: lastMeaningfulLine(message))
        }
    }

    // MARK: - Process 封装

    struct RunResult {
        var exitCode: Int32
        var output: String
        var stdoutData: Data
    }

    private func run(
        _ launchPath: String,
        args: [String],
        currentDirectory: URL? = nil
    ) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return RunResult(exitCode: -1, output: "无法启动 \(launchPath): \(error.localizedDescription)", stdoutData: Data())
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var output = String(data: stdoutData, encoding: .utf8) ?? ""
        output += "\n" + (String(data: stderrData, encoding: .utf8) ?? "")
        return RunResult(exitCode: process.terminationStatus, output: output, stdoutData: stdoutData)
    }

    private func lastMeaningfulLine(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    private func ensureExists(_ url: URL) -> URL {
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }
}
