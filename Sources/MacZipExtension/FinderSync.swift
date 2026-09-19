import Cocoa
import FinderSync
import Darwin

// MARK: - FinderSync 主插件 (MacZip 右键压缩/解压入口)

@objc(FinderSync)
class FinderSync: FIFinderSync {
    /// 菜单动作与整数 tag 的双向映射 (避免 representedObject 依赖)。
    private struct MenuSelection: Equatable {
        let actionId: String
        let invocationKind: ActionInvocationKind
        /// 菜单渲染时格式化的标题 (如 压缩为 "xxx.zip"),点击时以 tag 反查回填。
        let formattedTitle: String
    }

    private static var tagToSelection: [Int: MenuSelection] = [:]
    private static var nextTag: Int = 1000

    /// 菜单 tag 映射按次重建:扩展进程长驻,不清理会随右键次数无限增长。
    private static func resetMenuTags() {
        tagToSelection.removeAll()
    }

    // MARK: - 心跳限频

    private static let heartbeatLock = NSLock()
    private static var lastHeartbeatAt = Date.distantPast
    /// 菜单渲染是高频路径,心跳文件写盘限频到分钟级 (updateObservedDirectories
    /// 的状态变更心跳不受此限,立即写)。
    private static let heartbeatInterval: TimeInterval = 60

    private func writeHeartbeatThrottled(observedPathCount: Int) {
        var due = false
        Self.heartbeatLock.lock()
        if Date().timeIntervalSince(Self.lastHeartbeatAt) >= Self.heartbeatInterval {
            Self.lastHeartbeatAt = Date()
            due = true
        }
        Self.heartbeatLock.unlock()
        if due {
            writeHeartbeat(observedPathCount: observedPathCount)
        }
    }

    private static func getTag(for selection: MenuSelection) -> Int {
        if let existing = tagToSelection.first(where: { $0.value == selection })?.key {
            return existing
        }
        let tag = nextTag
        tagToSelection[tag] = selection
        nextTag += 1
        return tag
    }

    private static func selection(for tag: Int) -> MenuSelection? {
        tagToSelection[tag]
    }

    override init() {
        super.init()
        log("插件初始化启动...")

        // 1. 注册监控目录 (Desktop/Documents/Downloads/Home/Volumes)。
        updateObservedDirectories()

        // 2. 注册主 App 是状态栏图标与设置面板宿主;用户强退后可由此拉回。
        Self.ensureHostRunning()

        // 3. 监听主 App 的配置变更 (菜单开关/格式变化),立即重建菜单缓存。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(configChanged),
            name: MacZipConstants.configChangedSignal,
            object: nil
        )

        // 4. 预热:启用状态与 7z 可用性一次性读入,避免右键瞬间同步 IO。
        ActionDispatcher.shared.preheat()
        _ = ExternalArchiver.shared.isSevenZipAvailable

