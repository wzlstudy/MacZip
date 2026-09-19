import Cocoa
import Quartz

// MARK: - 插件进程生命周期入口 (appex 可执行文件必需)

@main
struct QuickLookExtensionMain {
    static func main() {
        _ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

@_silgen_name("NSExtensionMain")
@discardableResult
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

private final class QuickLookMoreChildrenNode: NSObject {
    let parent: ZipEntryNode?
    let offset: Int
    let remaining: Int

    init(parent: ZipEntryNode?, offset: Int, remaining: Int) {
        self.parent = parent
        self.offset = offset
        self.remaining = remaining
        super.init()
    }
}

private final class QuickLookTableCellView: NSTableCellView {
    var showsIcon = false

    override func layout() {
        super.layout()
        let height = bounds.height
        let iconSize: CGFloat = 16
        if let imageView {
            imageView.frame = NSRect(
                x: 2,
                y: max(0, (height - iconSize) / 2),
                width: iconSize,
                height: iconSize
            )
        }

        // 无图标列左右各留 8pt,与表头内边距一致,右对齐/左对齐均能对齐标题;
        // 有图标列保持 2pt 图标边距 + 图标 16pt + 6pt 间隙的原生节奏。
        let leftInset: CGFloat = showsIcon ? 24 : 8
        let rightInset: CGFloat = showsIcon ? 4 : 8
        textField?.frame = NSRect(
            x: leftInset,
            y: max(0, (height - 18) / 2),
            width: max(0, bounds.width - leftInset - rightInset),
            height: min(18, height)
        )
    }
}

// MARK: - MacZip QuickLook 预览扩展 (空格预览压缩包,树形文件列表)

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var outlineView: NSOutlineView!
    private var statusLabel: NSTextField!
    private var roots: [ZipEntryNode] = []
    private var archiveSize: UInt64 = 0
    private var loadedChildCounts: [String: Int] = [:]

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // Quick Look 的展开操作必须保持轻量;首批只创建少量可见条目,
    // 继续加载通过“显示更多”分页。
    private static let childPageSize = 64
    private static let rootChildrenKey = ""
    private var iconCache: [String: NSImage] = [:]

    override func loadView() {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let container = NSView(frame: frame)

        statusLabel = NSTextField(labelWithString: "正在读取压缩包…")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        outlineView = NSOutlineView()
        outlineView.style = .inset
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        // 列宽完全由用户控制,避免自动重分配抵消拖动结果。
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.allowsColumnResizing = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.backgroundColor = .clear
        // 内容区不画竖向网格线;列边界只由表头短刻度提示。
        outlineView.gridStyleMask = []
        // 置 0 后内容 cell 与列矩形重合,表头与内容用同一套内边距即可对齐
        // (默认 .inset 间距 17pt 会把内容从列边界内缩 8.5pt 造成错位)。
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = 220
        nameColumn.minWidth = 130
        nameColumn.maxWidth = 900
        nameColumn.resizingMask = [.userResizingMask]
        nameColumn.title = "名称"
        // 表头内边距与内容 cell 一致 (8pt),保证标题与正文像素级对齐。
        nameColumn.headerCell = FlatTableHeaderCell(title: "名称", alignment: .left, leadingInset: 8)
        outlineView.addTableColumn(nameColumn)
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.width = 88
        sizeColumn.minWidth = 68
        sizeColumn.maxWidth = 180
        sizeColumn.resizingMask = [.userResizingMask]
        sizeColumn.title = "大小"
        sizeColumn.headerCell = FlatTableHeaderCell(title: "大小", alignment: .right, trailingInset: 8)
        outlineView.addTableColumn(sizeColumn)
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.width = 132
        dateColumn.minWidth = 100
        dateColumn.maxWidth = 220
        dateColumn.resizingMask = [.userResizingMask]
        dateColumn.title = "修改日期"
        dateColumn.headerCell = FlatTableHeaderCell(title: "修改日期", alignment: .right, trailingInset: 8)
        outlineView.addTableColumn(dateColumn)
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.width = 100
        kindColumn.minWidth = 76
        kindColumn.maxWidth = 180
        kindColumn.resizingMask = [.userResizingMask]
        kindColumn.title = "种类"
        kindColumn.headerCell = FlatTableHeaderCell(title: "种类", alignment: .left, leadingInset: 8)
        outlineView.addTableColumn(kindColumn)

        outlineView.outlineTableColumn = nameColumn
        let tableHeader = FlatTableHeaderView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 0,
                height: FlatTableHeaderView.preferredHeight
            )
        )
        tableHeader.autoresizingMask = [.width]
        outlineView.headerView = tableHeader

        // 扁平表头:透明底 + 与列内容一致的对齐方式 (原生表头会画不透明白底,
        // 且标题一律左对齐,与右对齐的大小/时间数值错位)。
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(statusLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        view = container
        preferredContentSize = frame.size
    }

