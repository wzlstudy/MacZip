import Foundation
import zlib

/// 设置键与默认值单一定义源 (设置页 / 引擎 / 扩展三方共用)。
public enum MacZipSettings {
    public static let defaultFormat = "default_compress_format"          // zip / tar.gz / 7z
    public static let compressionLevel = "compression_level"             // store / fast / standard / best
    public static let defaultVolumeSizeMB = "default_volume_size_mb"     // 0 = 不分卷
    public static let preferPasswordBook = "prefer_password_book"        // 解压自动试密码本
    public static let deleteArchiveAfterExtract = "delete_archive_after_extract"
    public static let conflictPolicy = "conflict_policy"                 // rename / overwrite / skip
    public static let openFolderAfterExtract = "open_folder_after_extract"
    public static let playSoundOnFinish = "play_sound_on_finish"
    public static let enableSuccessHUD = "enable_success_hud"
    public static let enableDebugLogging = "enable_debug_logging"
    public static let excludeSystemJunk = "exclude_system_junk"
    public static let solidSevenZip = "solid_sevenzip_default"
    public static let zipUseAES256 = "zip_use_aes256"                    // ZIP 加密用 AES-256 (默认 ZipCrypto)
    public static let verifyAfterCompress = "verify_after_compress"      // ZIP 压缩完成后自动完整性校验
    public static let excludePatterns = "exclude_patterns"               // 自定义排除规则 (每条一个 glob)
    public static let openArchiveAction = "open_archive_action"          // 双击打开压缩包: preview / extract
    public static let silentLaunch = "silent_launch"                      // 后台/自启启动时保持静默不弹窗
    public static let showCompressMenu = "show_compress_menu"            // 右键"压缩为"主项
    public static let showExtractMenu = "show_extract_menu"              // 右键"解压"主项
    public static let showAdvancedMenu = "show_advanced_menu"            // 右键"更多选项"子菜单

    private static let cachedDefaults: [String: Any] = [
        defaultFormat: "zip",
        compressionLevel: "standard",
        defaultVolumeSizeMB: 0,
        preferPasswordBook: true,
        deleteArchiveAfterExtract: false,
        conflictPolicy: "rename",
        openArchiveAction: "preview",
        silentLaunch: true,
        openFolderAfterExtract: false,
        playSoundOnFinish: true,
        enableSuccessHUD: true,
        enableDebugLogging: false,
            excludeSystemJunk: true,
            solidSevenZip: false,
            zipUseAES256: false,
            verifyAfterCompress: true,
            excludePatterns: [String](),
            showCompressMenu: true,
        showExtractMenu: true,
        showAdvancedMenu: true
    ]

    /// 默认值表 (记忆化:此表在读取回退路径上被高频取用,不缓存则每次重建字典)。
    public static func defaults() -> [String: Any] {
        cachedDefaults
    }
}

/// 跨进程共享存储:App Group 容器 + config.json + PendingActions 动作队列。
/// 主 App (非沙盒) 与 Finder 扩展 (沙盒) 通过该容器交换配置与右键动作。
public final class SharedStorageManager {
    public static let shared = SharedStorageManager()

    private let fm = FileManager.default
    private let configLock = NSLock()
    /// config.json 内存缓存:getBool/getString/getInt 是右键菜单 / 日志路径上的
    /// 高频调用,不缓存则每次都整读 + 解析 JSON。
    /// 失效判定 = 短 TTL + 文件戳 (mtime+size) 双重条件:stat 校验单次 30-70µs,
    /// 用 250ms TTL 摊薄,跨进程变更最多延迟一个 TTL 可见;写入方进程写后即时生效。
    private var cachedConfig: [String: Any]?
    private var cachedConfigStamp: (date: Date, size: Int)?
    private var lastStampCheck = Date.distantPast
    private let stampCheckInterval: TimeInterval = 0.25

    // MARK: - 容器与路径

    private let containerLock = NSLock()
    private var cachedSharedContainerURL: URL?

