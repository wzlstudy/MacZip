import SwiftUI

// MARK: - FastZip 风格设置组件库
// 分组圆角卡片 + 行式布局,贴近 FastZip 设置窗口的观感 (白底 / 灰分组 / 蓝主色)。

/// 纵向滚动容器,内含多个 GroupedSection。
struct GroupedForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 一组设置卡片:标题 + 圆角分组背景。
struct GroupedSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 10)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
    }
}

/// 分组内的行:左对齐说明 + 右侧控件,行间细分割线。
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// 行间分割线 (带左侧缩进,与系统分组列表一致)。
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}

/// 右对齐说明文本的行 (只读信息)。
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingRow(title) {
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}
