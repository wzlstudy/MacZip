import Foundation

/// 密码本条目 (FastZip "密码本" 功能):存档后解压加密包时自动匹配。
public struct PasswordEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    /// 备注名 (如 "公司打包" / "张三的压缩包")。
    public var title: String
    public var password: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, password: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.password = password
        self.createdAt = createdAt
    }
}

/// 密码本存储:JSON 落盘于 App Group 容器,权限 0600。
/// 多进程并发写通过「临时文件 + 原子 rename」避免撕裂。
public final class PasswordBook {
    public static let shared = PasswordBook()

    private let fm = FileManager.default
    private let lock = NSLock()
    private let storageURL: URL
    /// 密码本内存缓存:解压与预览选中都会读 passwords,不缓存则每次都整读 +
    /// 解析 JSON。失效判定 = 短 TTL + 文件戳 (mtime+size);写入后本进程即时生效,
    /// 跨进程变更最多延迟一个 TTL 可见。
    private var cachedEntries: [PasswordEntry]?
    private var cachedStamp: (date: Date, size: Int)?
    private var lastStampCheck = Date.distantPast
    private let stampCheckInterval: TimeInterval = 0.25

    public init(sharedContainerURL: URL? = nil) {
        let container = sharedContainerURL
            ?? SharedStorageManager.shared.sharedContainerURL
        storageURL = container.appendingPathComponent("passwordbook.json")
    }

    // MARK: - 读取 / 写入

    public func entries() -> [PasswordEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    /// 追加一条;成功返回 true。
    @discardableResult
    public func add(_ entry: PasswordEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        all.append(entry)
        return saveUnlocked(all)
    }

    @discardableResult
    public func update(_ entry: PasswordEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        guard let index = all.firstIndex(where: { $0.id == entry.id }) else { return false }
        all[index] = entry
        return saveUnlocked(all)
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = loadUnlocked()
        let before = all.count
        all.removeAll { $0.id == id }
        guard all.count != before else { return false }
        return saveUnlocked(all)
    }

    public var passwords: [String] {
        entries().map { $0.password }
    }

    public var count: Int {
        entries().count
    }

    // MARK: - 持久化

    private func changeStamp() -> (date: Date, size: Int) {
        guard fm.fileExists(atPath: storageURL.path) else { return (date: .distantPast, size: -1) }
        let attrs = try? fm.attributesOfItem(atPath: storageURL.path)
        return (
            date: (attrs?[.modificationDate] as? Date) ?? .distantPast,
            size: (attrs?[.size] as? NSNumber)?.intValue ?? -1
        )
    }

    private func loadUnlocked() -> [PasswordEntry] {
        let now = Date()
        if let _ = cachedStamp, now.timeIntervalSince(lastStampCheck) < stampCheckInterval,
           let cached = cachedEntries {
            return cached
        }
        let stamp = changeStamp()
        if let cached = cachedEntries, let cachedStamp = cachedStamp,
           cachedStamp.date == stamp.date, cachedStamp.size == stamp.size {
            lastStampCheck = now
            return cached
        }
        var entries: [PasswordEntry] = []
        if let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([PasswordEntry].self, from: data)) ?? []
        }
        cachedEntries = entries
        cachedStamp = stamp
        lastStampCheck = now
        return entries
    }

    private func saveUnlocked(_ entries: [PasswordEntry]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            let tmpURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent(".passwordbook-\(UUID().uuidString).tmp")
            fm.createFile(atPath: tmpURL.path, contents: data)
            // 0600:仅属主可读写 (密码本安全底线)。
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            _ = try fm.replaceItemAt(storageURL, withItemAt: tmpURL)
            cachedEntries = entries
            cachedStamp = changeStamp()
            lastStampCheck = Date()
            return true
        } catch {
            AppLog.error("密码本写入失败: \(error.localizedDescription)", category: .core)
            return false
        }
    }
}