    /// App Group 容器。非沙盒宿主回退到固定 Group Containers 路径并确保存在。
    /// 解析结果按进程缓存:此路径被 config/密码本/日志/队列等所有存储访问高频引用,
    /// 而回退分支含 getpwuid + createDirectory 系统调用,不缓存则每次取路径都付费。
    public var sharedContainerURL: URL {
        containerLock.lock()
        defer { containerLock.unlock() }
        if let cached = cachedSharedContainerURL { return cached }
        let resolved: URL
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: MacZipConstants.appGroupIdentifier) {
            resolved = url
        } else {
            // 非沙盒进程 containerURL 可能返回 nil:按苹果布局手工定位。
            let home = getRealHomeDirectory()
            let url = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Group Containers", isDirectory: true)
                .appendingPathComponent(MacZipConstants.appGroupIdentifier, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            resolved = url
        }
        cachedSharedContainerURL = resolved
        return resolved
    }

    // 各存储路径一次性解析为存储属性:URL.appendingPathComponent 单次 ~20µs,
    // 这些属性被高频读写路径反复取用,不允许每次重新拼装。
    private var resolvedConfigURL: URL!
    private var resolvedPasswordBookURL: URL!
    private var resolvedHeartbeatURL: URL!
    private var resolvedPendingActionsDir: URL!
    private var resolvedInFlightActionsDir: URL!
    private var resolvedFailedActionsDir: URL!
    private var resolvedLogFileURL: URL!

    public var configURL: URL { resolvedConfigURL }
    public var passwordBookURL: URL { resolvedPasswordBookURL }
    public var extensionHeartbeatURL: URL { resolvedHeartbeatURL }
    public var pendingActionsDirectoryURL: URL { resolvedPendingActionsDir }
    public var inFlightActionsDirectoryURL: URL { resolvedInFlightActionsDir }
    public var failedActionsDirectoryURL: URL { resolvedFailedActionsDir }
    public var logFileURL: URL { resolvedLogFileURL }

    private init() {
        let container = sharedContainerURL
        resolvedConfigURL = container.appendingPathComponent("config.json")
        resolvedPasswordBookURL = container.appendingPathComponent("passwordbook.json")
        resolvedHeartbeatURL = container.appendingPathComponent("extension.heartbeat.json")
        resolvedPendingActionsDir = container.appendingPathComponent("PendingActions", isDirectory: true)
        resolvedInFlightActionsDir = container.appendingPathComponent("InFlightActions", isDirectory: true)
        resolvedFailedActionsDir = container.appendingPathComponent("FailedActions", isDirectory: true)
        resolvedLogFileURL = container.appendingPathComponent("maczip.log")
        for dir in [resolvedPendingActionsDir!, resolvedInFlightActionsDir!, resolvedFailedActionsDir!] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 获取沙盒外的真实用户 Home 目录 (扩展沙盒下 NSHomeDirectory 是容器路径)。
    private func getRealHomeDirectory() -> String {
        let pw = getpwuid(getuid())
        if let home = pw?.pointee.pw_dir {
            return FileManager.default.string(withFileSystemRepresentation: home, length: Int(strlen(home)))
        }
        return NSHomeDirectory()
    }

    public var isRunningInExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    // MARK: - config.json 读写

    /// config.json 当前文件戳;文件不存在时为稳定哨兵值,缺失态同样可被缓存。
    /// 用不抛异常的 fileExists 探测,避免缺失场景每次付出异常构造开销。
    private func configStampUnlocked() -> (date: Date, size: Int) {
        guard fm.fileExists(atPath: configURL.path) else { return (date: .distantPast, size: -1) }
        let attrs = try? fm.attributesOfItem(atPath: configURL.path)
        return (
            date: (attrs?[.modificationDate] as? Date) ?? .distantPast,
            size: (attrs?[.size] as? NSNumber)?.intValue ?? -1
        )
    }

    private func loadConfigUnlocked() -> [String: Any] {
        let now = Date()
        if let cache = cachedConfig, now.timeIntervalSince(lastStampCheck) < stampCheckInterval {
            return cache
        }
        let stamp = configStampUnlocked()
        if let cache = cachedConfig, let cached = cachedConfigStamp,
           cached.date == stamp.date, cached.size == stamp.size {
            lastStampCheck = now
            return cache
        }
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: resolvedConfigURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }
        cachedConfig = config
        cachedConfigStamp = stamp
        lastStampCheck = now
        return config
    }

