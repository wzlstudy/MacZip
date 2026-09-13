import Foundation

/// MacZip 引擎测试套件 (SwiftPM 在无 Xcode 的 CLT 14.x 上 manifest 编译损坏,
/// 故以可执行 runner 形式组织;Scripts/test.sh 直接用 swiftc 与 Core 同模块编译运行)。
/// 断言失败累积计数,全部通过打印 SUMMARY 后 exit(0)。

var passed = 0
var failed = 0

func expectTrue(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    expectTrue(a == b, "\(name) (\(a) == \(b))")
}

// MARK: - 工作区

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("MacZipTests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

func makeFixture() throws -> URL {
    let src = work.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: src.appendingPathComponent("sub/中文目录"), withIntermediateDirectories: true)
    try "hello maczip 你好世界".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "second file".write(to: src.appendingPathComponent("b.log"), atomically: true, encoding: .utf8)
    let binary = src.appendingPathComponent("binary.bin")
    fm.createFile(atPath: binary.path, contents: Data((0..<100_000).map { UInt8($0 % 251) }))
    // 伪随机不可压缩数据 (200KB),触发多分卷与 deflate 真实路径
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let random = Data((0..<200_000).map { _ -> UInt8 in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 33)
    })
    fm.createFile(atPath: src.appendingPathComponent("random.bin").path, contents: random)
    try "nested".write(to: src.appendingPathComponent("sub/c.txt"), atomically: true, encoding: .utf8)
    try "unicode".write(to: src.appendingPathComponent("sub/中文目录/d 文件.txt"), atomically: true, encoding: .utf8)
    return src
}

