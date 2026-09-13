import Foundation
import AppKit
import Quartz

/// 压缩包内容预览窗口 (双击 zip 打开 / 设置里选"预览"时的呈现载体)。
/// 纯 AppKit 实现,与 QuickLook 扩展共用同一套解析管线 (MacZipCore.ZipReader)
/// 与层级树模型 (MacZipCore.ZipEntryTree)。
///
/// 布局:顶部工具栏 (增加/提取/全部解压/删除/清理 + 搜索) + 左侧条目表 + 右侧内容预览。
/// 交互:支持多选;选中文件即按需解压到临时文件并用 QuickLook 渲染内容,
/// 目录与未选中项显示占位提示;加密文件先试密码本,再弹窗询问。
/// 内容编辑 (增加/删除/清理) 通过 MacZipCore.ZipArchiveEditor 原样搬运负载,保留压缩率。
final class ArchivePreviewWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    /// 存活的预览窗口控制器 (NSWindowController 需强引用,否则窗口随控制器释放);
    /// 窗口关闭时移除。多窗口:每个压缩包一个窗口。
    private static var activeControllers: [ArchivePreviewWindowController] = []
    /// 首个窗口恢复上次框架位置,后续窗口居中 (避免多窗口争用同一 frame autosave)。
    private static var primaryWindowFrameRestored = false
    private static let frameAutosaveName = "MacZipPreviewWindow"

    /// 打开 (或聚焦) 一个压缩包的内容预览窗口。同一压缩包已打开时置前复用,
    /// 不同压缩包各自开新窗口。须在主线程调用。
    static func show(archive url: URL) {
        let target = url.standardizedFileURL
        if let existing = activeControllers.first(where: { $0.archiveURL == target }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ArchivePreviewWindowController()
        activeControllers.append(controller)
        controller.show(archive: url)
    }

    private var archiveURL: URL?
    private var archiveSize: UInt64 = 0
    /// 当前归档格式 (决定是否允许内容编辑)。
    private var archiveFormat: ArchiveFormat?
    /// 统一内容读取器 (ZIP 家族 / TAR 家族),供按需抽取与密码校验。
    private var reader: ArchiveContentReader?
    /// 完整层级树。
    private var roots: [ZipEntryNode] = []
    /// 当前展示的树 (搜索过滤后,无关键字时同 roots)。
    private var visibleRoots: [ZipEntryNode] = []
    /// 底部状态栏的压缩包摘要 (不含选择状态)。
    private var archiveSummary = ""

    private var outlineView: NSOutlineView!
    private var nameColumn: NSTableColumn!
    private var listScrollView: NSScrollView!
    private var headerIcon: NSImageView!
    private var titleLabel: NSTextField!
    private var summaryLabel: NSTextField!
    private var searchField: NSSearchField!
    private var pathLabel: NSTextField!
    private var addButton: NSButton!
    private var extractButton: NSButton!
    private var deleteButton: NSButton!
    private var commentButton: NSButton!
    private weak var cleanButtonRef: NSButton?

    // MARK: 预览面板
    private var splitView: NSSplitView!
    private var previewContainer: NSView!
    private var previewIcon: NSImageView!
    private var previewTitleLabel: NSTextField!
    private var previewDetailLabel: NSTextField!
    private var previewOpenButton: NSButton!
    private var qlPreviewView: QLPreviewView?
    private var previewStatusLabel: NSTextField!
    private var previewSpinner: NSProgressIndicator!

    /// 选中变化防抖:方向键快速滚动时避免每行都触发解压。
    private var extractionWorkItem: DispatchWorkItem?
    /// 本次窗口会话的预览临时目录;关闭时整体清理。
    private var previewSessionDir: URL?
    /// 当前已解压并展示的临时文件 (用于"用默认程序打开"与切换时清理)。
    private var currentPreviewFile: URL?
    /// 当前预览对应的归档内路径 (双击文件时判定是否可直接打开)。
    private var currentPreviewNodePath: String?
    /// 本会话内用户确认过的密码 (后续加密条目直接复用)。
    private var resolvedPassword: String?
    /// 异步解压代际标记:选中项已变化时丢弃过期结果。
    private var previewToken = UUID()
    private var didSetInitialSplit = false

    /// 头部搜索框高度 (alignment rect)。rounded 按钮的边框视觉高度固定且不随约束
    /// 伸缩,实测把搜索框钉到 22pt 时两者渲染边缘逐像素重合,故不用按钮的 24pt 名义值。
    private static let searchFieldHeight: CGFloat = 22
    /// 底部状态栏高度。
    private static let footerHeight: CGFloat = 30
    /// 单文件内容预览上限:超过则只展示元信息,避免为超大条目解压占用大量磁盘/时间。
    private static let previewSizeLimit: UInt64 = 200 * 1024 * 1024
    /// 分隔条两侧最小宽度。名称列可收缩至 100,四列固定部分约 326 + 列间距,
    /// 故 500 可完整容纳且保持紧凑。
    private static let minListWidth: CGFloat = 500
    private static let minPreviewWidth: CGFloat = 200
    /// 首次展示时分隔条位置 (列表占比)。
    private static let initialListRatio: CGFloat = 0.64

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 760, height: 400)
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    // MARK: - UI 构建

    private func buildUI() {
        guard let window, let contentView = window.contentView else { return }

        headerIcon = NSImageView()
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        headerIcon.contentTintColor = .controlAccentColor
        headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [titleLabel, summaryLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        addButton = makeTextButton("增加", action: #selector(addClicked))
        extractButton = makeTextButton("提取", action: #selector(extractSelectedClicked))
        let extractAllButton = makeTextButton("全部解压", action: #selector(extractAllClicked))
        deleteButton = makeTextButton("删除", action: #selector(deleteClicked))
        let cleanButton = makeTextButton("清理", action: #selector(cleanClicked))
        cleanButtonRef = cleanButton
        commentButton = makeTextButton("注释", action: #selector(commentClicked))

        extractButton.isEnabled = false
        deleteButton.isEnabled = false

        searchField = NSSearchField()
        searchField.placeholderString = "搜索文件"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let header = NSStackView(views: [
            headerIcon, titleStack, spacer,
            addButton, extractButton, extractAllButton, deleteButton, cleanButton, commentButton,
            searchField
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        // 条目表:名称 + 大小 + 修改日期 + 种类,多选。
        outlineView = NSOutlineView()
        outlineView.style = .inset
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 12
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = false

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = 200
        nameColumn.minWidth = 100
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.title = "名称"
        outlineView.addTableColumn(nameColumn)
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.width = 80
        sizeColumn.minWidth = 80
        sizeColumn.maxWidth = 80
        sizeColumn.resizingMask = []
        sizeColumn.title = "大小"
        outlineView.addTableColumn(sizeColumn)
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.width = 118
        dateColumn.minWidth = 118
        dateColumn.maxWidth = 118
        dateColumn.resizingMask = []
        dateColumn.title = "修改日期"
        outlineView.addTableColumn(dateColumn)
        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.width = 96
        kindColumn.minWidth = 96
        kindColumn.maxWidth = 96
        kindColumn.resizingMask = []
        kindColumn.title = "种类"
        outlineView.addTableColumn(kindColumn)

        outlineView.outlineTableColumn = nameColumn
        outlineView.headerView = FlatTableHeaderView()
        self.nameColumn = nameColumn
        nameColumn.headerCell.alignment = .left
        sizeColumn.headerCell.alignment = .right
        dateColumn.headerCell.alignment = .right
        kindColumn.headerCell.alignment = .left
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        outlineView.menu = makeContextMenu()

        let scrollView = NSScrollView()
        listScrollView = scrollView
        // 表格宽度强制跟随可见区宽度:交给列自动分配去收缩名称列,避免缩窗时最右列被
        // 裁掉。NSTableView 作为 documentView 默认用 autoresizing,必须显式关闭才能让
        // 宽度约束生效(否则约束会被丢弃)。
        outlineView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outlineView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
        // 保证紧凑窗口下列表仍有最小可读宽度。
        let listMinWidth = scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minListWidth)
        listMinWidth.priority = NSLayoutConstraint.Priority(999)
        listMinWidth.isActive = true

        previewContainer = buildPreviewPane()

        // 左右分栏:列表 | 内容预览;分隔条可拖动但强制列表最小宽度,避免列被裁切。
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(previewContainer)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(header)
        contentView.addSubview(divider)
        contentView.addSubview(splitView)
        contentView.addSubview(footer)
        footer.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            headerIcon.widthAnchor.constraint(equalToConstant: 26),
            headerIcon.heightAnchor.constraint(equalToConstant: 26),

            searchField.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),
            searchField.widthAnchor.constraint(equalToConstant: 160),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            splitView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),

            pathLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            pathLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    /// 右侧内容预览面板:文件信息条 + QuickLook 内容视图 + 状态占位。
    private func buildPreviewPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        previewIcon = NSImageView()
        previewIcon.translatesAutoresizingMaskIntoConstraints = false
        previewIcon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        previewIcon.contentTintColor = .tertiaryLabelColor
        previewIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)

        previewTitleLabel = NSTextField(labelWithString: "未选择文件")
        previewTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        previewTitleLabel.lineBreakMode = .byTruncatingMiddle
        previewTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        previewDetailLabel = NSTextField(labelWithString: "选择左侧文件以预览内容")
        previewDetailLabel.font = .systemFont(ofSize: 10)
        previewDetailLabel.textColor = .secondaryLabelColor
        previewDetailLabel.lineBreakMode = .byTruncatingTail
        previewDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [previewTitleLabel, previewDetailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        previewOpenButton = NSButton(title: "用默认程序打开", target: self, action: #selector(openPreviewExternally))
        previewOpenButton.bezelStyle = .rounded
        previewOpenButton.controlSize = .small
        previewOpenButton.isEnabled = false
        previewOpenButton.translatesAutoresizingMaskIntoConstraints = false

        // QuickLook 统一渲染文本/图片/PDF/音视频/Office 等,复用系统预览引擎。
        // 初始占位视图仅撑起布局;每次实际预览会换成全新视图 (见 presentWithFreshPreviewView)。
        let initialQLView = QLPreviewView(frame: .zero, style: .normal)!
        initialQLView.autostarts = true
        initialQLView.isHidden = true
        initialQLView.translatesAutoresizingMaskIntoConstraints = false
        qlPreviewView = initialQLView

        previewStatusLabel = NSTextField(wrappingLabelWithString: "选择左侧文件以预览内容")
        previewStatusLabel.alignment = .center
        previewStatusLabel.font = .systemFont(ofSize: 12)
        previewStatusLabel.textColor = .secondaryLabelColor
        previewStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        previewSpinner = NSProgressIndicator()
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .small
        previewSpinner.isDisplayedWhenStopped = false
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(previewIcon)
        pane.addSubview(textStack)
        pane.addSubview(previewOpenButton)
        pane.addSubview(initialQLView)
        pane.addSubview(previewStatusLabel)
        pane.addSubview(previewSpinner)

        NSLayoutConstraint.activate([
            previewIcon.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            previewIcon.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            previewIcon.widthAnchor.constraint(equalToConstant: 18),
            previewIcon.heightAnchor.constraint(equalToConstant: 18),

            textStack.leadingAnchor.constraint(equalTo: previewIcon.trailingAnchor, constant: 7),
            textStack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 7),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: previewOpenButton.leadingAnchor, constant: -8),

            previewOpenButton.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            previewOpenButton.centerYAnchor.constraint(equalTo: previewIcon.centerYAnchor),

            initialQLView.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 8),
            initialQLView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            initialQLView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            initialQLView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),

            previewStatusLabel.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            previewStatusLabel.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            previewStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: 20),
            previewStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -20),

            previewSpinner.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            previewSpinner.bottomAnchor.constraint(equalTo: previewStatusLabel.topAnchor, constant: -8)
        ])

        return pane
    }

    private func makeTextButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "提取…", action: #selector(extractSelectedClicked), keyEquivalent: "")
        menu.addItem(withTitle: "删除", action: #selector(deleteClicked), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "展开全部", action: #selector(expandAllClicked), keyEquivalent: "")
        menu.addItem(withTitle: "折叠全部", action: #selector(collapseAllClicked), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: - 数据加载

    /// 展示一个压缩包的内容列表 (ZIP 家族 / TAR / TAR.GZ 走内建解析;其余格式回退为直接解压)。
    func show(archive url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            ToastHUD.showAsync(title: "文件不存在", content: url.lastPathComponent, isSuccess: false)
            return
        }

        // 不支持内容清单的格式 (7z/rar/单文件 gz 等) 回退到"直接解压",避免与
        // openArchives 的预览分支互相调用造成递归。
        guard let format = ArchiveFormat.detect(url: url), format.supportsContentPreview else {
            ActionCoordinator.shared.extractSingle(target: url)
            return
        }
        archiveFormat = format
        archiveURL = url.standardizedFileURL

        guard let window else { return }
        window.title = url.lastPathComponent
        if !Self.primaryWindowFrameRestored {
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)
            Self.primaryWindowFrameRestored = true
        } else {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        searchField.stringValue = ""
        didSetInitialSplit = false
        reloadArchive(preserveSearch: false)

        DispatchQueue.main.async { [weak self] in
            self?.applyInitialSplitIfNeeded()
        }

    }

    /// 重新解析当前压缩包并刷新界面 (内容编辑后调用)。
    private func reloadArchive(preserveSearch: Bool = true) {
        guard let url = archiveURL else { return }
        archiveSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0

        let contentReader: ArchiveContentReader
        let parsed: [ZipEntryInfo]
        do {
            contentReader = try ArchiveContentReader.open(url: url)
            parsed = try contentReader.listEntries()
        } catch {
            ToastHUD.showAsync(title: "无法读取压缩包", content: error.localizedDescription, isSuccess: false)
            return
        }
        self.reader = contentReader
        resetPreviewSession()

        roots = ZipEntryTree.build(from: parsed)

        let query = preserveSearch ? searchField.stringValue.trimmingCharacters(in: .whitespaces) : ""
        if query.isEmpty {
            visibleRoots = roots
        } else {
            visibleRoots = roots.compactMap { $0.filtered(matching: query) }
        }

        let counts = ZipEntryTree.counts(in: roots)
        let encrypted = roots.contains { $0.isEncrypted }
        var summary = "\(counts.files) 个文件"
        if counts.folders > 0 { summary += " · \(counts.folders) 个文件夹" }
        if encrypted { summary += " · 🔒 已加密" }
        if archiveSize > 0 {
            summary += " · 压缩包 \(ByteCountFormatter.string(fromByteCount: Int64(archiveSize), countStyle: .file))"
        }
        summaryLabel.stringValue = summary
        titleLabel.stringValue = url.lastPathComponent
        archiveSummary = summary

        outlineView.reloadData()
        if query.isEmpty {
            expandInitialLevel()
        } else {
            outlineView.expandItem(nil, expandChildren: true)
        }
        resetPreview()
        updateToolbarState()
        updateStatusText()
    }

    /// 初始只展开顶层目录,保持界面清爽;单根目录时再下探一层。
    private func expandInitialLevel() {
        for node in visibleRoots where node.isDirectory && !node.children.isEmpty {
            outlineView.expandItem(node)
        }
        if visibleRoots.count == 1, let only = visibleRoots.first, only.isDirectory {
            for child in only.children where child.isDirectory {
                outlineView.expandItem(child)
            }
        }
    }

    /// 首次展示时把分隔条放在偏左位置,并保证列表宽度不低于最小可读宽度。
    private func applyInitialSplitIfNeeded() {
        guard !didSetInitialSplit, let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let width = splitView.bounds.width
        guard width > 0 else { return }
        let desired = max(Self.minListWidth, width * Self.initialListRatio)
        splitView.setPosition(min(desired, width - Self.minPreviewWidth), ofDividerAt: 0)
        didSetInitialSplit = true
        fitListColumns()
    }

    /// 让名称列吸收列表宽度的余量:固定列(大小/修改日期/种类)保持原宽,名称列伸缩,
    /// 保证缩窗时四列都完整可见而非最右列被裁掉。
    private func fitListColumns() {
        guard let scrollView = listScrollView, let nameColumn else { return }
        let available = scrollView.contentSize.width
        guard available > 0 else { return }
        let others = outlineView.tableColumns
            .filter { $0 !== nameColumn }
            .reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = outlineView.intercellSpacing.width * CGFloat(outlineView.tableColumns.count + 1)
        let nameWidth = max(nameColumn.minWidth, available - others - spacing)
        if abs(nameColumn.width - nameWidth) > 0.5 {
            nameColumn.width = nameWidth
        }
    }

    // MARK: - 动作

    @objc private func expandAllClicked() {
        outlineView.expandItem(nil, expandChildren: true)
    }

    @objc private func collapseAllClicked() {
        outlineView.collapseItem(nil, collapseChildren: true)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            visibleRoots = roots
        } else {
            visibleRoots = roots.compactMap { $0.filtered(matching: query) }
        }
        outlineView.reloadData()
        if query.isEmpty {
            expandInitialLevel()
        } else {
            outlineView.expandItem(nil, expandChildren: true)
        }
        resetPreview()
        updateStatusText()
    }

    @objc private func rowDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ZipEntryNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if currentPreviewNodePath == node.path {
            // 双击已解压的文件:交给默认程序打开。
            openPreviewExternally()
        }
    }

    @objc private func extractAllClicked() {
        guard let url = archiveURL else { return }
        ActionCoordinator.shared.extractSingle(target: url)
    }

    /// 提取选中条目到用户选择的目录。
    @objc private func extractSelectedClicked() {
        let nodes = selectedNodes()
        guard !nodes.isEmpty else { return }
        let entries = nodes.compactMap { $0.entry }
        guard !entries.isEmpty else {
            ToastHUD.showAsync(title: "无法提取", content: "请选择具体文件", isSuccess: false)
            return
        }
        guard let destination = chooseFolderOnMain(title: "提取到") else { return }
        guard let archive = archiveURL, let format = archiveFormat else { return }

        let progress = ProgressWindowController()
        // ZIP 家族走 ArchiveService (支持密码本 / 冲突策略);TAR 家族由内建读取器直接抽取。
        if format.isZipFamily {
            let useBook = SharedStorageManager.shared.getBool(
                forKey: MacZipSettings.preferPasswordBook, defaultValue: true
            )
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ArchiveService.shared.extract(
                        archive: archive,
                        entries: entries,
                        destination: destination,
                        preferPasswordBook: useBook,
                        conflictPolicy: self.currentConflictPolicy(),
                        passwordPrompt: { [weak self] _, round in
                            self?.promptPassword(title: "解压加密压缩包", round: round)
                        },
                        reporter: progress
                    )
                } catch is CancellationError {
                    progress.close()
                } catch {
                    progress.fail(message: error.localizedDescription)
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let reader = self.reader else { return }
                do {
                    let policy = self.currentConflictPolicy()
                    progress.begin(totalBytes: entries.reduce(0) { $0 + $1.uncompressedSize }, title: "正在提取")
                    for entry in entries {
                        if progress.isCancelled { throw ZipError.cancelled }
                        guard let target = self.resolveTarDestination(entry, in: destination, policy: policy) else { continue }
                        try reader.extractEntry(entry, to: target, password: nil)
                    }
                    progress.finish(message: "提取完成", subtitle: destination.lastPathComponent)
                } catch is CancellationError {
                    progress.close()
                } catch {
                    progress.fail(message: error.localizedDescription)
                }
            }
        }
    }

    /// TAR 系提取的目标路径:还原归档内相对路径,并按冲突策略避让。
    /// 返回 nil 表示按 skip 策略跳过。
    private func resolveTarDestination(
        _ entry: ZipEntryInfo,
        in destination: URL,
        policy: ZipReader.ConflictPolicy
    ) -> URL? {
        let components = entry.name.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        let target = components.reduce(destination) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: target.path) else { return target }
        switch policy {
        case .overwrite: return target
        case .skip: return nil
        case .rename:
            let dir = target.deletingLastPathComponent()
            let stem = (target.lastPathComponent as NSString).deletingPathExtension
            let ext = (target.lastPathComponent as NSString).pathExtension
            var counter = 1
            var candidate = target
            while FileManager.default.fileExists(atPath: candidate.path) {
                counter += 1
                let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                candidate = dir.appendingPathComponent(name)
            }
            return candidate
        }
    }

    /// 删除选中条目 (目录连同子树),原样搬运其余负载,重写压缩包。
    @objc private func deleteClicked() {
        let nodes = selectedNodes()
        guard !nodes.isEmpty, let archive = archiveURL else { return }
        guard archiveFormat?.supportsEditing == true else {
            ToastHUD.showAsync(title: "暂不支持编辑", content: "该格式仅支持预览与解压", isSuccess: false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除所选 \(nodes.count) 项?"
        alert.informativeText = "将从压缩包中移除所选内容(目录连同其下所有文件)。此操作会重写压缩包,且不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let paths = Set(nodes.map { $0.path })
        let progress = ProgressWindowController()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                _ = try ZipArchiveEditor.delete(paths: paths, from: archive, reporter: progress)
                DispatchQueue.main.async { self?.reloadArchive() }
            } catch is CancellationError {
                progress.close()
            } catch {
                progress.fail(message: error.localizedDescription)
            }
        }
    }

    /// 清理系统隐藏文件 (.DS_Store / __MACOSX 等)。
    @objc private func cleanClicked() {
        guard let archive = archiveURL else { return }
        guard archiveFormat?.supportsEditing == true else {
            ToastHUD.showAsync(title: "暂不支持编辑", content: "该格式仅支持预览与解压", isSuccess: false)
            return
        }
        let progress = ProgressWindowController()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let removed = try ZipArchiveEditor.cleanSystemJunk(in: archive, reporter: progress)
                if removed == 0 {
                    progress.close()
                    ToastHUD.showAsync(title: "无需清理", content: "压缩包内没有系统隐藏文件", isSuccess: true)
                } else {
                    DispatchQueue.main.async { self?.reloadArchive() }
                }
            } catch is CancellationError {
                progress.close()
            } catch {
                progress.fail(message: error.localizedDescription)
            }
        }
    }

    /// 查看 / 编辑 ZIP 归档注释 (只重写 EOCD 尾部;空文本即清除)。
    @objc private func commentClicked() {
        guard let archive = archiveURL, archiveFormat?.supportsEditing == true else { return }
        let current = (try? ZipArchiveEditor.comment(of: archive)) ?? ""

        let alert = NSAlert()
        alert.messageText = "压缩包注释"
        alert.informativeText = "查看或编辑 ZIP 归档注释;清空文本即删除注释。"
        alert.alertStyle = .informational

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        textView.string = current
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated = textView.string

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ZipArchiveEditor.setComment(updated, on: archive)
                DispatchQueue.main.async {
                    ToastHUD.showAsync(
                        title: updated.isEmpty ? "注释已清除" : "注释已保存",
                        content: archive.lastPathComponent,
                        isSuccess: true
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    ToastHUD.showAsync(title: "注释保存失败", content: error.localizedDescription, isSuccess: false)
                }
            }
        }
    }

    /// 增加文件/目录到压缩包 (选中单个目录时挂到该目录下,否则放到根目录)。
    @objc private func addClicked() {
        guard let archive = archiveURL else { return }
        guard archiveFormat?.supportsEditing == true else {
            ToastHUD.showAsync(title: "暂不支持编辑", content: "该格式仅支持预览与解压", isSuccess: false)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "增加"
        panel.message = "选择要加入压缩包的文件或文件夹"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let inputs = panel.urls
        guard !inputs.isEmpty else { return }

        // 选中单个目录时作为目标子目录。
        let nodes = selectedNodes()
        let folder: String? = {
            guard nodes.count == 1, let only = nodes.first, only.isDirectory else { return nil }
            return only.path
        }()

        let progress = ProgressWindowController()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let password = try self.mutationPasswordIfNeeded()
                let level = ZlibCodec.Level(
                    rawValue: SharedStorageManager.shared.getString(
                        forKey: MacZipSettings.compressionLevel, defaultValue: "standard"
                    )
                ) ?? .standard
                _ = try ZipArchiveEditor.add(
                    inputs: inputs,
                    to: archive,
                    into: folder,
                    password: password,
                    level: level,
                    useAES: SharedStorageManager.shared.getBool(
                        forKey: MacZipSettings.zipUseAES256, defaultValue: false
                    ),
                    reporter: progress
                )
                DispatchQueue.main.async { self.reloadArchive() }
            } catch is CancellationError {
                progress.close()
            } catch {
                progress.fail(message: error.localizedDescription)
            }
        }
    }

    // MARK: - 选择 / 状态

    private func selectedNodes() -> [ZipEntryNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ZipEntryNode }
    }

    private func updateToolbarState() {
        let hasSelection = !outlineView.selectedRowIndexes.isEmpty
        let editable = archiveFormat?.supportsEditing ?? false
        extractButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection && editable
        addButton.isEnabled = editable
        cleanButtonRef?.isEnabled = editable
        commentButton.isEnabled = editable
    }

    private func updateStatusText() {
        var parts: [String] = []
        if !archiveSummary.isEmpty { parts.append(archiveSummary) }
        let selected = outlineView.selectedRowIndexes.count
        if selected > 0 {
            parts.append("已选择 \(selected) 项")
            if selected == 1, let node = selectedNodes().first {
                parts.append(node.isDirectory ? node.path + "/" : node.path)
            }
        }
        pathLabel.stringValue = parts.joined(separator: "  |  ")
    }

    /// 压缩包含加密条目时解析可用密码 (密码本优先,再弹窗;最多 3 次)。
    /// 返回 nil 表示无需密码;用户取消抛 `CancellationError`。
    private func mutationPasswordIfNeeded() throws -> String? {
        guard let reader, let url = archiveURL else { return nil }
        guard let encrypted = try reader.listEntries().first(where: { $0.isEncrypted && !$0.isDirectory }) else {
            return nil
        }
        for candidate in PasswordBook.shared.passwords where !candidate.isEmpty {
            if (try? reader.verifyPassword(candidate, for: encrypted)) == true { return candidate }
        }
        for round in 1...3 {
            guard let entered = promptPassword(title: "该压缩包已加密", round: round), !entered.isEmpty else {
                throw CancellationError()
            }
            if (try? reader.verifyPassword(entered, for: encrypted)) == true {
                _ = PasswordBook.shared.add(PasswordEntry(title: url.lastPathComponent, password: entered))
                return entered
            }
        }
        throw ZipError.wrongPassword
    }

    // MARK: - 主线程交互

    private func promptPassword(title: String, round: Int) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let hint = round > 1 ? " (第 \(round) 次尝试)" : ""
        alert.informativeText = "请输入密码\(hint)。"
        alert.alertStyle = .informational
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "密码"
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func chooseFolderOnMain(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = title
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func currentConflictPolicy() -> ZipReader.ConflictPolicy {
        ZipReader.ConflictPolicy(
            rawValue: SharedStorageManager.shared.getString(
                forKey: MacZipSettings.conflictPolicy, defaultValue: "rename"
            )
        ) ?? .rename
    }

    // MARK: - 内容预览

    /// 选中项变化:目录/空选清空预览,文件进入防抖解压流程。
    private func updatePreviewForSelection() {
        extractionWorkItem?.cancel()
        extractionWorkItem = nil
        previewToken = UUID()

        guard outlineView.selectedRowIndexes.count == 1,
              let node = selectedNodes().first else {
            resetPreview()
            return
        }
        if node.isDirectory {
            resetPreview(message: "文件夹不支持内容预览")
            return
        }
        guard let entry = node.entry else {
            resetPreview()
            return
        }

        let token = previewToken
        let work = DispatchWorkItem { [weak self] in
            self?.loadPreview(node: node, entry: entry, token: token)
        }
        extractionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// 按需把选中条目解压到临时文件,再交给 QuickLook 渲染。
    private func loadPreview(node: ZipEntryNode, entry: ZipEntryInfo, token: UUID) {
        guard let reader else { return }

        previewTitleLabel.stringValue = node.name
        previewDetailLabel.stringValue = detailText(for: entry)
        previewIcon.image = NSImage(systemSymbolName: Self.iconName(for: node), accessibilityDescription: nil)
        previewIcon.contentTintColor = entry.isEncrypted ? .systemOrange : .secondaryLabelColor
        previewOpenButton.isEnabled = false

        guard entry.uncompressedSize <= Self.previewSizeLimit else {
            showPreviewStatus(
                "文件较大 (\(ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file))),已跳过内容预览"
            )
            return
        }

        showPreviewStatus("正在解压…", spinner: true)
        let target = freshPreviewURL(for: node)
        let password = resolvedPassword
        let candidates = PasswordBook.shared.passwords
        let previousFile = currentPreviewFile

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try reader.extractEntry(entry, to: target, password: password, passwordCandidates: candidates)
                DispatchQueue.main.async {
                    guard self.previewToken == token else { return }
                    self.currentPreviewFile = target
                    self.currentPreviewNodePath = node.path
                    if let previousFile, previousFile != target {
                        try? FileManager.default.removeItem(at: previousFile)
                    }
                    self.presentPreview(url: target)
                }
            } catch let error as ZipError where error == .wrongPassword {
                DispatchQueue.main.async {
                    guard self.previewToken == token else { return }
                    self.promptForPasswordAndRetry(node: node, entry: entry)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.previewToken == token else { return }
                    self.showPreviewStatus("无法预览:\(error.localizedDescription)")
                }
            }
        }
    }

    private func presentPreview(url: URL) {
        previewStatusLabel.isHidden = true
        previewSpinner.stopAnimation(nil)
        presentWithFreshPreviewView(url: url)
        previewOpenButton.isEnabled = true
    }

    /// 用全新 QLPreviewView 呈现预览,替换并丢弃旧视图。
    ///
    /// 为什么不复用视图:QLPreviewView 在窗口被 orderOut、闲置、应用激活状态
    /// 变化等情况下会进入 Deactivated 内部状态,而对其设置非空 previewItem 时
    /// QuickLook 直接断言崩溃 (反汇编实证: item == nil || internalState !=
    /// QLPreviewDeactivatedInternalState)——单例窗口关闭重开后的第一次预览必崩。
    /// 新视图创建后立即设置条目,不存在被停用的窗口期。
    private func presentWithFreshPreviewView(url: URL) {
        let fresh = QLPreviewView(frame: .zero, style: .normal)!
        fresh.autostarts = true
        fresh.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(fresh)
        NSLayoutConstraint.activate([
            fresh.topAnchor.constraint(equalTo: previewIcon.bottomAnchor, constant: 8),
            fresh.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            fresh.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            fresh.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])
        fresh.isHidden = false
        fresh.previewItem = url as NSURL
        fresh.refreshPreviewItem()

        qlPreviewView?.removeFromSuperview()
        qlPreviewView = fresh
    }

    private func showPreviewStatus(_ message: String, spinner: Bool = false) {
        // 只隐藏视图、不置空 previewItem:对可能已 Deactivated 的视图设 nil 虽合法,
        // 但重建式呈现下旧视图即将被丢弃,无需清理。
        qlPreviewView?.isHidden = true
        previewStatusLabel.stringValue = message
        previewStatusLabel.isHidden = false
        if spinner {
            previewSpinner.startAnimation(nil)
        } else {
            previewSpinner.stopAnimation(nil)
        }
    }

    private func resetPreview(message: String = "选择左侧文件以预览内容") {
        previewToken = UUID()
        previewTitleLabel.stringValue = "未选择文件"
        previewDetailLabel.stringValue = "选择左侧文件以预览内容"
        previewIcon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        previewIcon.contentTintColor = .tertiaryLabelColor
        previewOpenButton.isEnabled = false
        currentPreviewNodePath = nil
        showPreviewStatus(message)
    }

    private func detailText(for entry: ZipEntryInfo) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)]
        let ext = (entry.name as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        if entry.isEncrypted { parts.append("🔒 已加密") }
        if let date = entry.lastModified { parts.append(dateFormatter.string(from: date)) }
        return parts.joined(separator: " · ")
    }

    /// 加密条目且密码本未命中:弹窗询问,成功后重试。
    private func promptForPasswordAndRetry(node: ZipEntryNode, entry: ZipEntryInfo) {
        let alert = NSAlert()
        alert.messageText = "压缩包已加密"
        alert.informativeText = "请输入「\(node.name)」的密码以预览内容。"
        alert.alertStyle = .informational
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "密码"
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "保存到密码本"
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            showPreviewStatus("已加密,未提供密码,无法预览")
            return
        }
        let password = input.stringValue
        guard !password.isEmpty else {
            showPreviewStatus("已加密,未提供密码,无法预览")
            return
        }
        if alert.suppressionButton?.state == .on {
            _ = PasswordBook.shared.add(PasswordEntry(title: node.name, password: password))
        }
        resolvedPassword = password
        let token = previewToken
        loadPreview(node: node, entry: entry, token: token)
    }

    @objc private func openPreviewExternally() {
        guard let file = currentPreviewFile else { return }
        NSWorkspace.shared.open(file)
    }

    // MARK: - 预览临时文件

    /// 会话级临时目录:首次预览时惰性创建,窗口关闭时整体删除。
    private func ensurePreviewSessionDir() -> URL {
        if let dir = previewSessionDir { return dir }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacZipPreview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        previewSessionDir = dir
        return dir
    }

    /// 每次预览使用唯一文件名,避免 QuickLook 依据同一路径缓存旧内容。
    private func freshPreviewURL(for node: ZipEntryNode) -> URL {
        let dir = ensurePreviewSessionDir()
        let last = (node.path as NSString).lastPathComponent
        let safe = (last.isEmpty ? "preview" : last).replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safe)")
    }

    private func resetPreviewSession() {
        extractionWorkItem?.cancel()
        extractionWorkItem = nil
        previewToken = UUID()
        resolvedPassword = nil
        currentPreviewFile = nil
        currentPreviewNodePath = nil
        if let dir = previewSessionDir {
            try? FileManager.default.removeItem(at: dir)
        }
        previewSessionDir = nil
    }

    func windowWillClose(_ notification: Notification) {
        resetPreviewSession()
        reader = nil
        roots = []
        visibleRoots = []
        archiveURL = nil
        Self.activeControllers.removeAll { $0 === self }
    }

    // MARK: - NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        fitListColumns()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, Self.minListWidth)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - Self.minPreviewWidth)
    }
}

