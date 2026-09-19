import AppKit

/// 使用 AppKit 传入的真实表头 cell frame 绘制标题。
///
/// 表头和正文不能分别读取 NSTableView 的列坐标再手工拼接,因为两者可能处于
/// 不同的滚动坐标系。让 NSTableHeaderView 调用 header cell,可以保持列宽、
/// 横向滚动、拖动命中区域和标题位置一致。
///
/// 对齐契约:表格把 intercellSpacing.width 置 0 后,内容 cell 视图与列矩形
/// 完全重合,因此表头标题只要使用与内容文本相同的左右内边距,即可实现
/// 像素级对齐——左对齐列传 leadingInset,右对齐列传 trailingInset,
/// 数值与两侧窗口的内容 cell 内边距保持一致 (8pt)。
final class FlatTableHeaderCell: NSTableHeaderCell {
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let textHeight: CGFloat = 16

    /// 标题距列左缘的内边距 (左对齐列使用)。
    let leadingInset: CGFloat
    /// 标题距列右缘的内边距 (右对齐列使用)。
    let trailingInset: CGFloat

    init(
        title: String,
        alignment: NSTextAlignment,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0
    ) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        super.init(textCell: title)
        self.alignment = alignment
        lineBreakMode = .byTruncatingTail
        isEditable = false
        isSelectable = false
    }

    required init(coder: NSCoder) {
        leadingInset = 0
        trailingInset = 0
        super.init(coder: coder)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard !title.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let contentRect = NSRect(
            x: cellFrame.minX + leadingInset,
            y: cellFrame.minY,
            width: max(0, cellFrame.width - leadingInset - trailingInset),
            height: cellFrame.height
        )
        guard contentRect.width > 0 else { return }

        let textSize = (title as NSString).size(withAttributes: attributes)
        let textWidth = min(ceil(textSize.width), contentRect.width)
        let textX: CGFloat
        switch alignment {
        case .right:
            textX = contentRect.maxX - textWidth
        case .center:
            textX = contentRect.midX - textWidth / 2
        default:
            textX = contentRect.minX
        }
        let textRect = NSRect(
            x: textX,
            y: contentRect.midY - Self.textHeight / 2,
            width: textWidth,
            height: Self.textHeight
        )
        (title as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }
}

final class FlatTableHeaderView: NSTableHeaderView {
    static let preferredHeight: CGFloat = 26
    /// 列间分隔刻度距表头上下边缘的内缩;短刻度比通高竖线更含蓄,
    /// 同时保留拖拽列宽的视觉锚点 (拖拽命中区仍是整个列边界)。
    private static let tickInset: CGFloat = 8

    /// 不透明底色带。标准表头底色/底线是半透明材质,在不同宿主下混合结果差异
    /// 很大:预览窗 (不透明白底) 里表头近乎白色,还要靠一条较重的底部边线才能
    /// 与行内容区分;QuickLook (半透明面板) 里则被材质吃掉显得很淡。改为自绘
    /// 固定灰带,两个宿主渲染一致,观感对齐 QuickLook 面板。
    private static let bandColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(red: 0.161, green: 0.161, blue: 0.169, alpha: 1)
            : NSColor(red: 0.925, green: 0.925, blue: 0.925, alpha: 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    override func layout() {
        super.layout()
        guard abs(frame.height - Self.preferredHeight) > 0.5 else { return }
        var adjustedFrame = frame
        adjustedFrame.size.height = Self.preferredHeight
        frame = adjustedFrame
    }

    override func draw(_ dirtyRect: NSRect) {
        // 不调用 super:原生绘制会叠加它自己的底色、列分割线和底部边线。
        // 底色带就位后逐列调用 headerCell 画标题 (FlatTableHeaderCell 只画
        // 文字),最后叠一层极淡的列间刻度。
        Self.bandColor.setFill()
        dirtyRect.fill()

        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            column.headerCell.draw(withFrame: rect, in: self)
        }

        drawSeparators(in: dirtyRect)
    }

    private func drawSeparators(in dirtyRect: NSRect) {
        guard let tableView, tableView.numberOfColumns > 1 else { return }
        NSColor.black.withAlphaComponent(0.10).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        for columnIndex in 0..<(tableView.numberOfColumns - 1) {
            let rect = headerRect(ofColumn: columnIndex)
            guard rect.intersects(dirtyRect) || dirtyRect.contains(NSPoint(x: rect.maxX, y: dirtyRect.midY)) else {
                continue
            }
            let x = rect.maxX - 0.5
            path.move(to: NSPoint(x: x, y: bounds.minY + Self.tickInset))
            path.line(to: NSPoint(x: x, y: bounds.maxY - Self.tickInset))
        }

        path.stroke()
    }
}