        log("初始化完成,7z 可用: \(ExternalArchiver.shared.isSevenZipAvailable)")
    }

    // MARK: - 菜单点击 → 写队列 → 通知主 App

    @objc func actionMenuItemSelected(_ sender: NSMenuItem) {
        let tag = sender.tag
        log("收到菜单点击事件, Tag: \(tag), title: \(sender.title)")
        guard let selection = FinderSync.selection(for: tag) else {
            log("错误: 无法根据 Tag \(tag) 反查动作")
            return
        }

        let controller = FIFinderSyncController.default()
        let targets: [URL]
        switch selection.invocationKind {
        case .items: targets = controller.selectedItemURLs() ?? []
        case .container: targets = controller.targetedURL().map { [$0] } ?? []
        }
        guard !targets.isEmpty else {
            log("错误: 系统返回选中路径为空")
            return
        }

        do {
            _ = try SharedStorageManager.shared.enqueueAction(
                actionId: selection.actionId,
                paths: targets.map { $0.path }
            )
            log("已入队动作 \(selection.actionId), 目标 \(targets.count) 个")
        } catch {
            log("写入动作队列失败: \(error.localizedDescription)")
            return
        }

        // 分布式空信号唤醒主 App 消费队列。
        DistributedNotificationCenter.default().postNotificationName(
            MacZipConstants.triggerActionSignal,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        Self.ensureHostRunning()
    }

    // MARK: - 监控目录

    override func requestBadgeIdentifier(for url: URL) {}

    private func getRealHomeDirectory() -> String {
        let pw = getpwuid(getuid())
        if let home = pw?.pointee.pw_dir {
            return FileManager.default.string(withFileSystemRepresentation: home, length: Int(strlen(home)))
        }
        return NSHomeDirectory()
    }

    private func updateObservedDirectories() {
        var observedURLs: Set<URL> = []
        let home = getRealHomeDirectory()
        // 监控用户主域常用目录 (与 FastZip 一致的默认覆盖面):
        // 桌面 / 文稿 / 下载 / 全部挂载卷根。fileExists 过滤会误伤受保护目录,故不校验可读性。
        let defaults = ["Desktop", "Documents", "Downloads"]
        for folder in defaults {
            let url = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(folder, isDirectory: true)
            observedURLs.insert(url.standardizedFileURL)
        }
        if let homeURL = URL(string: "file://" + home.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
            observedURLs.insert(homeURL)
        }
        // 挂载卷 (U 盘 / 移动硬盘)。
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        observedURLs.insert(volumes)

        FIFinderSyncController.default().directoryURLs = observedURLs
        writeHeartbeat(observedPathCount: observedURLs.count)
        log("监控目录注册成功,当前激活数量: \(observedURLs.count)")
    }

    private func writeHeartbeat(observedPathCount: Int) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        SharedStorageManager.shared.writeHeartbeat(
            observedPathCount: observedPathCount,
            version: version,
            processID: ProcessInfo.processInfo.processIdentifier
        )
    }

    @objc private func configChanged() {
        log("收到配置变更,刷新菜单缓存")
        ActionDispatcher.shared.preheat()
        updateObservedDirectories()
        let currentURLs = FIFinderSyncController.default().directoryURLs
        FIFinderSyncController.default().directoryURLs = currentURLs
    }

    // MARK: - 核心:动态渲染右键菜单 (FastZip 风格)

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        Self.resetMenuTags()
        writeHeartbeatThrottled(observedPathCount: FIFinderSyncController.default().directoryURLs.count)

        let targetURLs: [URL]
        let invocationKind: ActionInvocationKind
        if menuKind == .contextualMenuForItems {
            targetURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
            invocationKind = .items
        } else {
            targetURLs = FIFinderSyncController.default().targetedURL().map { [$0] } ?? []
            invocationKind = .container
        }
        guard !targetURLs.isEmpty else { return nil }

        let isContainer = invocationKind == .container
        let dispatcher = ActionDispatcher.shared
        let available = dispatcher.availableActions(for: targetURLs, isContainer: isContainer)
        guard !available.isEmpty else { return nil }

        let menu = NSMenu(title: MacZipConstants.appName)

        // FastZip 菜单结构:
        //   压缩为 "<名称>.<格式>"     (顶层主项)
        //   解压…                       (有压缩包时顶层主项)
        //   ─────────
        //   更多压缩选项 ▸  ZIP / TAR.GZ / 7Z / 加密压缩… / 分卷压缩… / 固实压缩
        //   更多解压选项 ▸  解压到 "<名称>/" / 解压到… / 测试压缩包
        let settings = MenuSettingsSnapshot()

        let primaryCompress = available.first { $0.actionId == "maczip.action.compress.default" }
        if settings.showCompressMenu, let compress = primaryCompress {
            let archiveName = Self.defaultArchiveName(for: targetURLs, format: settings.defaultFormat)
            let title = compress.titleTemplate.replacingOccurrences(
                of: "%@",
                with: archiveName
            )
            menu.addItem(makeItem(
                action: compress, title: title, invocationKind: invocationKind
            ))
        }

        var primaryExtractActionId: String?
        if settings.showExtractMenu,
           let extractHere = available.first(where: { $0.actionId == "maczip.action.extract.here" }) {
            if !isContainer, let single = targetURLs.first, targetURLs.count == 1,
               let subfolder = available.first(where: { $0.actionId == "maczip.action.extract.subfolder" }),
               subfolder.isAvailable(for: targetURLs, isContainer: isContainer) {
                let folderName = (single.lastPathComponent as NSString).deletingPathExtension
                let title = subfolder.titleTemplate.replacingOccurrences(of: "%@", with: "\(folderName)/")
                menu.addItem(makeItem(action: subfolder, title: title, invocationKind: invocationKind))
                primaryExtractActionId = subfolder.actionId
            } else {
                menu.addItem(makeItem(
                    action: extractHere, title: extractHere.titleTemplate, invocationKind: invocationKind
                ))
                primaryExtractActionId = extractHere.actionId
            }
        }

        let hasPrimary = menu.items.count > 0
        let compressExtras = available.filter {
            ["maczip.action.compress.zip", "maczip.action.compress.targz",
             "maczip.action.compress.7z", "maczip.action.compress.encrypted",
             "maczip.action.compress.volumed", "maczip.action.compress.solid"]
                .contains($0.actionId)
        }
        let extractExtras = available.filter {
            ["maczip.action.extract.here", "maczip.action.extract.subfolder",
             "maczip.action.extract.to", "maczip.action.test"].contains($0.actionId)
                && $0.actionId != primaryExtractActionId
        }

        if settings.showAdvancedMenu && (!compressExtras.isEmpty || !extractExtras.isEmpty) {
            // 注意:与 MacRightClick 一致,扩展菜单内不插入 NSMenuItem.separator()——
            // 分隔符在 Finder 扩展菜单中会渲染成一条空白行(视觉上是大段空隙),
            // 分组感靠"主项在前、子菜单在后"的排序表达。
            _ = hasPrimary

            if !compressExtras.isEmpty {
                let parent = NSMenuItem(title: "更多压缩选项", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "更多压缩选项")
                for action in compressExtras {
                    submenu.addItem(makeItem(
                        action: action, title: action.titleTemplate, invocationKind: invocationKind
                    ))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
            if !extractExtras.isEmpty {
                let parent = NSMenuItem(title: "更多解压选项", action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: "更多解压选项")
                for action in extractExtras {
                    var title = action.titleTemplate
                    if action.actionId == "maczip.action.extract.subfolder",
                       let single = targetURLs.first, targetURLs.count == 1 {
                        let folderName = (single.lastPathComponent as NSString).deletingPathExtension
                        title = title.replacingOccurrences(of: "%@", with: "\(folderName)/")
                    }
                    submenu.addItem(makeItem(action: action, title: title, invocationKind: invocationKind))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }

        guard !menu.items.isEmpty else { return nil }

        // 保持 Finder 右键菜单中的直接操作项,不额外增加 MacZip 子菜单层级。
        log("菜单渲染完毕,MacZip 菜单项: \(menu.items.count)")
        return menu
    }

    private func makeItem(
        action: ArchiveMenuAction,
        title: String,
        invocationKind: ActionInvocationKind
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(actionMenuItemSelected(_:)), keyEquivalent: "")
        let selection = MenuSelection(
            actionId: action.actionId,
            invocationKind: invocationKind,
            formattedTitle: title
        )
        item.tag = FinderSync.getTag(for: selection)
        item.target = self
        item.image = NSImage(systemSymbolName: action.iconName, accessibilityDescription: nil)
        return item
    }

    /// 依据选中目标推断默认压缩产物名 (FastZip 行为)。
    static func defaultArchiveName(for targets: [URL], format: String) -> String {
        return "\(ArchiveService.defaultArchiveBaseName(for: targets)).\(format)"
    }

    private func log(_ message: String) {
        AppLog.info("[FinderSync] \(message)", category: .ext)
        SharedStorageManager.shared.writeLog("[FinderSync] \(message)")
    }

    // MARK: - 拉起主 App

    static func ensureHostRunning() {
        let hostBundleID = MacZipConstants.appBundleIdentifier
        let isHostRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == hostBundleID
        }
        guard !isHostRunning else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hostBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        configuration.activates = false
        // 后台拉起标志:主 App 据此保持静默 (用户从启动台/访达手动启动时才弹设置窗口)。
        configuration.arguments = ["--background"]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

// MARK: - 菜单设置快照 (渲染前一次性读取)

struct MenuSettingsSnapshot {
    var showCompressMenu: Bool
    var showExtractMenu: Bool
    var showAdvancedMenu: Bool
    var defaultFormat: String

    init() {
        let storage = SharedStorageManager.shared
        showCompressMenu = storage.getBool(forKey: MacZipSettings.showCompressMenu, defaultValue: true)
        showExtractMenu = storage.getBool(forKey: MacZipSettings.showExtractMenu, defaultValue: true)
        showAdvancedMenu = storage.getBool(forKey: MacZipSettings.showAdvancedMenu, defaultValue: true)
        defaultFormat = storage.getString(forKey: MacZipSettings.defaultFormat, defaultValue: "zip")
    }
}

// MARK: - 插件进程生命周期入口

@main
struct ExtensionMain {
    static func main() {
        _ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@_silgen_name("NSExtensionMain")
@discardableResult
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
