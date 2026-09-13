import Cocoa
import SwiftUI

// MARK: - 纯代码 AppKit 生命周期托管入口

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    static var instance: AppDelegate?

    /// 扩展后台拉起标志 (与 FinderSync.ensureHostRunning 约定一致)。
    static let backgroundLaunchArgument = "--background"

    // 启动来源判定直接使用 getppid() (自启时父进程为 launchd pid=1),
    // 无需引入 libproc。

    /// 设置窗口,首次打开时惰性创建:SwiftUI 视图树 (NSHostingView) 内存可观,
    /// 菜单栏常驻应用不值得在启动时就为它付出常驻内存。
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var folderMonitor: SharedFolderMonitor?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. 监听来自 Finder 扩展的分布式触发信号。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleExtensionActionSignal),
            name: MacZipConstants.triggerActionSignal,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // 2. 回收崩溃孤儿 + 启动即消费遗留队列。
        ActionCoordinator.shared.start()

        // 3. DispatchSource 目录监听 (分布式信号之外的第二保险)。
        let monitor = SharedFolderMonitor(folderURL: SharedStorageManager.shared.pendingActionsDirectoryURL)
        monitor.onFolderChanged = {
            ActionCoordinator.shared.processPendingActions()
        }
        monitor.start()
        folderMonitor = monitor

        // 3.5 清理历史崩溃残留的临时目录 (预览会话 / 装配区 / 合并暂存等)。
        DispatchQueue.global(qos: .utility).async {
            SharedStorageManager.shared.sweepOrphanedTempDirectories()
        }

        // 4. 设置窗口惰性创建 (见 ensureSettingsWindow),此处不构建。

        // 5. 菜单栏常驻图标。
        setupStatusItem()

        // 6. 启动呈现策略 (对齐 MacRightClick LaunchPresentationPolicy):
        //    关键事实:.accessory 应用永远不是前台活跃 app,isActive 判断不可用;
        //    可靠的启动来源信号是启动参数:
        //      - Dock/启动台/访达双击 app  → 带 -psn_0_XXXX (Process Serial Number)
        //      - 开机自启 (launchd / 登录项) → 无 -psn,父进程为 launchd 或 launchservicesd
        //      - 扩展后台拉起               → 我们注入 --background
        //    规则:
        //      - 静默启动开启(默认):
        //          自启/后台/扩展拉起 → 静默;双击 app 图标 → 弹窗
        //      - 静默启动关闭:任何启动都弹窗
        //    双击 zip 打开文档:启动参数既有 -psn 又有文件路径 → 弹设置窗会很突兀,
        //    但由于有任务窗口(预览/进度),设置窗会被覆盖,不影响主流程。
        let launchArguments = CommandLine.arguments
        let hasPSN = launchArguments.contains { $0.hasPrefix("-psn_") }
        print("[App] 启动参数: \(launchArguments)")

        if launchArguments.contains(Self.backgroundLaunchArgument) {
            // 扩展后台拉起 → 永远静默 (不受用户开关影响)
            print("[App] 后台静默启动 (扩展拉起)")
        } else {
            let silentLaunch = SharedStorageManager.shared.getBool(
                forKey: MacZipSettings.silentLaunch,
                defaultValue: true
            )
            if !silentLaunch {
                // 用户显式要求任何启动都弹窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.showSettingsWindow()
                }
            } else if hasPSN {
                // 用户主动打开 app 图标 → 弹设置窗
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.showSettingsWindow()
                }
                print("[App] 用户主动启动 (带 PSN),弹出设置窗口")
            } else {
                // 自启 / 登录项 → 静默
                print("[App] 静默启动 (自启/登录项,无 PSN)")
            }
        }

        print("[App] MacZip 宿主程序启动完成 (中介链路就绪)")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        folderMonitor?.stop()
    }

    // MARK: - 文档打开 (Finder 双击压缩包 → 直接解压)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        ActionCoordinator.shared.openArchives(urls)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false // 无文档模型,双击应用图标只唤起设置窗口
    }

    // MARK: - 动作消费

    @objc private func handleExtensionActionSignal() {
        ActionCoordinator.shared.processPendingActions()
    }

    // MARK: - 菜单栏托盘

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "MacZip") {
            image.isTemplate = true
            button.image = image
        }
        if button.image == nil {
            button.title = "Zip"
        }

        let menu = NSMenu(title: "MacZip")
        menu.delegate = self
        rebuildStatusMenu(menu)
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let settingsItem = NSMenuItem(title: "打开设置…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let extensionItem = NSMenuItem(
            title: ExternalExtensionStatus.isFinderExtensionEnabled ? "Finder 扩展已启用" : "启用 Finder 扩展…",
            action: ExternalExtensionStatus.isFinderExtensionEnabled ? nil : #selector(openExtensionSettings),
            keyEquivalent: ""
        )
        extensionItem.target = self
        menu.addItem(extensionItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 MacZip", action: #selector(showAboutDialog), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(terminateApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// 惰性创建设置窗口 (FastZip 风格,SwiftUI 托管)。
    private func ensureSettingsWindow() -> NSWindow {
        if let window = settingsWindow { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.title = "MacZip 偏好设置"
        window.center()
        window.setFrameAutosaveName("MacZipSettingsWindow")
        window.contentView = NSHostingView(rootView: SettingsRootView())
        window.titlebarAppearsTransparent = true
        settingsWindow = window
        return window
    }

    @objc private func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        ensureSettingsWindow().makeKeyAndOrderFront(nil)
    }

    @objc private func openExtensionSettings() {
        ExternalExtensionStatus.openFinderExtensionPreferences()
    }

    @objc private func showAboutDialog() {
        let alert = NSAlert()
        alert.messageText = "关于 MacZip"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        alert.informativeText = """
        MacZip v\(version)

        macOS 快速压缩解压工具。
        多线程压缩引擎 · 空格预览压缩包 · 密码本自动解密
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.window.level = .modalPanel
        alert.window.orderFrontRegardless()
        alert.runModal()
    }

    @objc private func terminateApp() {
        NSApp.terminate(nil)
    }

    // MARK: - 窗口生命周期 (关闭即隐藏,保持菜单栏常驻)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }
}

// MARK: - Finder 扩展启用状态探测

enum ExternalExtensionStatus {
    private static let statusLock = NSLock()
    private static var cachedEnabled: Bool?
    private static var cachedAt = Date.distantPast
    /// pluginkit 是进程外同步查询,菜单栏菜单每次展开都会触发;
    /// 短 TTL 缓存,避免反复拉起子进程卡顿 UI。
    private static let queryTTL: TimeInterval = 30

    /// 查询 pluginkit 中本扩展的启用状态 (进程外查询,带 TTL 缓存)。
    static var isFinderExtensionEnabled: Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        if let cached = cachedEnabled, Date().timeIntervalSince(cachedAt) < queryTTL {
            return cached
        }
        let value = queryFinderExtensionEnabled()
        cachedEnabled = value
        cachedAt = Date()
        return value
    }

    private static func queryFinderExtensionEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", MacZipConstants.extensionBundleIdentifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // pluginkit -m 输出以 "+"/"-"/"!" 标注启用状态。
        return output.hasPrefix("+")
    }

    /// 打开系统设置的扩展管理面板 (macOS 12:系统偏好设置 → 扩展 → 访达扩展)。
    static func openFinderExtensionPreferences() {
        let prefPane = "x-apple.systempreferences:com.apple.ExtensionsPreferences"
        if let url = URL(string: prefPane) {
            NSWorkspace.shared.open(url)
        }
    }
}