    /// QuickLook 入口:解析归档清单,树形渲染文件列表 (不落盘)。
    /// 支持 ZIP / JAR / TAR / TAR.GZ (经内建读取器统一解析)。
    func preparePreviewOfFile(at url: URL) async throws {
        archiveSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0

        let contentReader = try ArchiveContentReader.open(url: url)
        let parsed = try contentReader.listEntries()
        let tree = ZipEntryTree.build(from: parsed)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.roots = tree
            self.loadedChildCounts.removeAll(keepingCapacity: true)
            let counts = ZipEntryTree.counts(in: tree)
            let encrypted = tree.contains { $0.isEncrypted }
            var summary = "\(counts.files) 个文件"
            if counts.folders > 0 { summary += " · \(counts.folders) 个文件夹" }
            if encrypted { summary += " · 🔒 已加密" }
            if self.archiveSize > 0 {
                summary += " · 压缩包 \(ByteCountFormatter.string(fromByteCount: Int64(self.archiveSize), countStyle: .file))"
            }
            self.statusLabel.stringValue = summary
            self.outlineView.reloadData()
            // 最多自动展开一个顶层目录。即使是“小型”归档,同时展开多个目录
            // 也会在主线程创建大量 row view,导致 Quick Look 首屏或后续操作卡顿。
            if parsed.count <= 500,
               let firstDirectory = tree.first(where: { $0.isDirectory && !$0.children.isEmpty }) {
                self.outlineView.expandItem(firstDirectory)
            }
        }
    }

    private func children(of parent: ZipEntryNode?) -> [ZipEntryNode] {
        parent?.children ?? roots
    }

    private func loadedChildCount(of parent: ZipEntryNode?) -> Int {
        let all = children(of: parent)
        guard !all.isEmpty else { return 0 }
        return min(
            all.count,
            loadedChildCounts[parent?.path ?? Self.rootChildrenKey] ?? Self.childPageSize
        )
    }

    private func childObject(at index: Int, of parent: ZipEntryNode?) -> Any {
        let all = children(of: parent)
        let loaded = loadedChildCount(of: parent)
        if index < loaded {
            return all[index]
        }
        return QuickLookMoreChildrenNode(
            parent: parent,
            offset: loaded,
            remaining: all.count - loaded
        )
    }

    private func loadMoreChildren(_ more: QuickLookMoreChildrenNode) {
        let key = more.parent?.path ?? Self.rootChildrenKey
        let total = more.parent?.children.count ?? roots.count
        loadedChildCounts[key] = min(total, more.offset + Self.childPageSize)
        if let parent = more.parent {
            outlineView.reloadItem(parent, reloadChildren: true)
        } else {
            outlineView.reloadData()
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) else { return }
        guard let more = item as? QuickLookMoreChildrenNode else { return }
        loadMoreChildren(more)
    }
}

extension PreviewViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let parent = item as? ZipEntryNode
        let all = children(of: parent)
        let loaded = loadedChildCount(of: parent)
        return loaded + (loaded < all.count ? 1 : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        childObject(at: index, of: item as? ZipEntryNode)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ZipEntryNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let more = item as? QuickLookMoreChildrenNode, let column = tableColumn {
            switch column.identifier.rawValue {
            case "name":
                let cell = reusableCell(identifier: "name", hasIcon: true)
                cell.textField?.stringValue = "显示更多（还剩 \(more.remaining) 项）"
                cell.textField?.textColor = .controlAccentColor
                cell.imageView?.image = icon(named: "ellipsis.circle")
                cell.imageView?.contentTintColor = .controlAccentColor
                return cell
            case "kind":
                let cell = reusableCell(identifier: "kind", hasIcon: false)
                cell.textField?.stringValue = "继续加载"
                cell.textField?.textColor = .controlAccentColor
                return cell
            case "size", "date":
                let cell = reusableCell(identifier: column.identifier.rawValue, hasIcon: false)
                cell.textField?.stringValue = ""
                return cell
            default:
                return nil
            }
        }

        guard let node = item as? ZipEntryNode, let column = tableColumn else { return nil }
        switch column.identifier.rawValue {
        case "name":
            let cell = reusableCell(identifier: "name", hasIcon: true)
            cell.textField?.stringValue = node.name
            cell.textField?.textColor = .labelColor
            guard let imageView = cell.imageView else { return cell }
            if node.isEncrypted {
                imageView.image = icon(named: "lock.fill")
                imageView.contentTintColor = .systemOrange
            } else {
                imageView.image = icon(named: node.isDirectory ? "folder.fill" : "doc")
                imageView.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
            }
            return cell
        case "size":
            let cell = reusableCell(identifier: "size", hasIcon: false)
            if node.isDirectory {
                cell.textField?.stringValue = node.displaySize > 0
                    ? byteCountFormatter.string(fromByteCount: Int64(node.displaySize))
                    : "—"
            } else {
                cell.textField?.stringValue = byteCountFormatter.string(
                    fromByteCount: Int64(node.displaySize)
                )
            }
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .right
            return cell
        case "date":
            let cell = reusableCell(identifier: "date", hasIcon: false)
            cell.textField?.stringValue = node.lastModified.map { dateFormatter.string(from: $0) } ?? ""
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .right
            return cell
        case "kind":
            let cell = reusableCell(identifier: "kind", hasIcon: false)
            cell.textField?.stringValue = ArchiveKind.displayName(forName: node.name, isDirectory: node.isDirectory)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .left
            return cell
        default:
            return nil
        }
    }

    private func reusableCell(identifier: String, hasIcon: Bool) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? QuickLookTableCellView {
            reused.showsIcon = hasIcon
            return reused
        }
        let cell = QuickLookTableCellView()
        cell.identifier = id
        cell.showsIcon = hasIcon

        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 11)
        textField.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(textField)
        cell.textField = textField

        if hasIcon {
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView
        }
        return cell
    }

    private func icon(named name: String) -> NSImage? {
        if let cached = iconCache[name] {
            return cached
        }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        iconCache[name] = image
        return image
    }
}