func filesUnder(_ dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
    while let next = enumerator?.nextObject() as? URL {
        let isDir = (try? next.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir {
            let relative = next.path.replacingOccurrences(of: dir.path + "/", with: "")
            result[relative] = try? Data(contentsOf: next)
        }
    }
    return result
}

// MARK: - 1. CRC32 已知向量

print("CRC32")
let crcVector = Array("123456789".utf8)
expectEqual(crcVector.withUnsafeBufferPointer { CRC32.checksum($0) }, UInt32(0xCBF43926), "标准向量 123456789")

// 大缓冲分块一致性:update() 内部按 1 MiB 分段调用 libz,验证跨段链接语义正确。
do {
    var big = [UInt8](repeating: 0, count: 3 * 1024 * 1024 + 12345)
    var seed: UInt64 = 0x1234_5678_9ABC_DEF0
    for i in big.indices {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        big[i] = UInt8(truncatingIfNeeded: seed >> 33)
    }
    let oneShot = big.withUnsafeBufferPointer { CRC32.checksum($0) }
    let localTable = big.withUnsafeBufferPointer { buf -> UInt32 in
        var c = UInt32(0) ^ 0xFFFFFFFF
        for byte in buf { c = CRC32.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
    expectEqual(oneShot, localTable, "3MiB 缓冲 libz CRC 与本地查表一致")
    // 分两段增量链接也应得到相同结果。
    let half = big.count / 3
    let c1 = big[0..<half].withUnsafeBufferPointer { CRC32.checksum($0) }
    let c2 = big[half...].withUnsafeBufferPointer { CRC32.update(c1, $0) }
    expectEqual(c2, oneShot, "跨段增量链接一致")
}

// MARK: - 2. ZipCrypto 双向

print("ZipCrypto")
do {
    let plain = Data("top secret payload 测试".utf8)
    var cipher = plain
    var context = ZipCrypto.Context(password: Array("pw-α-123".utf8))
    cipher.withUnsafeMutableBytes { raw in
        let buf = raw.bindMemory(to: UInt8.self)
        context.encryptInPlace(buf)
    }
    expectTrue(cipher != plain, "密文不同于明文")

    var decryptor = ZipCrypto.Context(password: Array("pw-α-123".utf8))
    cipher.withUnsafeMutableBytes { raw in
        let buf = raw.bindMemory(to: UInt8.self)
        decryptor.decryptInPlace(buf)
    }
    expectTrue(cipher == plain, "解密还原明文")
}

// MARK: - 3. zip 回环 (多线程 deflate / store / 目录 / 中文)

print("ZipWriter/ZipReader 回环")
do {
    let src = try makeFixture()
    let out = work.appendingPathComponent("rt.zip")
    let writer = ZipWriter(options: .init(level: .standard), reporter: NullProgressReporter())
    try writer.write(inputs: [src], to: out)

    let extractDir = work.appendingPathComponent("rt-out")
    let reader = ZipReader(archiveURL: out)
    _ = try reader.extractAll(options: .init(destination: extractDir), reporter: NullProgressReporter())

    let original = try filesUnder(src)
    let restored = try filesUnder(extractDir.appendingPathComponent(src.lastPathComponent))
    expectTrue(original == restored, "全部文件字节一致 (\(original.count) 个文件)")

    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", "-qq", out.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try unzip.run()
    unzip.waitUntilExit()
    expectTrue(unzip.terminationStatus == 0, "系统 unzip -t 接受我们生成的包")
} catch {
    expectTrue(false, "回环异常: \(error)")
}

// MARK: - 3b. 单条目按需解压 (预览窗口内容预览用)

print("单条目预览解压")
do {
    let src = try makeFixture()
    let out = work.appendingPathComponent("preview.zip")
    try ZipWriter(options: .init(level: .standard), reporter: NullProgressReporter())
        .write(inputs: [src], to: out)

    let reader = ZipReader(archiveURL: out)
    let entries = try reader.listEntries()
    guard let plain = entries.first(where: { !$0.isDirectory && $0.name.hasSuffix("a.txt") }) else {
        throw ZipError.corruptEntry(reason: "fixture 缺少 a.txt")
    }
    let dest = work.appendingPathComponent("preview-a.txt")
    let written = try reader.extractEntry(plain, to: dest, password: nil)
    expectEqual(try String(contentsOf: dest, encoding: .utf8), "hello maczip 你好世界", "单条目内容正确")
    expectEqual(written, plain.uncompressedSize, "返回字节数与条目一致")

    // 加密包:未给密码时密码本候选命中;错误密码被拒绝。
    let encOut = work.appendingPathComponent("preview-enc.zip")
    try ZipWriter(options: .init(level: .fast, password: "pwπ"), reporter: NullProgressReporter())
        .write(inputs: [src], to: encOut)
    let encReader = ZipReader(archiveURL: encOut)
    let encEntries = try encReader.listEntries()
    guard let enc = encEntries.first(where: { !$0.isDirectory && $0.name.hasSuffix("a.txt") }) else {
        throw ZipError.corruptEntry(reason: "加密 fixture 缺少 a.txt")
    }
    let encDest = work.appendingPathComponent("preview-enc-a.txt")
    _ = try encReader.extractEntry(enc, to: encDest, password: nil, passwordCandidates: ["pwπ"])
    expectEqual(try String(contentsOf: encDest, encoding: .utf8), "hello maczip 你好世界", "候选密码单条目解压正确")

    var rejected = false
    do {
        _ = try encReader.extractEntry(
            enc,
            to: work.appendingPathComponent("preview-bad.txt"),
            password: "wrong"
        )
    } catch {
        rejected = true
    }
    expectTrue(rejected, "单条目错误密码被拒绝")
} catch {
    expectTrue(false, "单条目预览异常: \(error)")
}

// MARK: - 4. 加密回环 + 错误密码拒绝

print("加密压缩")
do {
    let src = try makeFixture()
    let out = work.appendingPathComponent("enc.zip")
    let writer = ZipWriter(
        options: .init(level: .best, password: "秘密α123"),
        reporter: NullProgressReporter()
    )
    try writer.write(inputs: [src], to: out)

    let extractDir = work.appendingPathComponent("enc-out")
    let reader = ZipReader(archiveURL: out)
    _ = try reader.extractAll(
        options: .init(destination: extractDir, password: "秘密α123"),
        reporter: NullProgressReporter()
    )
    let original = try filesUnder(src)
    let restored = try filesUnder(extractDir.appendingPathComponent(src.lastPathComponent))
    expectTrue(original == restored, "加密回环字节一致")

    var wrongRejected = false
    do {
        let badDir = work.appendingPathComponent("enc-bad")
        _ = try ZipReader(archiveURL: out).extractAll(
            options: .init(destination: badDir, password: "wrong"),
            reporter: NullProgressReporter()
        )
    } catch {
        wrongRejected = true
    }
    expectTrue(wrongRejected, "错误密码被拒绝")
} catch {
    expectTrue(false, "加密异常: \(error)")
}

// MARK: - 5. 互操作:系统 zip 生成的加密包 (store/deflate 混合 + 数据描述符)

print("互操作")
do {
    let src = try makeFixture()
    let sysZip = work.appendingPathComponent("sys.zip")
    let zipProc = Process()
    zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zipProc.arguments = ["-q", "-P", "pw123", "-r", sysZip.path, "."]
    zipProc.currentDirectoryURL = src
    zipProc.standardOutput = FileHandle.nullDevice
    try zipProc.run()
    zipProc.waitUntilExit()
    expectTrue(zipProc.terminationStatus == 0, "系统 zip 生成 fixture")

    let extractDir = work.appendingPathComponent("sys-out")
    _ = try ZipReader(archiveURL: sysZip).extractAll(
        options: .init(destination: extractDir, password: "pw123"),
        reporter: NullProgressReporter()
    )
    let original = try filesUnder(src)
    let restored = try filesUnder(extractDir)
    expectTrue(original == restored, "解压系统 zip 加密包")

    try ZipReader(archiveURL: sysZip).test(
        options: .init(destination: work, password: "pw123"),
        reporter: NullProgressReporter()
    )
    expectTrue(true, "test() 校验系统 zip 通过")
} catch {
    expectTrue(false, "互操作异常: \(error)")
}

// MARK: - 6. 分卷切分/合并 + ArchiveService 自动路由

print("分卷")
do {
    let src = try makeFixture()
    let out = work.appendingPathComponent("vol.zip")
    let writer = ZipWriter(
        options: .init(level: .fast, volumeSize: 32 * 1024),
        reporter: NullProgressReporter()
    )
    let firstVolume = try writer.write(inputs: [src], to: out)
    expectEqual(ArchiveFormat.detect(url: firstVolume), ArchiveFormat.splitVolume, "产物识别为分卷")
    let volumes = SplitVolumes.allVolumes(forFirst: firstVolume)
    expectTrue((volumes?.count ?? 0) >= 2, "分卷数 >= 2 (\(volumes?.count ?? 0))")

    let staging = work.appendingPathComponent("vol-merge")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    let merged = try SplitVolumes.merge(firstVolume: firstVolume, stagingDirectory: staging)
    let mergedEntries = try ZipReader(archiveURL: merged).listEntries()
    expectTrue(!mergedEntries.isEmpty, "合并后中央目录可解析")

    let extractDir = work.appendingPathComponent("vol-out")
    _ = try ArchiveService.shared.extract(archive: firstVolume, destination: extractDir, reporter: NullProgressReporter())
    let original = try filesUnder(src)
    let restored = try filesUnder(extractDir.appendingPathComponent(src.lastPathComponent))
    expectTrue(original == restored, "分卷回环字节一致")
} catch {
    expectTrue(false, "分卷异常: \(error)")
}

// MARK: - 7. 格式识别

print("格式识别")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.zip")), ArchiveFormat.zip, "zip")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.tar.gz")), ArchiveFormat.tarGz, "tar.gz")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.7z")), ArchiveFormat.sevenZip, "7z")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.rar")), ArchiveFormat.rar, "rar")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.gz")), ArchiveFormat.gzip, "gz")
expectEqual(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/vol.zip.001")), ArchiveFormat.splitVolume, "分卷")
expectTrue(ArchiveFormat.detect(url: URL(fileURLWithPath: "/x/a.txt")) == nil, "非压缩包")

// MARK: - 8. 密码本

print("密码本")
do {
    let groupDir = work.appendingPathComponent("group", isDirectory: true)
    try fm.createDirectory(at: groupDir, withIntermediateDirectories: true)
    let book = PasswordBook(sharedContainerURL: groupDir)
    let entry = PasswordEntry(title: "测试", password: "pw-1")
    expectTrue(book.add(entry), "新增")
    expectTrue(book.passwords == ["pw-1"], "读取")
    var updated = entry
    updated.password = "pw-2"
    expectTrue(book.update(updated), "更新")
    expectTrue(book.passwords == ["pw-2"], "更新生效")
    expectTrue(book.remove(id: entry.id), "删除")
    expectTrue(book.count == 0, "删除生效")
} catch {
    expectTrue(false, "密码本异常: \(error)")
}

// MARK: - 9. 动作可用性

print("动作可用性")
let archiveURL = URL(fileURLWithPath: "/tmp/fake.zip")
expectTrue(DefaultActionRegistry.ExtractHere().isAvailable(for: [archiveURL], isContainer: false), "压缩包可解压")
expectTrue(!DefaultActionRegistry.ExtractHere().isAvailable(for: [URL(fileURLWithPath: "/tmp/fake.txt")], isContainer: false), "普通文件不可解压")
expectTrue(!DefaultActionRegistry.ExtractHere().isAvailable(for: [archiveURL], isContainer: true), "空白背景不可解压")
expectTrue(DefaultActionRegistry.CompressDefault().isAvailable(for: [archiveURL], isContainer: false), "任何目标可压缩")

// MARK: - 9b. 文件名编码 (GBK → GB18030 回退)

print("文件名编码")
do {
    // 中文 Windows 工具常见:GBK 字节且未置 EFS (UTF-8) 位。
    let gbk = Data([
        0xbd, 0xd8, 0xd6, 0xb9, 0xb5, 0xbd, 0x39, 0xd4, 0xc2, 0xb7, 0xdd,
        0x28, 0xb0, 0xfc, 0xba, 0xac, 0x29, 0xb3, 0xf5, 0xca, 0xbc, 0xbb, 0xaf,
        0x73, 0x71, 0x6c, 0xbd, 0xc5, 0xb1, 0xbe
    ])
    expectEqual(
        ZipEntryNameDecoder.decode(gbk, isUTF8Declared: false),
        "截止到9月份(包含)初始化sql脚本",
        "GBK 文件名回退 GB18030 解码"
    )

    let utf8 = Data("中文名.txt".utf8)
    expectEqual(ZipEntryNameDecoder.decode(utf8, isUTF8Declared: true), "中文名.txt", "EFS 置位按 UTF-8")
    expectEqual(ZipEntryNameDecoder.decode(utf8, isUTF8Declared: false), "中文名.txt", "未置位但合法 UTF-8 仍按 UTF-8")
    expectEqual(ZipEntryNameDecoder.decode(Data("readme.txt".utf8), isUTF8Declared: false), "readme.txt", "ASCII 名称不受影响")
}

// MARK: - 10. 层级树模型 (预览窗口 / QuickLook 共用)

print("层级树")
do {
    func entry(_ name: String, size: UInt64 = 0, dir: Bool = false, encrypted: Bool = false) -> ZipEntryInfo {
        ZipEntryInfo(
            name: name, isDirectory: dir, compressedSize: size, uncompressedSize: size,
            crc: 0, method: 0, isEncrypted: encrypted, lastModified: nil, index: 0
        )
    }
    // 故意打乱顺序,并省略部分中间目录条目,验证自动补齐 + 排序 + 汇总。
    let flat: [ZipEntryInfo] = [
        entry("README.txt", size: 100),
        entry("资料/sub/d.txt", size: 30),
        entry("资料/b.txt", size: 20),
        entry("资料/sub/c.txt", size: 40, encrypted: true),
        entry("资料/", dir: true),
    ]
    let tree = ZipEntryTree.build(from: flat)

    // 顶层:README.txt 与 资料/ 两个节点 (文件在后,目录优先)。
    expectEqual(tree.count, 2, "顶层节点数")
    expectTrue(tree[0].isDirectory, "目录排在文件之前")
    expectEqual(tree[0].name, "资料", "目录名")
    expectEqual(tree[1].name, "README.txt", "文件名")

    // 资料/ 下应有 b.txt 与 sub/。
    let ziLiao = tree[0]
    expectEqual(ziLiao.children.count, 2, "资料子节点数")
    expectTrue(ziLiao.children[0].isDirectory, "sub 目录优先")
    // 大小汇总:20 + 30 + 40 = 90。
    expectEqual(ziLiao.displaySize, UInt64(90), "目录大小汇总")
    expectTrue(ziLiao.containsEncrypted, "目录加密标记向上冒泡")

    // 中间目录 sub 由 "资料/sub/d.txt" 自动补齐。
    let sub = ziLiao.children[0]
    expectEqual(sub.path, "资料/sub", "自动补齐的中间目录路径")
    expectEqual(sub.children.count, 2, "sub 子节点数")
    expectEqual(sub.children[0].path, "资料/sub/c.txt", "子文件相对路径正确")

    // 搜索:命中深层文件时,祖先目录链被保留。
    let filtered = tree.compactMap { $0.filtered(matching: "c.txt") }
    expectEqual(filtered.count, 1, "搜索命中根数")
    expectEqual(filtered[0].children.first?.children.first?.path, "资料/sub/c.txt", "搜索保留祖先链")

    // 搜索目录名保留整棵子树。
    let byDir = tree.compactMap { $0.filtered(matching: "sub") }
    expectEqual(byDir.first?.children.first?.children.count, 2, "命中目录保留整棵子树")

    let counts = ZipEntryTree.counts(in: tree)
    expectEqual(counts.files, 4, "文件计数")
    expectEqual(counts.folders, 2, "目录计数 (含自动补齐)")
}

// MARK: - 10b. 归档编辑 (删除 / 增加 / 清理)

print("归档编辑")
do {
    let src = try makeFixture()
    let archive = work.appendingPathComponent("edit.zip")
    try ZipWriter(options: .init(level: .standard), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    let rootName = src.lastPathComponent
    let before = try ZipReader(archiveURL: archive).listEntries()
    let beforeCount = before.count

    // 删除一个文件:其余条目保持字节可解压。
    let removed = try ZipArchiveEditor.delete(
        paths: ["\(rootName)/a.txt"],
        from: archive,
        reporter: NullProgressReporter()
    )
    expectEqual(removed, 1, "删除命中 1 项")
    let after = try ZipReader(archiveURL: archive).listEntries()
    expectEqual(after.count, beforeCount - 1, "条目数减一")
    expectTrue(!after.contains { $0.name == "\(rootName)/a.txt" }, "被删条目已消失")

    let extractDir = work.appendingPathComponent("edit-out")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: extractDir), reporter: NullProgressReporter()
    )
    expectTrue(
        !fm.fileExists(atPath: extractDir.appendingPathComponent("\(rootName)/a.txt").path),
        "解压结果中不再有被删文件"
    )
    expectEqual(
        try String(contentsOf: extractDir.appendingPathComponent("\(rootName)/b.log"), encoding: .utf8),
        "second file",
        "未删除条目内容完好"
    )

    // 系统 unzip 仍认可编辑后的包。
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", "-qq", archive.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try unzip.run(); unzip.waitUntilExit()
    expectTrue(unzip.terminationStatus == 0, "系统 unzip -t 接受编辑后的包")

    // 增加文件。
    let newFile = work.appendingPathComponent("added.txt")
    try "brand new content".write(to: newFile, atomically: true, encoding: .utf8)
    let added = try ZipArchiveEditor.add(
        inputs: [newFile],
        to: archive,
        password: nil,
        level: .standard,
        reporter: NullProgressReporter()
    )
    expectEqual(added, 1, "增加 1 项")
    let afterAdd = try ZipReader(archiveURL: archive).listEntries()
    expectTrue(afterAdd.contains { $0.name == "added.txt" }, "新增条目存在")

    let addOut = work.appendingPathComponent("edit-add-out")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: addOut), reporter: NullProgressReporter()
    )
    expectEqual(
        try String(contentsOf: addOut.appendingPathComponent("added.txt"), encoding: .utf8),
        "brand new content",
        "新增条目内容正确"
    )
} catch {
    expectTrue(false, "归档编辑异常: \(error)")
}

