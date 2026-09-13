import Foundation

/// MacZipCLI:压缩引擎无头测试工具。
/// 与主 App / 扩展共享同一份 MacZipCore 源码 (raw swiftc 单模块编译,无需 import)。
/// 用法:
///   maczipcli compress <输入...> -o <输出.zip> [--level store|fast|standard|best] [--password <pw>] [--volume <MB>]
///   maczipcli extract <压缩包> [-d <目标目录>] [--password <pw>]
///   maczipcli test <压缩包> [--password <pw>]
///   maczipcli list <压缩包>

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[maczipcli] \(message)\n".utf8))
    exit(2)
}

final class CLIReporter: ArchiveProgressReporting {
    var isCancelled = false
    init() {}
    func begin(totalBytes: UInt64, title: String) {
        print("▶ \(title) (共 \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)))")
    }
    func willProcessFile(_ name: String) {}
    func advance(by bytes: UInt64) {
        // 简单吞吐输出,测试主要看终态。
    }
    func finish(message: String, subtitle: String?) {
        if let subtitle { print("✅ \(message) — \(subtitle)") } else { print("✅ \(message)") }
    }
    func fail(message: String) { print("❌ \(message)") }
}

guard CommandLine.arguments.count >= 3 else {
    print("""
    MacZipCLI — MacZip 压缩引擎无头测试工具
    用法:
      maczipcli compress <输入...> -o <输出.zip> [--level fast|standard|best] [--password <pw>] [--volume <MB>]
      maczipcli extract <压缩包> [-d <目录>] [--password <pw>]
      maczipcli test <压缩包> [--password <pw>]
      maczipcli list <压缩包>
    """)
    exit(0)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args[0]
let rest = Array(args.dropFirst())
var positional: [String] = []
var named: [String: String] = [:]
var index = 0
while index < rest.count {
    let token = rest[index]
    if token == "--aes" {
        named[token] = "1"
        index += 1
    } else if token == "-o" || token == "-d" || token == "--password" || token == "--volume" || token == "--level" || token == "--block-size" {
        guard index + 1 < rest.count else { die("参数 \(token) 缺值") }
        named[token] = rest[index + 1]
        index += 2
    } else {
        positional.append(token)
        index += 1
    }
}

let reporter = CLIReporter()
let service = ArchiveService.shared

func expandInputs(_ paths: [String]) -> [URL] {
    paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
}

switch command {
case "compress":
    guard let output = named["-o"] else { die("compress 需要 -o <输出>") }
    let inputs = expandInputs(positional)
    guard !inputs.isEmpty else { die("没有输入文件") }
    let level: ZlibCodec.Level = {
        switch named["--level"] {
        case "store": return .store
        case "fast": return .fast
        case "best": return .best
        default: return .standard
        }
    }()
    let volumeMB = named["--volume"].flatMap(Int.init)
    let blockMB = named["--block-size"].flatMap(Int.init)
    do {
        let result = try service.compress(
            inputs: inputs,
            output: URL(fileURLWithPath: (output as NSString).expandingTildeInPath),
            format: .zip,
            level: level,
            password: named["--password"],
            volumeSizeMB: volumeMB,
            parallelBlockSizeMB: blockMB,
            useAES: named["--aes"] != nil,
            reporter: reporter
        )
        print("产物: \(result.path)")
    } catch {
        die("压缩失败: \(error)")
    }

case "extract":
    guard positional.count == 1 else { die("extract 需要 <压缩包>") }
    let archiveURL = expandInputs(positional)[0]
    do {
        let destination = try service.extract(
            archive: archiveURL,
            destination: named["-d"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            password: named["--password"],
            reporter: reporter
        )
        print("解压到: \(destination.path)")
    } catch {
        die("解压失败: \(error)")
    }

case "test":
    guard positional.count == 1 else { die("test 需要 <压缩包>") }
    do {
        try service.test(
            archive: expandInputs(positional)[0],
            password: named["--password"],
            reporter: reporter
        )
    } catch {
        die("测试失败: \(error)")
    }

case "list":
    guard positional.count == 1 else { die("list 需要 <压缩包>") }
    do {
        let entries = try ZipReader(archiveURL: expandInputs(positional)[0]).listEntries()
        print("共 \(entries.count) 个条目:")
        for entry in entries {
            let flag = entry.isDirectory ? "DIR " : (entry.isEncrypted ? "🔒  " : "    ")
            print("  \(flag)\(entry.name)  (\(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)))")
        }
    } catch {
        die("读取失败: \(error)")
    }

default:
    die("未知命令: \(command)")
}