// MARK: - 树数据源 / 委托

extension ArchivePreviewWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ZipEntryNode else { return visibleRoots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ZipEntryNode else { return visibleRoots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ZipEntryNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updatePreviewForSelection()
        updateToolbarState()
        updateStatusText()
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
                imageView.image = NSImage(systemSymbolName: Self.iconName(for: node), accessibilityDescription: nil)
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
        textField.font = .systemFont(ofSize: 11.5)
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

    /// 依据扩展名挑选 SF Symbol,让列表更直观。
    private static func iconName(for node: ZipEntryNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg", "icns":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v", "flv", "wmv":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "zip", "7z", "rar", "gz", "tar", "bz2", "xz", "tgz":
            return "doc.zipper"
        case "txt", "md", "rtf", "log":
            return "doc.text"
        case "swift", "js", "ts", "py", "c", "cc", "cpp", "h", "hpp", "java", "rb", "go", "rs",
             "json", "xml", "html", "css", "sh", "yml", "yaml", "sql":
            return "chevron.left.forwardslash.chevron.right"
        case "app", "dmg", "pkg":
            return "shippingbox"
        case "xls", "xlsx", "csv", "numbers":
            return "tablecells"
        case "ppt", "pptx", "key":
            return "rectangle.on.rectangle"
        case "doc", "docx", "pages":
            return "doc.text"
        default:
            return "doc"
        }
    }
}