    private func saveConfigUnlocked(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = resolvedConfigURL.deletingLastPathComponent()
            .appendingPathComponent(".config-\(UUID().uuidString).tmp")
        fm.createFile(atPath: tmpURL.path, contents: data)
        _ = try fm.replaceItemAt(resolvedConfigURL, withItemAt: tmpURL)
        cachedConfig = config
        cachedConfigStamp = configStampUnlocked()
        lastStampCheck = Date()
    }

    private func mutateConfig(_ mutation: (inout [String: Any]) -> Void) -> Bool {
        configLock.lock()
        defer { configLock.unlock() }
        var config = loadConfigUnlocked()
        mutation(&config)
        do {
            try saveConfigUnlocked(config)
            return true
        } catch {
            AppLog.error("config 写入失败: \(error.localizedDescription)", category: .core)
            return false
        }
    }

    public func getBool(forKey key: String, defaultValue: Bool) -> Bool {
        configLock.lock()
        defer { configLock.unlock() }
        let config = loadConfigUnlocked()
        return (config[key] as? Bool) ?? ((MacZipSettings.defaults()[key] as? Bool) ?? defaultValue)
    }

    public func setBool(_ value: Bool, forKey key: String) -> Bool {
        mutateConfig { $0[key] = value }
    }

    public func getString(forKey key: String, defaultValue: String) -> String {
        configLock.lock()
        defer { configLock.unlock() }
        let config = loadConfigUnlocked()
        return (config[key] as? String) ?? ((MacZipSettings.defaults()[key] as? String) ?? defaultValue)
    }

    public func setString(_ value: String, forKey key: String) -> Bool {
        mutateConfig { $0[key] = value }
    }

    public func getInt(forKey key: String, defaultValue: Int) -> Int {
        configLock.lock()
        defer { configLock.unlock() }
        let config = loadConfigUnlocked()
        return (config[key] as? Int) ?? ((MacZipSettings.defaults()[key] as? Int) ?? defaultValue)
    }

    public func setInt(_ value: Int, forKey key: String) -> Bool {
        mutateConfig { $0[key] = value }
    }

    public func getStringArray(forKey key: String, defaultValue: [String]) -> [String] {
        configLock.lock()
        defer { configLock.unlock() }
        let config = loadConfigUnlocked()
        return (config[key] as? [String]) ?? ((MacZipSettings.defaults()[key] as? [String]) ?? defaultValue)
    }

    public func setStringArray(_ value: [String], forKey key: String) -> Bool {
        mutateConfig { $0[key] = value }
    }

    /// 配置变更后广播 (扩展刷新菜单)。
    public func postConfigChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            MacZipConstants.configChangedSignal,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - 临时目录清扫与诊断数据清理

    /// 本应用产生的临时目录前缀 (正常由 defer / 会话结束清理;崩溃时残留)。
    private static let orphanedTempPrefixes = [
        "MacZipPreview-",   // 预览窗口会话目录
        "MacZip-staging-",  // 压缩分片装配区
        "MacZip-add-",      // 归档编辑暂存
        "MacZip-merge-",    // 分卷合并暂存
        "MacZip-targz-",    // tar.gz 预览解包
        "MacZip-dec-"       // (历史版本) 加密条目解密暂存
    ]

    /// 清理历史会话残留的临时目录 (应用启动时调用;单实例,启动时无并发会话)。
    public func sweepOrphanedTempDirectories() {
        sweepOrphanedTempDirectories(
            in: fm.temporaryDirectory,
            olderThan: 60
        )
    }

