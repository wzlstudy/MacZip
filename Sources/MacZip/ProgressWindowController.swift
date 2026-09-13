import Foundation
import AppKit
import os

private let watchdogLog = Logger(subsystem: "wzl.MacZip", category: "progress")

/// 压缩/解压进度浮窗 (FastZip 风格:置顶小窗 + 进度条 + 取消按钮)。
///
/// 只呈现整体进度条与百分比,不显示"当前文件":
/// 并行压缩/解压时多个文件同时处理,单个文件名无法反映真实进度,
/// 反而会让人误以为界面卡住。收尾阶段 (分片写入 / 切分分卷) 用标题文字提示。
final class ProgressWindowController: ArchiveProgressReporting {
    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var percentLabel: NSTextField!

    private let lock = NSLock()
    private var _isCancelled = false
    private var processedBytes: UInt64 = 0
    private var totalBytes: UInt64 = 0
    /// 字节级进度是否可用 (0 表示 indeterminate)。
    private var isIndeterminate = true

    // MARK: - UI 更新合并 (coalescing)
    //
    // 多线程压缩/解压会以极高频率调用 advance (每个 1 MiB 分块一次)。
    // 若每次调用都往主队列派发一个 block,主队列会被成千上万个陈旧 block 淹没,
    // finish()/close() 的关闭任务排在队尾,进度到 100% 后弹窗会滞留数秒。
    // 因此这里只保留"最新待应用进度",并保证同一时刻最多只有一个待执行 UI block。

    /// 最新待应用的进度值 (受 lock 保护)。
    private var pendingPercent: Double?
    /// 是否已有 UI 更新 block 排队 (受 lock 保护)。
    private var uiUpdateScheduled = false

    // MARK: 无响应看门狗
    //
    // 兜底防护:任何 finish/fail/close 泄漏 (如某条成功路径漏掉收尾) 都会让
    // 面板永久滞留且取消按钮无效 (工作已结束,无人响应取消标记)。
    // 看门狗在 begin 时挂起,每次进度活动刷新时间戳;超时无活动即标记取消、
    // 关闭面板并提示。正常的长任务 (逐块 advance) 会不断刷新,不会误伤。

    /// 无活动多久判定为无响应。
    static let watchdogTimeout: TimeInterval = 300
    private var lastActivityAt = Date()
    private var watchdogItem: DispatchWorkItem?

    private func touchActivity() {
        lock.lock()
        lastActivityAt = Date()
        lock.unlock()
    }

