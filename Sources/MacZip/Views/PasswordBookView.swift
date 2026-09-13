import SwiftUI

/// 密码本管理 (FastZip「密码本」页):列表 + 添加/编辑/删除。
struct PasswordBookView: View {
    @State private var entries: [PasswordEntry] = []
    @State private var refreshTrigger = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // 操作条。
            HStack {
                Text("保存常用解压密码,解压加密压缩包时自动匹配。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    beginAdd()
                } label: {
                    Label("添加密码", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)

            // 列表。
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("密码本为空")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("添加密码后,解压加密 ZIP 时会自动尝试匹配")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            PasswordRow(
                                entry: entry,
                                onEdit: { beginEdit(entry) },
                                onDelete: { delete(entry) }
                            )
                            if index < entries.count - 1 {
                                RowDivider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                    .padding(.horizontal, 28)
                }
                Spacer(minLength: 16)
            }
        }
        .onAppear(perform: reload)
        .id(refreshTrigger)
    }

    private func reload() {
        entries = PasswordBook.shared.entries()
    }

    private func beginAdd() {
        guard let saved = PasswordEditAlert.run(entry: nil, isAdding: true) else { return }
        _ = PasswordBook.shared.add(saved)
        reload()
        refreshTrigger = UUID()
    }

    private func beginEdit(_ entry: PasswordEntry) {
        guard let saved = PasswordEditAlert.run(entry: entry, isAdding: false) else { return }
        _ = PasswordBook.shared.update(saved)
        reload()
        refreshTrigger = UUID()
    }

    private func delete(_ entry: PasswordEntry) {
        _ = PasswordBook.shared.remove(id: entry.id)
        reload()
    }
}

/// 密码行。
private struct PasswordRow: View {
    let entry: PasswordEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundColor(.blue)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "未命名密码" : entry.title)
                    .font(.system(size: 13, weight: .medium))
                Text("添加于 \(Self.dateFormatter.string(from: entry.createdAt))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("编辑") { onEdit() }
                .controlSize(.small)
            Button("删除") { onDelete() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// 密码编辑弹窗 (纯 AppKit NSAlert 实现):
/// SwiftUI sheet 在新版 macOS 上叠加 SecureField 会触发系统自动填充玻璃浮层 /
/// 布局撕裂等渲染问题;NSAlert 全版本渲染一致,与主 App 的密码提示框风格统一。
enum PasswordEditAlert {
    /// 模态弹出编辑框。返回保存后的条目;取消返回 nil。
    @discardableResult
    static func run(entry: PasswordEntry?, isAdding: Bool) -> PasswordEntry? {
        let alert = NSAlert()
        alert.messageText = isAdding ? "添加密码" : "编辑密码"
        alert.informativeText = "备注便于识别用途,解压加密压缩包时将自动尝试该密码。"
        alert.alertStyle = .informational

        // 辅助视图:备注 + 密码 两行输入。
        let width: CGFloat = 280
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 84))

        let titleLabel = NSTextField(labelWithString: "备注")
        titleLabel.frame = NSRect(x: 0, y: 64, width: width, height: 14)
        titleLabel.font = .systemFont(ofSize: 11)

        let titleField = NSTextField(frame: NSRect(x: 0, y: 42, width: width, height: 22))
        titleField.placeholderString = "例如:公司打包"
        titleField.stringValue = entry?.title ?? ""

        let pwLabel = NSTextField(labelWithString: "密码")
        pwLabel.frame = NSRect(x: 0, y: 22, width: width, height: 14)
        pwLabel.font = .systemFont(ofSize: 11)

        let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        pwField.stringValue = entry?.password ?? ""

        container.addSubview(titleLabel)
        container.addSubview(titleField)
        container.addSubview(pwLabel)
        container.addSubview(pwField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = titleField

        alert.addButton(withTitle: isAdding ? "添加" : "保存")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, !pwField.stringValue.isEmpty else {
            return nil
        }

        var updated = entry ?? PasswordEntry(title: "", password: "")
        updated.title = titleField.stringValue
        updated.password = pwField.stringValue
        return updated
    }
}
