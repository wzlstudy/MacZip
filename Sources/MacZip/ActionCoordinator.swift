import Foundation
import AppKit

/// 动作协调器:消费 Finder 扩展写入的 PendingActions 队列,
/// 调度 ArchiveService 执行,并驱动进度窗 / 密码弹窗 / 完成提示。
final class ActionCoordinator {
    static let shared = ActionCoordinator()

    /// 串行队列:多笔右键动作按 FIFO 消费,避免并发进度窗互相踩踏。
    private let workQueue = DispatchQueue(label: "wzl.MacZip.action-coordinator", qos: .userInitiated)
    private var osLock = os_unfair_lock()

    private init() {}

    func start() {
        SharedStorageManager.shared.reclaimAbandonedInFlightActions()
        processPendingActions()
    }

    /// 外部触发入口 (分布式信号 / 启动扫描 / 文件监听)。线程安全,立即返回。
    func processPendingActions() {
        workQueue.async { [weak self] in
            self?.drainQueue()
        }
    }

    private func drainQueue() {
        guard os_unfair_lock_trylock(&osLock) else { return }
        defer { os_unfair_lock_unlock(&osLock) }

        let leases = SharedStorageManager.shared.consumePendingActionLeases()
        SharedStorageManager.shared.writeLog("[Coordinator] 取到 \(leases.count) 个待处理动作")
        for lease in leases {
            let event = lease.event
            SharedStorageManager.shared.writeLog("[Coordinator] 开始执行: \(event.actionId), 目标: \(event.paths)")
            runAction(event)
            SharedStorageManager.shared.writeLog("[Coordinator] 动作返回: \(event.actionId)")
            SharedStorageManager.shared.acknowledge(lease)
        }

        // 防竞态兜底:SharedStorageManager 对"刚落盘却解析失败"的半写文件会跳过并留在队列,
        // 但 kqueue 不会再为它触发事件。若队列仍积压,1.5s 后自动补一轮 drain,直到消费干净。
        if SharedStorageManager.shared.pendingActionCount > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.processPendingActions()
            }
        }
    }

    // MARK: - 动作执行

    private func runAction(_ event: SharedActionEvent) {
        let targets = event.paths.map { URL(fileURLWithPath: $0) }
        guard !targets.isEmpty else { return }

        let progress = ProgressWindowController()

        do {
            switch event.actionId {
            case "maczip.action.compress.default",
                 "maczip.action.compress.zip",
                 "maczip.action.compress.targz",
                 "maczip.action.compress.7z",
                 "maczip.action.compress.solid":
                try performCompress(event: event, targets: targets, progress: progress, password: nil)

            case "maczip.action.compress.encrypted":
                guard let password = promptPasswordOnMain(title: "加密压缩", allowSave: true) else {
                    progress.close()
                    return
                }
                try performCompress(event: event, targets: targets, progress: progress, password: password)

            case "maczip.action.compress.volumed":
                guard let volumeMB = promptVolumeOnMain() else {
                    progress.close()
                    return
                }
                try performCompress(event: event, targets: targets, progress: progress, password: nil, volumeMB: volumeMB)

            case "maczip.action.extract.here",
                 "maczip.action.extract.subfolder",
                 "maczip.action.extract.to",
                 "maczip.action.test":
                try performExtractOrTest(event: event, targets: targets, progress: progress)

            default:
                AppLog.error("未知动作: \(event.actionId)", category: .app)
                progress.close()
            }
        } catch is CancellationError {
            progress.close()
            ToastHUD.showAsync(title: "已取消", content: "操作已取消", isSuccess: true)
        } catch {
            progress.fail(message: error.localizedDescription)
            SharedStorageManager.shared.writeLog(
                "[Coordinator] 动作 \(event.actionId) 失败: \(error.localizedDescription)", level: .error
            )
        }
    }

    private func performCompress(
        event: SharedActionEvent,
        targets: [URL],
        progress: ProgressWindowController,
        password: String?,
        volumeMB: Int? = nil
    ) throws {
        let storage = SharedStorageManager.shared
        let format: ArchiveService.CompressFormat
        switch event.actionId {
        case "maczip.action.compress.targz": format = .tarGz
        case "maczip.action.compress.7z", "maczip.action.compress.solid": format = .sevenZip
        case "maczip.action.compress.default":
            format = ArchiveService.CompressFormat(
                rawValue: storage.getString(forKey: MacZipSettings.defaultFormat, defaultValue: "zip")
            ) ?? .zip
        default: format = .zip
        }

        let level = ZlibCodec.Level(
            rawValue: storage.getString(forKey: MacZipSettings.compressionLevel, defaultValue: "standard")
        ) ?? .standard

        // 压缩格式与能力不匹配时优雅降级。
        if format == .sevenZip && !ExternalArchiver.shared.isSevenZipAvailable {
            progress.close()
            ToastHUD.showAsync(
                title: "7Z 压缩不可用",
                content: "未找到 7-Zip 引擎,可使用 ZIP / TAR.GZ",
                isSuccess: false
            )
            return
        }

        let output = ArchiveService.defaultOutputURL(for: targets, format: format)
        let solid = storage.getBool(forKey: MacZipSettings.solidSevenZip, defaultValue: false)
            || event.actionId == "maczip.action.compress.solid"
        let volume = volumeMB ?? {
            let stored = storage.getInt(forKey: MacZipSettings.defaultVolumeSizeMB, defaultValue: 0)
            return stored > 0 ? stored : nil
        }()

        SharedStorageManager.shared.writeLog("[Coordinator] 压缩参数: format=\(format.rawValue) level=\(level.rawValue) output=\(output.path)")
        let result = try ArchiveService.shared.compress(
            inputs: targets,
            output: output,
            format: format,
            level: level,
            password: password,
            volumeSizeMB: volume,
            solid: solid,
            excludeSystemJunk: storage.getBool(forKey: MacZipSettings.excludeSystemJunk, defaultValue: true),
            useAES: format == .zip && storage.getBool(forKey: MacZipSettings.zipUseAES256, defaultValue: false),
            excludePatterns: storage.getStringArray(forKey: MacZipSettings.excludePatterns, defaultValue: []),
            reporter: progress
        )

        // 压缩后自动校验 (仅 ZIP;用压缩时口令,加密包同样可验)。
        if format == .zip && storage.getBool(forKey: MacZipSettings.verifyAfterCompress, defaultValue: true) {
            do {
                try ArchiveService.shared.test(
                    archive: result,
                    password: password,
                    preferPasswordBook: false,
                    reporter: progress
                )
                SharedStorageManager.shared.writeLog("[Coordinator] 校验通过: \(result.path)")
            } catch is CancellationError {
                progress.close()
                ToastHUD.showAsync(title: "已取消", content: "操作已取消", isSuccess: true)
                return
            } catch {
                SharedStorageManager.shared.writeLog(
                    "[Coordinator] 压缩包校验失败 (\(result.path)): \(error.localizedDescription)", level: .error
                )
                progress.fail(message: "压缩包校验失败:\(error.localizedDescription)")
                ToastHUD.showAsync(
                    title: "压缩包校验失败",
                    content: "建议删除后重新压缩 (\(result.lastPathComponent))",
                    isSuccess: false
                )
                return
            }
        }

        SharedStorageManager.shared.writeLog("[Coordinator] 压缩完成: \(result.path)")
        // ZipWriter 不负责 finish (分卷/装配多出口),由协调器统一收尾。
        // 副标题必须是产物 (压缩包) 名,而非最后处理的文件名。
        progress.finish(message: "压缩完成", subtitle: result.lastPathComponent)
    }

    private func performExtractOrTest(
        event: SharedActionEvent,
        targets: [URL],
        progress: ProgressWindowController
    ) throws {
        let storage = SharedStorageManager.shared

        if event.actionId == "maczip.action.test" {
            var lastError: Error?
            for target in targets {
                do {
                    try ArchiveService.shared.test(
                        archive: target,
                        password: event.password,
                        preferPasswordBook: storage.getBool(forKey: MacZipSettings.preferPasswordBook, defaultValue: true),
                        passwordPrompt: { [weak self] _, round in
                            self?.promptPasswordOnMain(title: "测试加密压缩包", allowSave: false, round: round)
                        },
                        reporter: progress
                    )
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            // 成功也必须收尾进度窗,否则面板永久滞留且取消按钮无效 (工作已结束)。
            progress.finish(message: "压缩包完好", subtitle: targets.first?.lastPathComponent)
            return
        }

        // 解压目标目录。
        var destination: URL?
        if event.actionId == "maczip.action.extract.to" {
            guard let chosen = chooseFolderOnMain() else {
                progress.close()
                return
            }
            destination = chosen
        }

        let conflictPolicy = ZipReader.ConflictPolicy(
            rawValue: storage.getString(forKey: MacZipSettings.conflictPolicy, defaultValue: "rename")
        ) ?? .rename

        var lastError: Error?
        var lastDestination: URL?
        for target in targets {
            do {
                lastDestination = try extractOne(
                    target: target,
                    destination: destination,
                    password: event.password,
                    conflictPolicy: conflictPolicy,
                    progress: progress
                )
            } catch {
                lastError = error
            }
        }
        if let lastError {
            // 容错解压:部分条目损坏已跳过 → 按成功收尾但明示跳过详情。
            if case let ZipError.partialFailure(skipped) = lastError {
                progress.finish(message: "解压完成 (跳过 \(skipped.count) 个损坏项)", subtitle: lastDestination?.lastPathComponent)
                SharedStorageManager.shared.writeLog("[Coordinator] 跳过损坏条目: \(skipped.joined(separator: ", "))")
                if storage.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
                    NSSound(named: "Glass")?.play()
                }
                return
            }
            throw lastError
        }

        progress.finish(message: "解压完成", subtitle: lastDestination?.lastPathComponent)

        if storage.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
            NSSound(named: "Glass")?.play()
        }
    }

    /// 解压单个压缩包 (右键动作 / 双击打开文档共用)。
    /// 完成后按设置删除压缩包 / 打开目标文件夹。返回解压目标目录。
    /// 注意:本方法不做 finish/fail 收尾,由调用方统一处理 (多目标场景只发一次 HUD)。
    @discardableResult
    private func extractOne(
        target: URL,
        destination: URL?,
        password: String?,
        conflictPolicy: ZipReader.ConflictPolicy,
        progress: ProgressWindowController
    ) throws -> URL {
        let storage = SharedStorageManager.shared
        let extractedTo = try ArchiveService.shared.extract(
            archive: target,
            destination: destination,
            password: password,
            preferPasswordBook: storage.getBool(forKey: MacZipSettings.preferPasswordBook, defaultValue: true),
            conflictPolicy: conflictPolicy,
            passwordPrompt: { [weak self] _, round in
                self?.promptPasswordOnMain(title: "解压加密压缩包", allowSave: true, round: round)
            },
            reporter: progress
        )

        if storage.getBool(forKey: MacZipSettings.deleteArchiveAfterExtract, defaultValue: false) {
            try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
        }
        if storage.getBool(forKey: MacZipSettings.openFolderAfterExtract, defaultValue: false) {
            DispatchQueue.main.async {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extractedTo.path)
            }
        }
        return extractedTo
    }

    // MARK: - 文档打开 (Finder 双击压缩包)

    /// Finder 双击压缩包 (MacZip 为默认打开方式)。
    /// 行为由设置项 open_archive_action 决定:preview 预览窗口 (默认) / extract 直接解压。
    public func openArchives(_ urls: [URL]) {
        let storage = SharedStorageManager.shared
        let action = storage.getString(forKey: MacZipSettings.openArchiveAction, defaultValue: "preview")

        for url in urls {
            guard ArchiveFormat.detect(url: url) != nil else {
                ToastHUD.showAsync(
                    title: "无法打开",
                    content: "不支持该压缩包格式: \(url.lastPathComponent)",
                    isSuccess: false
                )
                continue
            }
            if action == "extract" {
                workQueue.async { [weak self] in
                    guard let self else { return }
                    let progress = ProgressWindowController()
                    do {
                        let extractedTo = try self.extractOne(
                            target: url,
                            destination: nil,
                            password: nil,
                            conflictPolicy: self.currentConflictPolicy(),
                            progress: progress
                        )
                        progress.finish(message: "解压完成", subtitle: extractedTo.lastPathComponent)
                        if storage.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
                            NSSound(named: "Glass")?.play()
                        }
                    } catch let ZipError.partialFailure(skipped) {
                        progress.finish(message: "解压完成 (跳过 \(skipped.count) 个损坏项)", subtitle: url.lastPathComponent)
                        SharedStorageManager.shared.writeLog("[Coordinator] 跳过损坏条目: \(skipped.joined(separator: ", "))")
                        if storage.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
                            NSSound(named: "Glass")?.play()
                        }
                    } catch is CancellationError {
                        progress.close()
                    } catch {
                        progress.fail(message: error.localizedDescription)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    ArchivePreviewWindowController.show(archive: url)
                }
            }
        }
    }

    /// 预览窗口的"解压到当前位置"按钮入口。
    public func extractSingle(target: URL) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let progress = ProgressWindowController()
            do {
                let extractedTo = try self.extractOne(
                    target: target,
                    destination: nil,
                    password: nil,
                    conflictPolicy: self.currentConflictPolicy(),
                    progress: progress
                )
                progress.finish(message: "解压完成", subtitle: extractedTo.lastPathComponent)
                if SharedStorageManager.shared.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
                    NSSound(named: "Glass")?.play()
                }
            } catch let ZipError.partialFailure(skipped) {
                progress.finish(message: "解压完成 (跳过 \(skipped.count) 个损坏项)", subtitle: target.lastPathComponent)
                SharedStorageManager.shared.writeLog("[Coordinator] 跳过损坏条目: \(skipped.joined(separator: ", "))")
                if SharedStorageManager.shared.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true) {
                    NSSound(named: "Glass")?.play()
                }
            } catch is CancellationError {
                progress.close()
            } catch {
                progress.fail(message: error.localizedDescription)
            }
        }
    }

    private func currentConflictPolicy() -> ZipReader.ConflictPolicy {
        ZipReader.ConflictPolicy(
            rawValue: SharedStorageManager.shared.getString(forKey: MacZipSettings.conflictPolicy, defaultValue: "rename")
        ) ?? .rename
    }

    // MARK: - 主线程交互 (密码 / 分卷 / 选目录)

    /// 主线程弹密码框。返回 nil 表示用户取消。
    @discardableResult
    private func promptPasswordOnMain(title: String, allowSave: Bool, round: Int = 1) -> String? {
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            let roundHint = round > 1 ? " (第 \(round) 次尝试)" : ""
            alert.informativeText = "请输入密码\(roundHint),或从密码本中选择。"
            alert.alertStyle = .informational
            let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.placeholderString = "密码"
            alert.accessoryView = input
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            if allowSave {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "保存到密码本"
            }
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                result = input.stringValue
                if allowSave, alert.suppressionButton?.state == .on, let password = result, !password.isEmpty {
                    _ = PasswordBook.shared.add(PasswordEntry(title: title, password: password))
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func promptVolumeOnMain() -> Int? {
        var result: Int?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "分卷压缩"
            alert.informativeText = "选择每个分卷的大小 (MB)。"
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.stringValue = "100"
            alert.accessoryView = input
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                result = Int(input.stringValue)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func chooseFolderOnMain() -> URL? {
        var result: URL?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "解压到这里"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK {
                result = panel.url
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