    private func scheduleWatchdog() {
        watchdogItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.panel != nil else { return }
            self.lock.lock()
            let idle = Date().timeIntervalSince(self.lastActivityAt)
            self.lock.unlock()
            if idle < Self.watchdogTimeout {
                // 期间有过活动:按剩余空闲时长重新挂起,绝不误取消健康任务。
                self.scheduleWatchdog()
                return
            }
            self.lock.lock()
            self._isCancelled = true
            self.lock.unlock()
            watchdogLog.error("进度窗超时无响应,已自动取消并关闭")
            self.close()
            ToastHUD.showAsync(title: "操作无响应", content: "进度窗已自动关闭并取消", isSuccess: false)
        }
        watchdogItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchdogTimeout, execute: item)
    }

    private func cancelWatchdog() {
        watchdogItem?.cancel()
        watchdogItem = nil
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func begin(totalBytes: UInt64, title: String) {
        lock.lock()
        processedBytes = 0
        self.totalBytes = totalBytes
        isIndeterminate = totalBytes == 0
        pendingPercent = nil
        uiUpdateScheduled = false
        lastActivityAt = Date()
        lock.unlock()
        scheduleWatchdog()

        DispatchQueue.main.async { [weak self] in
            self?.present(title: title)
        }
    }

    /// 单个文件开始处理。并行引擎下多个文件几乎同时启动,此回调不再驱动界面,
    /// 仅记录最后一个名字,供 finish 时作为 HUD 副标题兜底。
    func willProcessFile(_ name: String) {
        touchActivity()
        lock.lock()
        lastFile = name
        lock.unlock()
    }

    func advance(by bytes: UInt64) {
        touchActivity()
        lock.lock()
        processedBytes += bytes
        if !isIndeterminate && totalBytes > 0 {
            pendingPercent = min(1.0, Double(processedBytes) / Double(totalBytes))
        }
        let needSchedule = !uiUpdateScheduled
        if needSchedule { uiUpdateScheduled = true }
        lock.unlock()

        if needSchedule {
            DispatchQueue.main.async { [weak self] in self?.flushUI() }
        }
    }

    /// 收尾阶段提示:分片写入压缩包 / 切分分卷时更新标题,避免进度满格后界面看似卡住。
    func willFinalize(message: String) {
        touchActivity()
        DispatchQueue.main.async { [weak self] in
            self?.titleLabel?.stringValue = message
        }
    }

    /// 在主线程应用最新待更新进度,并决定是否继续调度。
    private func flushUI() {
        lock.lock()
        let percent = pendingPercent
        pendingPercent = nil
        lock.unlock()

        if !closeRequestedOnMain, let percent {
            progressBar?.doubleValue = percent
            percentLabel?.stringValue = String(format: "%.0f%%", percent * 100)
        }

        // 应用期间可能又有新值入队:有则再调度一轮,否则释放调度标志。
        // 判定与清标志必须与生产者的入队操作在同一把锁下原子完成,避免丢更新。
        lock.lock()
        let more = pendingPercent != nil
        if !more { uiUpdateScheduled = false }
        lock.unlock()

        if more {
            DispatchQueue.main.async { [weak self] in self?.flushUI() }
        }
    }

    /// 任务正常结束。subtitle 为 HUD 副标题 (压缩显示压缩包名,解压显示目标文件夹);
    /// 缺省时回退到最后处理的文件名。
    func finish(message: String, subtitle: String? = nil) {
        close()
        let content = subtitle ?? lastFileName
        ToastHUD.showAsync(title: message, content: content, isSuccess: true)
    }

    func fail(message: String) {
        close()
        ToastHUD.showAsync(title: "操作失败", content: message, isSuccess: false)
    }

    private var lastFileName: String {
        lock.lock()
        defer { lock.unlock() }
        return lastFile
    }
    private var lastFile: String = ""

    // MARK: - UI

    private func present(title: String) {
        guard panel == nil else {
            titleLabel.stringValue = title
            return
        }

        let width: CGFloat = 420
        let height: CGFloat = 96
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let x = screen.origin.x + (screen.size.width - width) / 2
        let y = screen.origin.y + screen.size.height - height - 90

        let contentPanel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        contentPanel.level = .floating
        contentPanel.isOpaque = false
        contentPanel.hasShadow = true
        contentPanel.titleVisibility = .hidden
        contentPanel.titlebarAppearsTransparent = true
        contentPanel.hidesOnDeactivate = false
        contentPanel.isFloatingPanel = true
        contentPanel.worksWhenModal = true

        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effectView.material = .windowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 20, y: height - 38, width: width - 40 - 80, height: 20)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: width - 40 - 56, height: 16))
        progressBar.isIndeterminate = isIndeterminate
        progressBar.minValue = 0
        progressBar.maxValue = 1
        if isIndeterminate {
            progressBar.startAnimation(nil)
        }

        percentLabel = NSTextField(labelWithString: isIndeterminate ? "" : "0%")
        percentLabel.frame = NSRect(x: width - 68, y: 30, width: 48, height: 13)
        percentLabel.font = .systemFont(ofSize: 10, weight: .medium)
        percentLabel.alignment = .right
        percentLabel.textColor = .secondaryLabelColor

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.frame = NSRect(x: width - 78, y: height - 42, width: 60, height: 24)

        effectView.addSubview(titleLabel)
        effectView.addSubview(progressBar)
        effectView.addSubview(percentLabel)
        effectView.addSubview(cancelButton)
        contentPanel.contentView = effectView

        // 极速任务下 close() 可能先于本 present 的主线程任务排队;
        // 若关闭已被请求,直接不展示 (并顺手关闭),避免面板永久滞留屏幕。
        if closeRequestedOnMain {
            contentPanel.close()
            panel = nil
            return
        }
        contentPanel.orderFrontRegardless()
        self.panel = contentPanel
    }

    @objc private func cancelClicked(_ sender: Any) {
        lock.lock()
        _isCancelled = true
        lock.unlock()
        cancelWatchdog()
        // 立即收起面板:若后台工作已结束 (面板泄漏场景),用户不至于面对
        // 一个永远关不掉的面板;若仍在进行,下一个取消检查点会中止工作。
        close()
    }

    /// 主线程读写的关闭请求标志 (present/close 均在主线程执行,天然串行)。
    private var closeRequestedOnMain = false

    func close() {
        cancelWatchdog()
        // 必须强捕获 self:快动作 (如几毫秒的测试) 可能先于主线程执行 present 块
        // 就走到 close,此时 panel 尚为 nil;若用 weak self,控制器在 runAction
        // 返回后立即释放,close 块执行时 self 为空、panelToClose 也是捕获到的 nil,
        // 随后 present 块才创建面板 → 面板永久滞留且取消按钮无效。强捕获保证
        // close 块执行时能拿到 (或等到) present 创建的当前面板。
        lock.lock()
        let panelToClose = self.panel
        lock.unlock()
        DispatchQueue.main.async { self.closeOnMain(backup: panelToClose) }
    }

    private func closeOnMain(backup: NSPanel?) {
        closeRequestedOnMain = true
        (panel ?? backup)?.close()
        panel = nil
    }
}
