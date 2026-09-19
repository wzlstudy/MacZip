import Foundation

/// 右键动作分类 (设置页分组用)。
public enum ArchiveActionCategory: String, Codable, CaseIterable, Identifiable {
    case compress
    case extract

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .compress: return "压缩"
        case .extract: return "解压"
        }
    }
}

/// 动作调用场景。
public enum ActionInvocationKind: String, Codable, Equatable {
    case items       // 右键选中项
    case container   // 右键空白背景
}

/// 动作完成状态。
public enum ActionCompletionStatus: Equatable {
    case succeeded
    case failed(message: String?)
    case cancelled
}

/// 统一的右键动作抽象。
public protocol ArchiveMenuAction {
    /// 唯一标识符,用于分发与配置存储。
    var actionId: String { get }
    /// 右键菜单标题 (支持 "%@" 占位符,由扩展按目标名格式化)。
    var titleTemplate: String { get }
    /// SF Symbol 图标名。
    var iconName: String { get }
    var category: ArchiveActionCategory { get }
    /// 是否默认在右键菜单显示。
    var isEnabledByDefault: Bool { get }
    /// 依赖外部 7-Zip 时为 true;不可用则自动隐藏。
    var requiresSevenZip: Bool { get }
    /// 是否需要用户输入密码 (弹窗)。
    var requiresPasswordPrompt: Bool { get }
    /// 是否需要用户选择分卷大小 (弹窗)。
    var requiresVolumePrompt: Bool { get }
    /// 该动作在当前选中目标上是否可用。
    func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool
}

public extension ArchiveMenuAction {
    var isEnabledByDefault: Bool { true }
    var requiresSevenZip: Bool { false }
    var requiresPasswordPrompt: Bool { false }
    var requiresVolumePrompt: Bool { false }
}

/// 内建动作注册表 (MacZip 19 项右键能力的核心子集,全部可独立关闭)。
public enum DefaultActionRegistry {
    /// 压缩为 "<名称>.<默认格式>" — 顶层主项。
    public struct CompressDefault: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.default" }
        public var titleTemplate: String { "压缩为 \"%@\"" }
        public var iconName: String { "doc.zipper" }
        public var category: ArchiveActionCategory { .compress }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
            !targetURLs.isEmpty
        }
    }

    public struct CompressZip: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.zip" }
        public var titleTemplate: String { "压缩为 ZIP" }
        public var iconName: String { "doc.zipper" }
        public var category: ArchiveActionCategory { .compress }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    public struct CompressTarGz: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.targz" }
        public var titleTemplate: String { "压缩为 TAR.GZ" }
        public var iconName: String { "doc.zipper" }
        public var category: ArchiveActionCategory { .compress }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    public struct CompressSevenZip: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.7z" }
        public var titleTemplate: String { "压缩为 7Z" }
        public var iconName: String { "doc.zipper" }
        public var category: ArchiveActionCategory { .compress }
        public var requiresSevenZip: Bool { true }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    public struct CompressEncrypted: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.encrypted" }
        public var titleTemplate: String { "加密压缩…" }
        public var iconName: String { "lock.shield" }
        public var category: ArchiveActionCategory { .compress }
        public var requiresPasswordPrompt: Bool { true }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    public struct CompressVolumed: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.volumed" }
        public var titleTemplate: String { "分卷压缩…" }
        public var iconName: String { "square.split.2x1" }
        public var category: ArchiveActionCategory { .compress }
        public var requiresVolumePrompt: Bool { true }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    public struct CompressSolid: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.compress.solid" }
        public var titleTemplate: String { "固实压缩为 7Z" }
        public var iconName: String { "square.stack.3d.up" }
        public var category: ArchiveActionCategory { .compress }
        public var requiresSevenZip: Bool { true }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool { !targetURLs.isEmpty }
    }

    /// 解压到当前位置 — 顶层主项。
    public struct ExtractHere: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.extract.here" }
        public var titleTemplate: String { "解压到当前位置" }
        public var iconName: String { "arrow.down.right.square" }
        public var category: ArchiveActionCategory { .extract }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
            !isContainer && targetURLs.allSatisfy(Self.isArchive)
        }
        /// 所有格式 (含分卷首段) 的统一判定入口。
        static func isArchive(_ url: URL) -> Bool {
            ArchiveFormat.isArchiveFile(at: url)
        }
    }

    /// 解压到 "<名称>/" 子文件夹。
    public struct ExtractSubfolder: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.extract.subfolder" }
        public var titleTemplate: String { "解压到 \"%@\"" }
        public var iconName: String { "folder.badge.plus" }
        public var category: ArchiveActionCategory { .extract }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
            !isContainer && targetURLs.count == 1 && DefaultActionRegistry.ExtractHere.isArchive(targetURLs[0])
        }
    }

    /// 解压到… (用户选择目录)。
    public struct ExtractTo: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.extract.to" }
        public var titleTemplate: String { "解压到…" }
        public var iconName: String { "square.and.arrow.down.on.square" }
        public var category: ArchiveActionCategory { .extract }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
            !isContainer && !targetURLs.isEmpty && targetURLs.allSatisfy(ExtractHere.isArchive)
        }
    }

    /// 测试压缩包完整性。
    public struct TestArchive: ArchiveMenuAction {
        public init() {}
        public var actionId: String { "maczip.action.test" }
        public var titleTemplate: String { "测试压缩包完整性" }
        public var iconName: String { "checkmark.seal" }
        public var category: ArchiveActionCategory { .extract }
        public func isAvailable(for targetURLs: [URL], isContainer: Bool) -> Bool {
            !isContainer && !targetURLs.isEmpty && targetURLs.allSatisfy(ExtractHere.isArchive)
        }
    }

    /// 全部内建动作 (顺序即菜单默认顺序)。
    public static func allActions() -> [ArchiveMenuAction] {
        [
            CompressDefault(),
            CompressZip(),
            CompressTarGz(),
            CompressSevenZip(),
            CompressEncrypted(),
            CompressVolumed(),
            CompressSolid(),
            ExtractHere(),
            ExtractSubfolder(),
            ExtractTo(),
            TestArchive()
        ]
    }
}

