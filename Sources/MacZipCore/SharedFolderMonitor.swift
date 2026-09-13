import Foundation

/// 轻量目录变更监听 (kqueue DISPATCH_VNODE_WRITE)。
/// 用于监听 App Group 容器中的 PendingActions 目录,作为分布式通知之外的第二保险。
///
/// 注意:write 事件不需要重挂 (同一 source 持续投递);只有目录本身被删除/重命名时
/// 才重新 open。早期实现"每次事件都 restart",高频动作下 cancel/reopen 链路会断裂,
/// 导致监听静默失效、队列无人消费。
final class SharedFolderMonitor {
    private let folderURL: URL
    private var monitorSource: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let stateLock = NSLock()

    var onFolderChanged: (() -> Void)?

    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    func start() {
        stateLock.lock()
        // 幂等:已有活跃监听时不重复挂 (write 事件无需 restart)。
        guard monitorSource == nil else {
            stateLock.unlock()
            return
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        let fd = open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else {
            stateLock.unlock()
            AppLog.error("目录监听 open 失败: \(folderURL.path)", category: .core)
            return
        }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: DispatchQueue(label: "wzl.MacZip.folder-monitor", qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.onFolderChanged?()
            // 目录本身被动过 (删除/重命名):旧 fd 失效,需要重挂。
            if self.shouldReselect(source) {
                self.start(reset: true)
            }
        }
        source.setCancelHandler { [fd] in
            if fd >= 0 { close(fd) }
        }
        source.resume()
        monitorSource = source
        stateLock.unlock()
    }

    private func shouldReselect(_ source: DispatchSourceFileSystemObject) -> Bool {
        let data = UInt(source.data.rawValue)
        let deleteOrRename: UInt = DispatchSource.FileSystemEvent.delete.rawValue
            | DispatchSource.FileSystemEvent.rename.rawValue
        return (data & deleteOrRename) != 0
    }

    func start(reset: Bool) {
        stateLock.lock()
        if reset {
            monitorSource?.cancel()
            monitorSource = nil
            if descriptor >= 0 {
                // fd 由 cancel handler 关闭,这里只清句柄。
                descriptor = -1
            }
        }
        stateLock.unlock()
        start()
    }

    func stop() {
        stateLock.lock()
        monitorSource?.cancel()
        monitorSource = nil
        descriptor = -1
        stateLock.unlock()
    }
}