    /// 实现层 (可注入目录,供测试):删除名称匹配应用前缀、且超过 ageLimit 秒
    /// 未修改的目录。fresh 保留以防误删 (极端情况下的并发实例)。
    public func sweepOrphanedTempDirectories(in directory: URL, olderThan ageLimit: TimeInterval) {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return }
        let now = Date()
        for entry in entries {
            let name = entry.lastPathComponent
            guard Self.orphanedTempPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > ageLimit else { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// 清空运行日志 (删除文件,下次写入自动重建)。
    public func clearLogFile() {
        try? fm.removeItem(at: logFileURL)
    }

    /// 删除本应用的历史崩溃报告 (~/Library/Logs/DiagnosticReports/MacZip*.ips,
    /// 含系统轮转后的 Retired 归档)。返回删除的文件数。
    @discardableResult
    public func clearCrashReports() -> Int {
        let reportsDir = URL(fileURLWithPath: getRealHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return clearCrashReports(in: reportsDir)
    }

    /// 实现层 (可注入目录,供测试)。
    func clearCrashReports(in directory: URL) -> Int {
        var removed = 0
        let targets = [directory, directory.appendingPathComponent("Retired", isDirectory: true)]
        for target in targets {
            guard let files = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) else { continue }
            for file in files
            where file.lastPathComponent.hasPrefix("MacZip") && file.pathExtension == "ips" {
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: - 日志

    public func writeLog(_ message: String, level: SharedLogLevel = .info) {
        switch level {
        case .info: AppLog.info(message, category: .core)
        case .debug: AppLog.debug(message, category: .core)
        case .error: AppLog.error(message, category: .core)
        }
        // 统一落一份文本日志,便于用户在"高级"页一键打开排查。
        let debugEnabled = isDebugLoggingEnabledDisk
        guard level != .debug || debugEnabled else { return }
        let line = "\(DateFormatter.logTimestamp.string(from: Date())) [\(level.rawValue)] \(message)\n"
        // 体积上限:超过 4MB 直接重建,避免日志无限增长占用磁盘。
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? Int, size > 4 * 1024 * 1024 {
            try? fm.removeItem(at: logFileURL)
        }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
            _ = try? handle.close()
        } else {
            fm.createFile(atPath: logFileURL.path, contents: Data(line.utf8))
        }
    }

    /// 调试日志开关 (自带 TTL + 文件戳缓存)。writeLog 每写一行都会查此开关,
    /// 必须缓存;且刻意不经 configLock——若未来有人在持 configLock 的路径上调用
    /// writeLog,两把独立锁不会构成嵌套死锁。
    private let debugFlagLock = NSLock()
    private var debugFlagStamp: (date: Date, size: Int)?
    private var debugFlagCached = false
    private var debugFlagCheckedAt = Date.distantPast

    private var isDebugLoggingEnabledDisk: Bool {
        debugFlagLock.lock()
        defer { debugFlagLock.unlock() }
        let now = Date()
        if let _ = debugFlagStamp, now.timeIntervalSince(debugFlagCheckedAt) < stampCheckInterval {
            return debugFlagCached
        }
        guard fm.fileExists(atPath: resolvedConfigURL.path) else {
            debugFlagStamp = (date: .distantPast, size: -1)
            debugFlagCached = false
            debugFlagCheckedAt = now
            return false
        }
        let attrs = try? fm.attributesOfItem(atPath: resolvedConfigURL.path)
        let stamp = (
            date: (attrs?[.modificationDate] as? Date) ?? .distantPast,
            size: (attrs?[.size] as? NSNumber)?.intValue ?? -1
        )
        if let cached = debugFlagStamp, cached.date == stamp.date, cached.size == stamp.size {
            debugFlagCheckedAt = now
            return debugFlagCached
        }
        var value = false
        if let data = try? Data(contentsOf: resolvedConfigURL),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value = (config[MacZipSettings.enableDebugLogging] as? Bool) ?? false
        }
        debugFlagStamp = stamp
        debugFlagCached = value
        debugFlagCheckedAt = now
        return value
    }

    // MARK: - PendingActions 动作队列 (Extension → 主 App)

    /// 扩展写入一个动作事件,返回事件文件 URL。
    public func enqueueAction(
        actionId: String,
        paths: [String],
        extra: [String: Any] = [:]
    ) throws -> URL {
        try fm.createDirectory(at: pendingActionsDirectoryURL, withIntermediateDirectories: true)
        var payload: [String: Any] = [
            "id": UUID().uuidString,
            "actionId": actionId,
            "paths": paths,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let url = pendingActionsDirectoryURL
            .appendingPathComponent("action-\(UUID().uuidString).json")
        // 先写临时文件再 rename,保证读取端只见完整 JSON。
        let tmpURL = pendingActionsDirectoryURL
            .appendingPathComponent(".pending-\(UUID().uuidString).tmp")
        fm.createFile(atPath: tmpURL.path, contents: data)
        try fm.moveItem(at: tmpURL, to: url)
        return url
    }

    /// 租约:事件文件被搬到 InFlight/<pid>/,动作终态后 ack 删除。
    public struct PendingActionLease {
        public var event: SharedActionEvent
        public var inFlightURL: URL
    }

    /// 以租约形式取走全部待处理动作 (原子 rename,崩溃可回收)。
    public func consumePendingActionLeases() -> [PendingActionLease] {
        var leases: [PendingActionLease] = []
        guard let files = try? fm.contentsOfDirectory(
            at: pendingActionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return leases }

        let inFlightDir = inFlightActionsDirectoryURL
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.createDirectory(at: inFlightDir, withIntermediateDirectories: true)

        for file in files where file.lastPathComponent.hasPrefix("action-") {
            do {
                let data = try Data(contentsOf: file)
                let event = try JSONDecoder().decode(SharedActionEvent.self, from: data)
                let inFlightURL = inFlightDir.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: inFlightURL.path) {
                    try fm.removeItem(at: inFlightURL)
                }
                try fm.moveItem(at: file, to: inFlightURL)
                leases.append(PendingActionLease(event: event, inFlightURL: inFlightURL))
            } catch {
                // 防竞态:文件刚落盘 (≤2s) 却解析失败,多半是写入方尚未写完 (非原子写)。
                // 留在队列等下一轮 drain;老文件才判废进 FailedActions。
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(modified) < 2.0 {
                    continue
                }
                AppLog.error("动作事件解析失败: \(error.localizedDescription)", category: .core)
                writeLog("[Storage] 动作事件解析失败 (\(file.lastPathComponent)): \(error.localizedDescription)", level: .error)
                try? fm.moveItem(at: file, to: failedActionsDirectoryURL.appendingPathComponent(file.lastPathComponent))
            }
        }
        return leases
    }

    /// 动作终态后确认删除租约文件。
    public func acknowledge(_ lease: PendingActionLease) {
        try? fm.removeItem(at: lease.inFlightURL)
    }

    /// 启动时回收:上次进程崩溃遗留在 InFlight/<pid>/ 的孤儿搬回 PendingActions。
    public func reclaimAbandonedInFlightActions() {
        reclaimAbandonedInFlightActions { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
    }

    public func reclaimAbandonedInFlightActions(processIsAlive: (Int32) -> Bool) {
        guard let owners = try? fm.contentsOfDirectory(
            at: inFlightActionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for owner in owners {
            let ownerName = owner.lastPathComponent
            guard let pid = Int32(ownerName) else { continue }
            if processIsAlive(pid) { continue }
            let orphans = (try? fm.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil, options: [])) ?? []
            for orphan in orphans {
                let destination = pendingActionsDirectoryURL.appendingPathComponent(orphan.lastPathComponent)
                try? fm.moveItem(at: orphan, to: destination)
            }
            try? fm.removeItem(at: owner)
        }
    }

    public var pendingActionCount: Int {
        let files = (try? fm.contentsOfDirectory(
            at: pendingActionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("action-") }.count
    }

    // MARK: - 扩展心跳

    public func writeHeartbeat(observedPathCount: Int, version: String, processID: Int32) {
        let payload: [String: Any] = [
            "observedPathCount": observedPathCount,
            "version": version,
            "pid": Int(processID),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        let tmpURL = sharedContainerURL.appendingPathComponent(".heartbeat-\(UUID().uuidString).tmp")
        fm.createFile(atPath: tmpURL.path, contents: data)
        _ = try? fm.replaceItemAt(extensionHeartbeatURL, withItemAt: tmpURL)
    }

    public struct HeartbeatInfo: Codable {
        var observedPathCount: Int
        var version: String
        var pid: Int
        var updatedAt: String

        var updatedDate: Date? {
            ISO8601DateFormatter().date(from: updatedAt)
        }
    }

    public func readHeartbeat() -> HeartbeatInfo? {
        guard let data = try? Data(contentsOf: extensionHeartbeatURL) else { return nil }
        return try? JSONDecoder().decode(HeartbeatInfo.self, from: data)
    }
}

/// 共享日志级别。
public enum SharedLogLevel: String {
    case info
    case debug
    case error
}

/// Extension → 主 App 的动作事件模型。
public struct SharedActionEvent: Codable, Equatable {
    public var id: String
    public var actionId: String
    public var paths: [String]
    public var createdAt: String
    /// 用户在弹窗里输入的密码 (加密压缩等动作回传)。
    public var password: String?
    /// 分卷大小 (MB),分卷压缩动作回传。
    public var volumeSizeMB: Int?
}

extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
