import Foundation

/// 压缩包条目层级树节点 (主 App 预览窗口 / QuickLook 预览共用)。
///
/// 中央目录本身是扁平的 "a/b/c.txt" 形式;这里把它折叠成可展开的真正树:
/// 显式目录条目保留其信息,文件名中隐含的中间目录自动补齐,并自底向上汇总大小与加密标记。
public final class ZipEntryNode: NSObject {
    /// 单段名称 (不含父路径与结尾斜杠)。
    public let name: String
    /// 归档内完整相对路径 (目录不带结尾斜杠),用于展示与定位。
    public let path: String
    public private(set) var isDirectory: Bool
    /// 中央目录中的显式条目;自动补齐的中间目录为 nil。
    public private(set) var entry: ZipEntryInfo?

    /// 子节点 (目录才可能非空),已按"目录优先 + 名称"排序。
    public private(set) var children: [ZipEntryNode] = []

    /// 目录下所有文件累计未压缩字节数 (文件为自身大小)。
    public private(set) var totalUncompressedSize: UInt64 = 0
    /// 子树内是否含加密条目。
    public private(set) var containsEncrypted = false

    init(name: String, path: String, isDirectory: Bool, entry: ZipEntryInfo?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.entry = entry
        super.init()
        if let entry, !entry.isDirectory {
            totalUncompressedSize = entry.uncompressedSize
        }
        containsEncrypted = entry?.isEncrypted ?? false
    }

    /// 回填显式条目 (构建时先建节点,后遇到同名目录条目时补信息)。
    func attach(entry: ZipEntryInfo) {
        self.entry = entry
        if entry.isDirectory { isDirectory = true } else { totalUncompressedSize = entry.uncompressedSize }
        containsEncrypted = containsEncrypted || entry.isEncrypted
    }

    func appendChild(_ node: ZipEntryNode) { children.append(node) }

    /// 自底向上汇总大小/加密标记,并按"目录优先 + 名称"排序子树。
    func finalizeTree() {
        if isDirectory {
            var total: UInt64 = 0
            var encrypted = containsEncrypted
            for child in children {
                child.finalizeTree()
                total += child.totalUncompressedSize
                encrypted = encrypted || child.containsEncrypted
            }
            totalUncompressedSize = total
            containsEncrypted = encrypted
        }
        children.sort(by: ZipEntryTree.sortComparator)
    }

    /// 关键字过滤:自身 path/name 命中则保留整棵子树;否则保留含命中后代的子树。
    /// 返回新节点,不修改原树。
    public func filtered(matching query: String) -> ZipEntryNode? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: query, options: options) != nil
            || path.range(of: query, options: options) != nil {
            return snapshot(children: children)
        }
        let kids = children.compactMap { $0.filtered(matching: query) }
        guard !kids.isEmpty else { return nil }
        return snapshot(children: kids)
    }

    private func snapshot(children: [ZipEntryNode]) -> ZipEntryNode {
        let node = ZipEntryNode(name: name, path: path, isDirectory: isDirectory, entry: entry)
        node.children = children
        node.totalUncompressedSize = totalUncompressedSize
        node.containsEncrypted = containsEncrypted
        return node
    }

    /// 展示用大小 (目录为子树总量)。
    public var displaySize: UInt64 { totalUncompressedSize }
    /// 修改时间 (仅显式条目具备)。
    public var lastModified: Date? { entry?.lastModified }
    /// 是否含加密内容 (目录为子树汇总)。
    public var isEncrypted: Bool { containsEncrypted }
}

/// 扁平中央目录 → 层级树。
public enum ZipEntryTree {
    /// 统一排序规则:目录优先,同类按名称本地化比较 (自然数字序)。
    static func sortComparator(_ lhs: ZipEntryNode, _ rhs: ZipEntryNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// 构建树。自动补齐缺失的中间目录;返回的根节点已排序并汇总。
    public static func build(from entries: [ZipEntryInfo]) -> [ZipEntryNode] {
        var index: [String: ZipEntryNode] = [:]
        var roots: [ZipEntryNode] = []

        for entry in entries {
            let normalized = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let parts = normalized.split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != "." }
            guard !parts.isEmpty else { continue }

            var parentPath = ""
            for (position, part) in parts.enumerated() {
                let isLast = position == parts.count - 1
                let path = parentPath.isEmpty ? part : parentPath + "/" + part
                let node: ZipEntryNode
                if let existing = index[path] {
                    node = existing
                } else {
                    // 只有末段才可能是文件;更上层一律视为目录。
                    let isDirectory = !isLast || entry.isDirectory
                    node = ZipEntryNode(name: part, path: path, isDirectory: isDirectory, entry: nil)
                    index[path] = node
                    if parentPath.isEmpty {
                        roots.append(node)
                    } else if let parent = index[parentPath] {
                        parent.appendChild(node)
                    }
                }
                if isLast { node.attach(entry: entry) }
                parentPath = path
            }
        }

        for root in roots { root.finalizeTree() }
        roots.sort(by: sortComparator)
        return roots
    }

    /// 统计树中文件 / 目录数量 (含自动补齐的目录)。
    public static func counts(in nodes: [ZipEntryNode]) -> (files: Int, folders: Int) {
        var files = 0
        var folders = 0
        func walk(_ list: [ZipEntryNode]) {
            for node in list {
                if node.isDirectory { folders += 1 } else { files += 1 }
                walk(node.children)
            }
        }
        walk(nodes)
        return (files, folders)
    }
}
