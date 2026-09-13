import AppKit

/// 扁平化表头视图:去掉原生表头的不透明背景与 3D 浮雕,按列在承载视图的材质上
/// 直接绘制标题,并支持列级对齐。
///
/// 背景:原生 `NSTableHeaderView` 会强制画一层不透明底 (在 QuickLook 预览扩展里
/// 表现为突兀的白色条),与半透明的预览面板割裂,故整体重绘。
/// 对齐:原生 `NSTableHeaderCell` 会忽略 `alignment` (实测设为右对齐时干脆不绘制文字),
/// 导致"大小 / 修改时间"标题左对齐、数值右对齐而错位。这里直接读取各列
/// `headerCell.alignment` 自行排版,保证标题与列内容对齐。
final class FlatTableHeaderView: NSTableHeaderView {
    /// 与数据单元格文字对齐所需的最小内边距 (在列间距之外的额外补偿)。
    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        guard let tableView else { return }
        // NSTableView 的单元格会按 intercellSpacing 向内收缩,表头需用同样的内缩量,
        // 标题才能与下方单元格文字在同一竖直边缘对齐。
        let spacing = tableView.intercellSpacing.width / 2
        for (index, column) in tableView.tableColumns.enumerated() {
            // 用 rect(ofColumn:) 而非 headerRect(ofColumn:):后者在列间距之外又额外加宽,
            // 会导致标题与单元格内容错开。
            let rect = tableView.rect(ofColumn: index)
            let headerRect = NSRect(x: rect.origin.x, y: bounds.origin.y, width: rect.width, height: bounds.height)
            guard headerRect.intersects(dirtyRect) else { continue }
            drawTitle(column.title, alignment: column.headerCell.alignment, in: headerRect, inset: spacing + 2)
        }
    }

    private func drawTitle(_ title: String, alignment: NSTextAlignment, in rect: NSRect, inset: CGFloat) {
        guard !title.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let content = rect.insetBy(dx: inset, dy: 0)
        guard content.width > 0 else { return }
        let textRect = NSRect(
            x: content.origin.x,
            y: content.origin.y + (content.height - textSize.height) / 2,
            width: content.width,
            height: textSize.height
        )
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