/// 动作分发器:扩展与主 App 共用的查询门面。
public final class ActionDispatcher {
    public static let shared = ActionDispatcher()

    public private(set) var allActions: [ArchiveMenuAction]
    /// 动作 ID → 启用状态缓存 (主进程写入,扩展进程读取)。
    private var enabledStates: [String: Bool] = [:]

    public init(actions: [ArchiveMenuAction] = DefaultActionRegistry.allActions()) {
        allActions = actions
        preheat()
    }

    public func preheat() {
        let keys = allActions.map { "action_enabled." + $0.actionId }
        for key in keys {
            let stored = SharedStorageManager.shared.getBool(forKey: key, defaultValue: true)
            enabledStates[key] = stored
        }
    }

    public func action(forId actionId: String) -> ArchiveMenuAction? {
        allActions.first { $0.actionId == actionId }
    }

    public func isEnabled(_ actionId: String) -> Bool {
        let key = "action_enabled." + actionId
        if let cached = enabledStates[key] { return cached }
        let stored = SharedStorageManager.shared.getBool(forKey: key, defaultValue: true)
        enabledStates[key] = stored
        return stored
    }

    public func setEnabled(_ enabled: Bool, for actionId: String) -> Bool {
        let key = "action_enabled." + actionId
        guard SharedStorageManager.shared.setBool(enabled, forKey: key) else { return false }
        enabledStates[key] = enabled
        return true
    }

    /// 依据 7z 可用性过滤动作 (压缩菜单降级)。
    public func availableActions(for targetURLs: [URL], isContainer: Bool) -> [ArchiveMenuAction] {
        allActions.filter { action in
            guard isEnabled(action.actionId) else { return false }
            if action.requiresSevenZip && !ExternalArchiver.shared.isSevenZipAvailable { return false }
            return action.isAvailable(for: targetURLs, isContainer: isContainer)
        }
    }
}
