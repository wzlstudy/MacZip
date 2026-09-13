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

// MARK: - MacZip QuickLook 预览扩展 (空格预览压缩包,树形文件列表)

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var outlineView: NSOutlineView!
    private var statusLabel: NSTextField!
    private var roots: [ZipEntryNode] = []
    private var archiveSize: UInt64 = 0

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

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
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.backgroundColor = .clear

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = 176
        nameColumn.minWidth = 130
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.title = "名称"
        outlineView.addTableColumn(nameColumn)
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.width = 74
        sizeColumn.minWidth = 74
        sizeColumn.maxWidth = 74
        sizeColumn.resizingMask = []
        sizeColumn.title = "大小"
        outlineView.addTableColumn(sizeColumn)
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.width = 112
        dateColumn.minWidth = 112
        dateColumn.maxWidth = 112
        dateColumn.resizingMask = []
        dateColumn.title = "修改日期"
        outlineView.addTableColumn(dateColumn)
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.width = 88
        kindColumn.minWidth = 88
        kindColumn.maxWidth = 88
        kindColumn.resizingMask = []
        kindColumn.title = "种类"
        outlineView.addTableColumn(kindColumn)

        outlineView.outlineTableColumn = nameColumn
        outlineView.headerView = FlatTableHeaderView()

        // 扁平表头:透明底 + 与列内容一致的对齐方式 (原生表头会画不透明白底,
        // 且标题一律左对齐,与右对齐的大小/时间数值错位)。
        nameColumn.headerCell.alignment = .left
        sizeColumn.headerCell.alignment = .right
        dateColumn.headerCell.alignment = .right
        kindColumn.headerCell.alignment = .left

        outlineView.dataSource = self
        outlineView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
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
            // 默认展开顶层目录,首屏即可看到内容。
            for node in tree where node.isDirectory && !node.children.isEmpty {
                self.outlineView.expandItem(node)
            }
        }
    }
}

extension PreviewViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ZipEntryNode else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ZipEntryNode else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ZipEntryNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ZipEntryNode, let column = tableColumn else { return nil }
        switch column.identifier.rawValue {
        case "name":
            let cell = reusableCell(identifier: "name", hasIcon: true)
            cell.textField?.stringValue = node.name
            cell.textField?.textColor = .labelColor
            guard let imageView = cell.imageView else { return cell }
            if node.isEncrypted {
                imageView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                imageView.contentTintColor = .systemOrange
            } else {
                imageView.image = NSImage(
                    systemSymbolName: node.isDirectory ? "folder.fill" : "doc",
                    accessibilityDescription: nil
                )
                imageView.contentTintColor = node.isDirectory ? .systemBlue : .secondaryLabelColor
            }
            return cell
        case "size":
            let cell = reusableCell(identifier: "size", hasIcon: false)
            if node.isDirectory {
                cell.textField?.stringValue = node.displaySize > 0
                    ? ByteCountFormatter.string(fromByteCount: Int64(node.displaySize), countStyle: .file)
                    : "—"
            } else {
                cell.textField?.stringValue = ByteCountFormatter.string(
                    fromByteCount: Int64(node.displaySize), countStyle: .file
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
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = id

        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 11)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        if hasIcon {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }
}