// 加密归档删除:无需密码,密文原样搬运。
do {
    let src = try makeFixture()
    let archive = work.appendingPathComponent("edit-enc.zip")
    try ZipWriter(
        options: .init(level: .fast, password: "pw-enc"),
        reporter: NullProgressReporter()
    ).write(inputs: [src], to: archive)

    let rootName = src.lastPathComponent
    _ = try ZipArchiveEditor.delete(
        paths: ["\(rootName)/b.log"],
        from: archive,
        reporter: NullProgressReporter()
    )
    let remaining = try ZipReader(archiveURL: archive).listEntries()
    expectTrue(!remaining.contains { $0.name == "\(rootName)/b.log" }, "加密包删除无需密码")

    let out = work.appendingPathComponent("edit-enc-out")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: out, password: "pw-enc"),
        reporter: NullProgressReporter()
    )
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("\(rootName)/a.txt"), encoding: .utf8),
        "hello maczip 你好世界",
        "加密包删除后其余条目仍可解压"
    )
} catch {
    expectTrue(false, "加密归档编辑异常: \(error)")
}

// 清理系统杂质。
do {
    let archive = work.appendingPathComponent("edit-clean.zip")
    let writer = ZipWriter(options: .init(level: .store, excludeSystemJunk: false), reporter: NullProgressReporter())
    let junkDir = work.appendingPathComponent("junk-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: junkDir, withIntermediateDirectories: true)
    try "keep".write(to: junkDir.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    try "junk".write(to: junkDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try writer.write(inputs: [junkDir], to: archive, rootBehavior: .flatten)

    let cleanRemoved = try ZipArchiveEditor.cleanSystemJunk(in: archive, reporter: NullProgressReporter())
    expectEqual(cleanRemoved, 1, "清理移除 .DS_Store")
    let names = try ZipReader(archiveURL: archive).listEntries().map { $0.name }
    expectTrue(names.contains("keep.txt") && !names.contains(".DS_Store"), "清理后仅保留正常文件")
} catch {
    expectTrue(false, "清理异常: \(error)")
}

// MARK: - 10c. TAR / TAR.GZ / JAR 内容读取

print("TAR 系与 JAR 读取")
do {
    let src = try makeFixture()
    let tarURL = work.appendingPathComponent("content.tar")
    let tarc = Process()
    tarc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tarc.arguments = ["-cf", tarURL.path, "-C", src.deletingLastPathComponent().path, src.lastPathComponent]
    try tarc.run(); tarc.waitUntilExit()
    expectTrue(tarc.terminationStatus == 0, "系统 tar 生成 fixture")

    // TAR 列表 + 抽取
    let tarReader = TarReader(archiveURL: tarURL)
    let tarEntries = try tarReader.listEntries()
    let tarNames = tarEntries.map { $0.name }
    expectTrue(tarNames.contains { $0.hasSuffix("/a.txt") }, "TAR 列出 a.txt")
    expectTrue(tarNames.contains { $0.hasSuffix("/sub/c.txt") }, "TAR 列出嵌套文件")
    guard let aEntry = tarEntries.first(where: { $0.name.hasSuffix("/a.txt") }) else {
        throw ZipError.corruptEntry(reason: "TAR fixture 缺少 a.txt")
    }
    let aOut = work.appendingPathComponent("tar-a.txt")
    try tarReader.extractEntry(aEntry, to: aOut)
    expectEqual(try String(contentsOf: aOut, encoding: .utf8), "hello maczip 你好世界", "TAR 抽取内容正确")

    // TAR.GZ:gunzip 后读取
    let tgzURL = work.appendingPathComponent("content.tar.gz")
    let gzc = Process()
    gzc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzc.arguments = ["-k", "-f", tarURL.path]
    try gzc.run(); gzc.waitUntilExit()
    // gzip -k 产物为 content.tar.gz
    expectTrue(fm.fileExists(atPath: tgzURL.path), "系统 gzip 生成 tar.gz")

    let tgzReader = try ArchiveContentReader.open(url: tgzURL)
    let tgzEntries = try tgzReader.listEntries()
    expectTrue(tgzEntries.contains { $0.name.hasSuffix("/a.txt") }, "TAR.GZ 列出 a.txt")
    guard let tgzA = tgzEntries.first(where: { $0.name.hasSuffix("/a.txt") }) else {
        throw ZipError.corruptEntry(reason: "TAR.GZ fixture 缺少 a.txt")
    }
    let tgzOut = work.appendingPathComponent("tgz-a.txt")
    try tgzReader.extractEntry(tgzA, to: tgzOut, password: nil)
    expectEqual(try String(contentsOf: tgzOut, encoding: .utf8), "hello maczip 你好世界", "TAR.GZ 抽取内容正确")

    // JAR:本质是 ZIP
    let jarURL = work.appendingPathComponent("content.jar")
    try ZipWriter(options: .init(level: .standard), reporter: NullProgressReporter())
        .write(inputs: [src], to: jarURL)
    expectEqual(ArchiveFormat.detect(url: jarURL), .jar, "jar 扩展名识别为 JAR")
    let jarReader = try ArchiveContentReader.open(url: jarURL)
    let jarEntries = try jarReader.listEntries()
    expectTrue(jarEntries.contains { $0.name.hasSuffix("/a.txt") }, "JAR 列出 a.txt")
    guard let jarA = jarEntries.first(where: { $0.name.hasSuffix("/a.txt") }) else {
        throw ZipError.corruptEntry(reason: "JAR fixture 缺少 a.txt")
    }
    let jarOut = work.appendingPathComponent("jar-a.txt")
    try jarReader.extractEntry(jarA, to: jarOut, password: nil)
    expectEqual(try String(contentsOf: jarOut, encoding: .utf8), "hello maczip 你好世界", "JAR 抽取内容正确")
} catch {
    expectTrue(false, "TAR/JAR 读取异常: \(error)")
}

// MARK: - 11. 大文件分块并行 (写入端分块 deflate + 读取端并行 inflate)

print("分块并行")
do {
    let src = work.appendingPathComponent("blocks-src", isDirectory: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    // ~3.5MB 文本+随机混合,blockSize = 1MiB → 4 块。
    var seed: UInt64 = 0xDEADBEEFCAFE
    let random = Data((0..<200_000).map { _ -> UInt8 in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 33)
    })
    var big = Data()
    while big.count < 3_500_000 {
        big.append("mixed segment \(big.count) lorem ipsum dolor sit amet\n".data(using: .utf8)!)
        big.append(random.prefix(60_000))
    }
    try big.write(to: src.appendingPathComponent("big.bin"))
    try "extra".write(to: src.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

    let archive = work.appendingPathComponent("blocks.zip")
    try ZipWriter(options: .init(level: .standard, parallelBlockSize: 1 << 20), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    // 中央目录携带块图 (证明写入端确实走了分块路径)。
    let entries = try ZipReader(archiveURL: archive).listEntries()
    guard let bigEntry = entries.first(where: { $0.name.hasSuffix("big.bin") }) else {
        throw ZipError.corruptEntry(reason: "分块 fixture 缺少 big.bin")
    }
    expectTrue(bigEntry.blockMap?.segmentSizes.count == 4, "块图记录 4 段 (\(bigEntry.blockMap?.segmentSizes.count ?? 0))")

    // 并行解压全部。
    let extractDir = work.appendingPathComponent("blocks-out")
    _ = try ZipReader(archiveURL: archive).extractAll(options: .init(destination: extractDir), reporter: NullProgressReporter())
    expectEqual(try Data(contentsOf: extractDir.appendingPathComponent("blocks-src/big.bin")), big, "分块并行回环字节一致")

    // 完整性测试 (并行、不落盘)。
    try ZipReader(archiveURL: archive).test(options: .init(destination: work), reporter: NullProgressReporter())
    expectTrue(true, "分块包 test() 通过")

    // 单条目按需解压 (预览窗口路径)。
    let single = work.appendingPathComponent("blocks-single.bin")
    _ = try ZipReader(archiveURL: archive).extractEntry(bigEntry, to: single, password: nil)
    expectEqual(try Data(contentsOf: single), big, "单条目并行解压一致")

    // 外部兼容性:系统 unzip 认可分块包。
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", "-qq", archive.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try unzip.run(); unzip.waitUntilExit()
    expectTrue(unzip.terminationStatus == 0, "系统 unzip -t 接受分块包")

    // 编辑后分块条目原样保留、仍可并行解压。
    _ = try ZipArchiveEditor.delete(paths: ["blocks-src/extra.txt"], from: archive, reporter: NullProgressReporter())
    let out2 = work.appendingPathComponent("blocks2-out")
    _ = try ZipReader(archiveURL: archive).extractAll(options: .init(destination: out2), reporter: NullProgressReporter())
    expectEqual(try Data(contentsOf: out2.appendingPathComponent("blocks-src/big.bin")), big, "编辑后分块条目完好")
} catch {
    expectTrue(false, "分块并行异常: \(error)")
}

// 分块并行 + 加密组合 (加密走串行流式路径,结果必须等价)。
do {
    let src = work.appendingPathComponent("blocks-enc-src", isDirectory: true)
    try fm.createDirectory(at: src.appendingPathComponent("d"), withIntermediateDirectories: true)
    var seed: UInt64 = 0xABCDEF
    var content = Data()
    while content.count < 2_500_000 {
        content.append("encrypted block \(content.count)\n".data(using: .utf8)!)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        content.append(Data([UInt8(truncatingIfNeeded: seed >> 33)]))
    }
    try content.write(to: src.appendingPathComponent("d/big2.bin"))

    let archive = work.appendingPathComponent("blocks-enc.zip")
    try ZipWriter(options: .init(level: .fast, password: "pw-blocks", parallelBlockSize: 1 << 20), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    let extractDir = work.appendingPathComponent("blocks-enc-out")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: extractDir, password: "pw-blocks"), reporter: NullProgressReporter()
    )
    expectEqual(try Data(contentsOf: extractDir.appendingPathComponent("blocks-enc-src/d/big2.bin")), content, "分块+加密回环字节一致")
} catch {
    expectTrue(false, "分块+加密异常: \(error)")
}

// MARK: - 12. WinZip AES 加密 (自研读写 + pyzipper 互操作)

func runShell(_ launchPath: String, _ args: [String]) -> (exit: Int32, out: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

print("WinZip AES")
do {
    let src = work.appendingPathComponent("aes-src", isDirectory: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    let content = "AES 加密测试 content 0123456789 🔒\n"
    try content.write(to: src.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    try "second".write(to: src.appendingPathComponent("b.log"), atomically: true, encoding: .utf8)

    let archive = work.appendingPathComponent("aes.zip")
    try ZipWriter(options: .init(level: .standard, password: "aes-pw-π", useAES: true), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    // 写入端头部规格:method 99 + AES extra。
    let entries = try ZipReader(archiveURL: archive).listEntries()
    expectTrue(entries.contains { $0.method == 99 }, "头部压缩方法为 99")

    // 自研读取回环。
    let out = work.appendingPathComponent("aes-out")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: out, password: "aes-pw-π"), reporter: NullProgressReporter()
    )
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("aes-src/secret.txt"), encoding: .utf8),
        content,
        "AES 回环字节一致"
    )

    // 错误密码拒绝 (口令校验值)。
    var wrongRejected = false
    do {
        _ = try ZipReader(archiveURL: archive).extractAll(
            options: .init(destination: work.appendingPathComponent("aes-bad"), password: "wrong"),
            reporter: NullProgressReporter()
        )
    } catch { wrongRejected = true }
    expectTrue(wrongRejected, "AES 错误密码被拒绝")

    // test() 路径 (解密不落盘)。
    try ZipReader(archiveURL: archive).test(
        options: .init(destination: work, password: "aes-pw-π"), reporter: NullProgressReporter()
    )
    expectTrue(true, "AES 包 test() 通过")

    // 编辑:AES 包删除条目无需密码,其余条目仍可解压。
    _ = try ZipArchiveEditor.delete(paths: ["aes-src/b.log"], from: archive, reporter: NullProgressReporter())
    let out2 = work.appendingPathComponent("aes-out2")
    _ = try ZipReader(archiveURL: archive).extractAll(
        options: .init(destination: out2, password: "aes-pw-π"), reporter: NullProgressReporter()
    )
    expectEqual(
        try String(contentsOf: out2.appendingPathComponent("aes-src/secret.txt"), encoding: .utf8),
        content,
        "AES 包编辑后其余条目完好"
    )
} catch {
    expectTrue(false, "AES 异常: \(error)")
}

// pyzipper 互操作 (双向;环境未装 pyzipper 时优雅跳过)。
do {
    let probe = runShell("/usr/bin/python3", ["-c", "import pyzipper"])
    if probe.exit != 0 {
        print("  (跳过 pyzipper 互操作: \(probe.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))")
    } else {
        let aesDir = work.appendingPathComponent("pyaes", isDirectory: true)
        try fm.createDirectory(at: aesDir, withIntermediateDirectories: true)
        let script = aesDir.appendingPathComponent("interop.py")
        let mine = aesDir.appendingPathComponent("mine.zip").path
        let theirs = aesDir.appendingPathComponent("theirs.zip").path
        let plain = "pyzipper 互操作 payload ✅\n"
        try plain.write(to: aesDir.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)

        let code = """
        import pyzipper, sys
        # 1) pyzipper 生成 AES-128 与 AES-256 (store 与 deflate 各一)
        for nbits, comp, tag in ((128, pyzipper.ZIP_STORED, 's128'), (256, pyzipper.ZIP_DEFLATED, 'd256')):
            with pyzipper.AESZipFile(r'\(theirs).{nbits}'.format(nbits=nbits), 'w',
                                     compression=comp, encryption=pyzipper.WZ_AES,
                                     encryption_kwargs={'nbits': nbits}) as z:
                z.setpassword('pw-参考'.encode())
                z.writestr('inner/{}.txt'.format(tag), 'nbits={} comp={} 内容'.format(nbits, comp).encode())
        # 2) pyzipper 读取 MacZip 生成的 AES 包
        with pyzipper.AESZipFile(r'\(mine)') as z:
            z.setpassword('aes-pw-π'.encode())
            names = z.namelist()
            info = z.getinfo([n for n in names if n.endswith('secret.txt')][0])
            # pyzipper 会把 compress_type 改写为 AES extra 里的实际方法 (0/8)
            assert info.compress_type in (0, 8), 'real method expected, got %r' % info.compress_type
            data = z.read(info.filename).decode()
            assert 'AES 加密测试' in data, 'content mismatch'
            print('PYOK', len(names))
        """
        try code.write(to: script, atomically: true, encoding: .utf8)

        // MacZip 生成 AES-256 包。
        let mineSrc = work.appendingPathComponent("aes-src")
        try ZipWriter(options: .init(level: .standard, password: "aes-pw-π", useAES: true), reporter: NullProgressReporter())
            .write(inputs: [mineSrc], to: URL(fileURLWithPath: mine))

        // pyzipper 读取 MacZip 包。
        let verify = runShell("/usr/bin/python3", [script.path])
        expectTrue(verify.exit == 0 && verify.out.contains("PYOK"), "pyzipper 读取 MacZip AES 包")

        // MacZip 读取 pyzipper 包 (128/256,store/deflate)。
        var allRead = true
        for tag in ["128", "256"] {
            let theirs = URL(fileURLWithPath: "\(theirs).\(tag)")
            guard fm.fileExists(atPath: theirs.path) else { allRead = false; continue }
            let out3 = work.appendingPathComponent("pyaes-out-\(tag)")
            do {
                _ = try ZipReader(archiveURL: theirs).extractAll(
                    options: .init(destination: out3, password: "pw-参考"), reporter: NullProgressReporter()
                )
                let files = (try? fm.contentsOfDirectory(atPath: out3.appendingPathComponent("inner").path)) ?? []
                if files.isEmpty { allRead = false }
            } catch {
                allRead = false
                print("  ❌ 读取 pyzipper-\(tag) 失败: \(error)")
            }
        }
        expectTrue(allRead, "MacZip 读取 pyzipper AES 包 (128/256)")
    }
}

// MARK: - 13. 损坏包容错解压 (跳过坏条目)

print("容错解压")
do {
    let src = work.appendingPathComponent("tolerant-src", isDirectory: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try String(repeating: "AAA", count: 40).write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try String(repeating: "BBB", count: 40).write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    try String(repeating: "CCC", count: 40).write(to: src.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

    // store 档:载荷即原文,翻转一个字节必然触发该条目 CRC 校验失败。
    let archive = work.appendingPathComponent("tolerant.zip")
    try ZipWriter(options: .init(level: .store), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    // 定位中央目录起点 (尾部扫 EOCD),破坏其前 3 字节 (落在最后一个文件 c.txt 的载荷内)。
    let raw = try Data(contentsOf: archive)
    var eocdOffset = -1
    if raw.count >= 22 {
        var i = raw.count - 22
        while i >= 0 {
            if raw.readLE32(at: i) == 0x06054b50 { eocdOffset = i; break }
            i -= 1
        }
    }
    expectTrue(eocdOffset > 0, "EOCD 定位成功")
    let cdOffset = Int(raw.readLE32(at: eocdOffset + 16))
    expectTrue(cdOffset > 3, "中央目录偏移合理 (\(cdOffset))")
    var corrupted = raw
    corrupted[cdOffset - 3] ^= 0xFF
    try corrupted.write(to: archive)

    let reader = ZipReader(archiveURL: archive)

    // skipCorrupt:抛 partialFailure 且只跳过 c.txt,其余两个文件完好。
    let out1 = work.appendingPathComponent("tolerant-out-skip")
    do {
        _ = try reader.extractAll(options: .init(destination: out1, errorPolicy: .skipCorrupt), reporter: NullProgressReporter())
        expectTrue(false, "skipCorrupt 应抛 partialFailure")
    } catch let ZipError.partialFailure(skipped) {
        expectEqual(skipped.count, 1, "跳过 1 个条目")
        expectTrue(skipped.first?.hasSuffix("c.txt") == true, "跳过的是 c.txt (\(skipped.first ?? "?"))")
    }
    expectEqual(
        try String(contentsOf: out1.appendingPathComponent("tolerant-src/a.txt"), encoding: .utf8),
        String(repeating: "AAA", count: 40),
        "a.txt 完好解压"
    )
    expectEqual(
        try String(contentsOf: out1.appendingPathComponent("tolerant-src/b.txt"), encoding: .utf8),
        String(repeating: "BBB", count: 40),
        "b.txt 完好解压"
    )
    expectTrue(!fm.fileExists(atPath: out1.appendingPathComponent("tolerant-src/c.txt").path), "损坏条目无残留文件")

    // abortFirst:直接抛数据错误 (非 partialFailure)。
    var abortedWithCorrupt = false
    do {
        _ = try reader.extractAll(options: .init(destination: out1, errorPolicy: .abortFirst), reporter: NullProgressReporter())
    } catch let ZipError.partialFailure {
        abortedWithCorrupt = false
    } catch {
        abortedWithCorrupt = true
    }
    expectTrue(abortedWithCorrupt, "abortFirst 直接抛数据错误")
} catch {
    expectTrue(false, "容错解压异常: \(error)")
}

// MARK: - 14. WinZip 分卷 (z01..zNN + zip 末卷)

print("WinZip 分卷")
do {
    let dir = work.appendingPathComponent("wzsplit", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // 完整包 (~1MB 不可压数据,store 档)。
    var seed: UInt64 = 0x1234ABCD
    let payload = Data((0..<1_000_000).map { _ -> UInt8 in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 33)
    })
    try payload.write(to: dir.appendingPathComponent("payload.bin"))
    let fullZip = dir.appendingPathComponent("full.zip")
    try ZipWriter(options: .init(level: .store), reporter: NullProgressReporter())
        .write(inputs: [dir.appendingPathComponent("payload.bin")], to: fullZip, rootBehavior: .flatten)
    let fullBytes = try Data(contentsOf: fullZip)

    // 切成 WinZip 布局: data.z01..zNN + data.zip (末片物理上就是含中央目录的 zip)。
    let pieceSize = 300_000
    var offset = 0
    var index = 1
    while offset < fullBytes.count {
        let take = min(pieceSize, fullBytes.count - offset)
        let isLast = offset + take >= fullBytes.count
        let name = isLast ? "data.zip" : "data.z\(String(format: "%02d", index))"
        try fullBytes.subdata(in: offset..<(offset + take)).write(to: dir.appendingPathComponent(name))
        offset += take
        if !isLast { index += 1 }
    }
    expectTrue(
        ["data.z01", "data.z02", "data.z03", "data.zip"].allSatisfy {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        },
        "分卷文件齐备 (3 中间卷 + 1 末卷)"
    )

    // 判定。
    expectEqual(ArchiveFormat.detect(url: dir.appendingPathComponent("data.z01")), ArchiveFormat.splitVolume, "z01 判定为分卷")
    expectEqual(ArchiveFormat.detect(url: dir.appendingPathComponent("data.zip")), ArchiveFormat.splitVolume, "有 z01 兄弟的 zip 判定为分卷末卷")
    let loneZip = work.appendingPathComponent("lone.zip")
    try "x".write(to: loneZip, atomically: true, encoding: .utf8)
    expectEqual(ArchiveFormat.detect(url: loneZip), ArchiveFormat.zip, "无 z01 兄弟的 zip 仍是普通 zip")
    expectTrue(SplitVolumes.volumeInfo(of: URL(fileURLWithPath: "/x/x.z1")) == nil, "单位序号不识别")
    expectTrue(SplitVolumes.volumeInfo(of: URL(fileURLWithPath: "/x/x.z")) == nil, "无序号不识别")
    let zInfo = SplitVolumes.volumeInfo(of: dir.appendingPathComponent("data.z02"))
    expectTrue(
        zInfo?.style == .winZip && zInfo?.sequence == 2 && zInfo?.mergedFileName == "data.zip",
        "volumeInfo 解析 z02 (\(zInfo.map { "\($0.style) seq=\($0.sequence) merged=\($0.mergedFileName)" } ?? "nil"))"
    )

    // 入口一: 从 z01 解压。
    let out1 = work.appendingPathComponent("wz-out-1")
    _ = try ArchiveService.shared.extract(
        archive: dir.appendingPathComponent("data.z01"), destination: out1, reporter: NullProgressReporter()
    )
    expectEqual(try Data(contentsOf: out1.appendingPathComponent("payload.bin")), payload, "z01 入口解压字节一致")

    // 入口二: 从末卷 zip 解压。
    let out2 = work.appendingPathComponent("wz-out-2")
    _ = try ArchiveService.shared.extract(
        archive: dir.appendingPathComponent("data.zip"), destination: out2, reporter: NullProgressReporter()
    )
    expectEqual(try Data(contentsOf: out2.appendingPathComponent("payload.bin")), payload, "zip 末卷入口解压字节一致")
} catch {
    expectTrue(false, "WinZip 分卷异常: \(error)")
}

// MARK: - 15. 归档注释查看 / 编辑

print("归档注释")
do {
    let src = work.appendingPathComponent("cmt-src", isDirectory: true)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try "commented file".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

    let archive = work.appendingPathComponent("cmt.zip")
    try ZipWriter(options: .init(level: .fast, comment: "原始注释 ✅ v1"), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive)

    expectEqual(try ZipArchiveEditor.comment(of: archive), "原始注释 ✅ v1", "读取创建时注释")

    // 重写注释 → 条目与注释同存。
    try ZipArchiveEditor.setComment("更新后的注释 v2", on: archive)
    expectEqual(try ZipArchiveEditor.comment(of: archive), "更新后的注释 v2", "重写注释生效")
    let names = try ZipReader(archiveURL: archive).listEntries().map { $0.name }
    expectTrue(names.contains { $0.hasSuffix("f.txt") }, "注释重写后条目完好")

    // 编辑 (删除条目) 后注释保留。
    _ = try ZipArchiveEditor.delete(paths: ["cmt-src/f.txt"], from: archive, reporter: NullProgressReporter())
    expectEqual(try ZipArchiveEditor.comment(of: archive), "更新后的注释 v2", "编辑后注释保留")

    // 清除注释。
    try ZipArchiveEditor.setComment("", on: archive)
    expectEqual(try ZipArchiveEditor.comment(of: archive), "", "清除注释")

    // 系统 unzip 接受注释重写后的包。
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-t", "-qq", archive.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try unzip.run(); unzip.waitUntilExit()
    expectTrue(unzip.terminationStatus == 0, "unzip 接受注释重写后的包")
} catch {
    expectTrue(false, "归档注释异常: \(error)")
}

// MARK: - 16. 自定义排除规则

print("自定义排除规则")
do {
    let src = work.appendingPathComponent("excl-src", isDirectory: true)
    try fm.createDirectory(at: src.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
    try fm.createDirectory(at: src.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try fm.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
    try "log".write(to: src.appendingPathComponent("a.log"), atomically: true, encoding: .utf8)
    try "keep".write(to: src.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
    try "js".write(to: src.appendingPathComponent("node_modules/pkg/x.js"), atomically: true, encoding: .utf8)
    try "md".write(to: src.appendingPathComponent("docs/readme.md"), atomically: true, encoding: .utf8)
    try "txt".write(to: src.appendingPathComponent("docs/guide.txt"), atomically: true, encoding: .utf8)
    try "o".write(to: src.appendingPathComponent("build/a.o"), atomically: true, encoding: .utf8)

    let archive = work.appendingPathComponent("excl.zip")
    try ZipWriter(
        options: .init(level: .store, excludePatterns: ["*.log", "NODE_MODULES", "docs/*.md"]),
        reporter: NullProgressReporter()
    ).write(inputs: [src], to: archive)

    let names = try ZipReader(archiveURL: archive).listEntries().map { $0.name }
    expectTrue(!names.contains { $0.hasSuffix("a.log") }, "排除 *.log (大小写不敏感)")
    expectTrue(!names.contains { $0.contains("node_modules") }, "排除 node_modules 整棵子树 (大小写不敏感)")
    expectTrue(!names.contains { $0.hasSuffix("readme.md") }, "排除 docs/*.md")
    expectTrue(names.contains { $0.hasSuffix("keep.txt") }, "保留 keep.txt")
    expectTrue(names.contains { $0.hasSuffix("guide.txt") }, "保留 docs/guide.txt")
    expectTrue(names.contains { $0.hasSuffix("a.o") }, "保留 build/a.o")

    // 目录前缀语义: "docs" 无斜杠 → 整棵剪枝。
    let archive2 = work.appendingPathComponent("excl2.zip")
    try ZipWriter(options: .init(level: .store, excludePatterns: ["docs"]), reporter: NullProgressReporter())
        .write(inputs: [src], to: archive2)
    let names2 = try ZipReader(archiveURL: archive2).listEntries().map { $0.name }
    expectTrue(!names2.contains { $0.contains("docs") }, "无斜杠规则剪枝 docs 子树")
    expectTrue(names2.contains { $0.hasSuffix("build/a.o") }, "其余保留")

    // 匹配器单元断言。
    expectTrue(ExcludeMatcher.matches(pattern: "build/*", relativePath: "build/a.o"), "build/* 命中直接子项")
    expectTrue(!ExcludeMatcher.matches(pattern: "docs/*.md", relativePath: "docs/sub/x.md"), "*/单段 不跨层")
    expectTrue(ExcludeMatcher.matches(pattern: "*.log", relativePath: "x/y/z.log"), "无斜杠规则命中任意层级")
    expectTrue(ExcludeMatcher.matches(pattern: "build", relativePath: "build"), "目录名精确命中")
} catch {
    expectTrue(false, "自定义排除规则异常: \(error)")
}

// MARK: - 17. 临时目录清扫与崩溃报告清理

print("临时目录清扫")
do {
    let dir = work.appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = dir.appendingPathComponent("MacZipPreview-OLD", isDirectory: true)
    try fm.createDirectory(at: old, withIntermediateDirectories: true)
    let fresh = dir.appendingPathComponent("MacZipPreview-NEW", isDirectory: true)
    try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
    let unrelated = dir.appendingPathComponent("OtherApp-OLD", isDirectory: true)
    try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
    let past = Date().addingTimeInterval(-2 * 3600)
    try fm.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
    try fm.setAttributes([.modificationDate: past], ofItemAtPath: unrelated.path)

    SharedStorageManager.shared.sweepOrphanedTempDirectories(in: dir, olderThan: 60)
    expectTrue(!fm.fileExists(atPath: old.path), "过期会话目录已清除")
    expectTrue(fm.fileExists(atPath: fresh.path), "新鲜会话目录保留 (防误删并发实例)")
    expectTrue(fm.fileExists(atPath: unrelated.path), "无关目录不误删")
}

print("崩溃报告清理")
do {
    let dir = work.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let retired = dir.appendingPathComponent("Retired", isDirectory: true)
    try fm.createDirectory(at: retired, withIntermediateDirectories: true)
    try "x".write(to: dir.appendingPathComponent("MacZip-2026-09-13.ips"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("OtherApp.ips"), atomically: true, encoding: .utf8)
    try "x".write(to: retired.appendingPathComponent("MacZip-2026-09-12.ips"), atomically: true, encoding: .utf8)

    let removed = SharedStorageManager.shared.clearCrashReports(in: dir)
    expectEqual(removed, 2, "删除本应用 2 份报告 (含 Retired 归档)")
    expectTrue(!fm.fileExists(atPath: dir.appendingPathComponent("MacZip-2026-09-13.ips").path), "本应用报告已删除")
    expectTrue(fm.fileExists(atPath: dir.appendingPathComponent("OtherApp.ips").path), "其他应用报告不误删")
}

// MARK: - SUMMARY

print("==================================================================")
print("SUMMARY: \(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}
exit(0)
