import SwiftUI

/// 设置窗口根视图:FastZip 风格 — 顶部品牌头 + 分段 Tab + 内容区。
struct SettingsRootView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "通用"
        case compress = "压缩"
        case extract = "解压"
        case passwords = "密码本"
        case advanced = "高级"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .compress: return "doc.zipper"
            case .extract: return "arrow.down.right.square"
            case .passwords: return "key"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            // 品牌头:图标 + 名称 + 版本。
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage.resized(to: NSSize(width: 40, height: 40)) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacZip")
                        .font(.system(size: 16, weight: .semibold))
                    Text("快速压缩解压 · 多线程引擎 · 空格预览")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 10)

            // 顶部分段 Tab (macOS 12 兼容:不用 NavigationStack)。
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)

            Divider()
                .padding(.top, 12)

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView()
                case .compress: CompressSettingsView()
                case .extract: ExtractSettingsView()
                case .passwords: PasswordBookView()
                case .advanced: AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}

extension NSImage {
    func resized(to newSize: NSSize) -> NSImage? {
        let result = NSImage(size: newSize)
        result.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }
}

// MARK: - 通用 Tab

struct GeneralSettingsView: View {
    @State private var isExtensionEnabled = false
    @State private var silentLaunch = true
    @State private var playSound = true
    @State private var showSuccessHUD = true

    var body: some View {
        GroupedForm {
            GroupedSection("启动") {
                SettingRow("静默启动", subtitle: "开机自启 / 后台拉起时保持静默,不弹出主窗口(用户主动打开时会正常弹出)") {
                    Toggle("", isOn: $silentLaunch)
                        .labelsHidden()
                        .onChange(of: silentLaunch) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.silentLaunch)
                        }
                }
            }

            GroupedSection("Finder 扩展") {
                HStack(spacing: 12) {
                    Image(systemName: isExtensionEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(isExtensionEnabled ? .green : .orange)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isExtensionEnabled ? "Finder 右键扩展已启用" : "尚未启用 Finder 右键扩展")
                            .font(.system(size: 13, weight: .medium))
                        Text(isExtensionEnabled
                             ? "在访达中右键即可使用压缩/解压功能"
                             : "启用后才能在访达右键菜单中使用 MacZip")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !isExtensionEnabled {
                        Button("启用扩展…") {
                            ExternalExtensionStatus.openFinderExtensionPreferences()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            GroupedSection("反馈") {
                SettingRow("完成后提示音", subtitle: "解压/压缩完成时播放系统提示音") {
                    Toggle("", isOn: $playSound)
                        .labelsHidden()
                        .onChange(of: playSound) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.playSoundOnFinish)
                        }
                }
                RowDivider()
                SettingRow("显示成功通知", subtitle: "操作成功时在屏幕顶部显示胶囊通知") {
                    Toggle("", isOn: $showSuccessHUD)
                        .labelsHidden()
                        .onChange(of: showSuccessHUD) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.enableSuccessHUD)
                        }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let storage = SharedStorageManager.shared
        silentLaunch = storage.getBool(forKey: MacZipSettings.silentLaunch, defaultValue: true)
        playSound = storage.getBool(forKey: MacZipSettings.playSoundOnFinish, defaultValue: true)
        showSuccessHUD = storage.getBool(forKey: MacZipSettings.enableSuccessHUD, defaultValue: true)
        // pluginkit 进程外查询通常 <100ms,直接同步读。
        isExtensionEnabled = ExternalExtensionStatus.isFinderExtensionEnabled
    }
}

// MARK: - 压缩 Tab

struct CompressSettingsView: View {
    @State private var defaultFormat: String = "zip"
    @State private var level: ZlibCodec.Level = .standard
    @State private var volumeSizeMB: Int = 0
    @State private var excludeJunk = true
    @State private var useAES256 = false
    @State private var verifyAfterCompress = true
    @State private var excludeRulesText = ""
    @State private var solidDefault = false
    @State private var showCompressMenu = true
    @State private var showAdvancedMenu = true

    private let volumePresets: [Int] = [0, 10, 50, 100, 500, 1024]

    var body: some View {
        GroupedForm {
            GroupedSection("默认格式") {
                SettingRow("右键「压缩为」的默认格式") {
                    Picker("", selection: $defaultFormat) {
                        Text("ZIP").tag("zip")
                        Text("TAR.GZ").tag("tar.gz")
                        Text("7Z").tag("7z")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .onChange(of: defaultFormat) { value in
                        _ = SharedStorageManager.shared.setString(value, forKey: MacZipSettings.defaultFormat)
                        SharedStorageManager.shared.postConfigChanged()
                    }
                }
            }

            GroupedSection("压缩引擎") {
                SettingRow("压缩等级") {
                    Picker("", selection: $level) {
                        ForEach(ZlibCodec.Level.allCases) { lv in
                            Text(lv.localizedName).tag(lv)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: level) { value in
                        _ = SharedStorageManager.shared.setString(value.rawValue, forKey: MacZipSettings.compressionLevel)
                    }
                }
                RowDivider()
                SettingRow("排除系统杂质文件", subtitle: "自动跳过 .DS_Store / __MACOSX 等文件") {
                    Toggle("", isOn: $excludeJunk)
                        .labelsHidden()
                        .onChange(of: excludeJunk) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.excludeSystemJunk)
                        }
                }
                RowDivider()
                SettingRow("ZIP 加密使用 AES-256", subtitle: "强加密 (WinZip AES);Windows 资源管理器不识别,需用 MacZip / WinZip / 7-Zip 打开。关闭时为传统 ZipCrypto (兼容性最好但强度弱)") {
                    Toggle("", isOn: $useAES256)
                        .labelsHidden()
                        .onChange(of: useAES256) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.zipUseAES256)
                        }
                }
                RowDivider()
                SettingRow("压缩后自动校验", subtitle: "ZIP 压缩完成后立即重读校验完整性,发现损坏当场提示 (需多花一次读盘时间)") {
                    Toggle("", isOn: $verifyAfterCompress)
                        .labelsHidden()
                        .onChange(of: verifyAfterCompress) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.verifyAfterCompress)
                        }
                }
            }

            GroupedSection("自定义排除规则") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每行一条,在系统杂质过滤之上叠加 (对 ZIP 引擎生效):\n不含 / → 匹配任意层级的文件或目录名,如 *.log、node_modules\n含 / → 匹配压缩包内相对路径,如 build/*、docs/*.md")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    TextEditor(text: $excludeRulesText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .onChange(of: excludeRulesText) { value in
                            let patterns = value
                                .split(separator: "\n")
                                .map { String($0).trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            _ = SharedStorageManager.shared.setStringArray(patterns, forKey: MacZipSettings.excludePatterns)
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            GroupedSection("分卷压缩") {
                SettingRow("默认分卷大小", subtitle: "右键「分卷压缩…」弹窗的预设值") {
                    Picker("", selection: $volumeSizeMB) {
                        Text("不分卷").tag(0)
                        Text("10 MB").tag(10)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: volumeSizeMB) { value in
                        _ = SharedStorageManager.shared.setInt(value, forKey: MacZipSettings.defaultVolumeSizeMB)
                    }
                }
            }

            GroupedSection("右键菜单") {
                SettingRow("显示「压缩为」主项") {
                    Toggle("", isOn: $showCompressMenu)
                        .labelsHidden()
                        .onChange(of: showCompressMenu) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.showCompressMenu)
                            SharedStorageManager.shared.postConfigChanged()
                        }
                }
                RowDivider()
                SettingRow("显示「更多压缩/解压选项」子菜单") {
                    Toggle("", isOn: $showAdvancedMenu)
                        .labelsHidden()
                        .onChange(of: showAdvancedMenu) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.showAdvancedMenu)
                            SharedStorageManager.shared.postConfigChanged()
                        }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let storage = SharedStorageManager.shared
        defaultFormat = storage.getString(forKey: MacZipSettings.defaultFormat, defaultValue: "zip")
        level = ZlibCodec.Level(rawValue: storage.getString(forKey: MacZipSettings.compressionLevel, defaultValue: "standard")) ?? .standard
        volumeSizeMB = storage.getInt(forKey: MacZipSettings.defaultVolumeSizeMB, defaultValue: 0)
        excludeJunk = storage.getBool(forKey: MacZipSettings.excludeSystemJunk, defaultValue: true)
        useAES256 = storage.getBool(forKey: MacZipSettings.zipUseAES256, defaultValue: false)
        verifyAfterCompress = storage.getBool(forKey: MacZipSettings.verifyAfterCompress, defaultValue: true)
        excludeRulesText = storage.getStringArray(forKey: MacZipSettings.excludePatterns, defaultValue: [])
            .joined(separator: "\n")
        solidDefault = storage.getBool(forKey: MacZipSettings.solidSevenZip, defaultValue: false)
        showCompressMenu = storage.getBool(forKey: MacZipSettings.showCompressMenu, defaultValue: true)
        showAdvancedMenu = storage.getBool(forKey: MacZipSettings.showAdvancedMenu, defaultValue: true)
    }
}

// MARK: - 解压 Tab

struct ExtractSettingsView: View {
    @State private var openArchiveAction = "preview"
    @State private var conflictPolicy: ZipReader.ConflictPolicy = .rename
    @State private var preferPasswordBook = true
    @State private var deleteAfterExtract = false
    @State private var openFolderAfterExtract = true
    @State private var showExtractMenu = true

    var body: some View {
        GroupedForm {
            GroupedSection("双击打开") {
                SettingRow("双击压缩包时", subtitle: "在 Finder 中双击 zip 等压缩包 (打开方式为 MacZip) 时的行为") {
                    Picker("", selection: $openArchiveAction) {
                        Text("预览内容").tag("preview")
                        Text("直接解压").tag("extract")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .onChange(of: openArchiveAction) { value in
                        _ = SharedStorageManager.shared.setString(value, forKey: MacZipSettings.openArchiveAction)
                    }
                }
            }

            GroupedSection("解压行为") {
                SettingRow("文件名冲突时") {
                    Picker("", selection: $conflictPolicy) {
                        ForEach(ZipReader.ConflictPolicy.allCases, id: \.self) { policy in
                            Text(policy.localizedName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: conflictPolicy) { value in
                        _ = SharedStorageManager.shared.setString(value.rawValue, forKey: MacZipSettings.conflictPolicy)
                    }
                }
                RowDivider()
                SettingRow("解压后打开目标文件夹") {
                    Toggle("", isOn: $openFolderAfterExtract)
                        .labelsHidden()
                        .onChange(of: openFolderAfterExtract) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.openFolderAfterExtract)
                        }
                }
                RowDivider()
                SettingRow("解压后删除压缩包", subtitle: "压缩包将移入废纸篓") {
                    Toggle("", isOn: $deleteAfterExtract)
                        .labelsHidden()
                        .onChange(of: deleteAfterExtract) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.deleteArchiveAfterExtract)
                        }
                }
            }

            GroupedSection("密码") {
                SettingRow("自动尝试密码本", subtitle: "解压加密包时按密码本顺序自动匹配") {
                    Toggle("", isOn: $preferPasswordBook)
                        .labelsHidden()
                        .onChange(of: preferPasswordBook) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.preferPasswordBook)
                        }
                }
                RowDivider()
                SettingRow("显示「解压」主项") {
                    Toggle("", isOn: $showExtractMenu)
                        .labelsHidden()
                        .onChange(of: showExtractMenu) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.showExtractMenu)
                            SharedStorageManager.shared.postConfigChanged()
                        }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let storage = SharedStorageManager.shared
        openArchiveAction = storage.getString(forKey: MacZipSettings.openArchiveAction, defaultValue: "preview")
        conflictPolicy = ZipReader.ConflictPolicy(rawValue: storage.getString(forKey: MacZipSettings.conflictPolicy, defaultValue: "rename")) ?? .rename
        preferPasswordBook = storage.getBool(forKey: MacZipSettings.preferPasswordBook, defaultValue: true)
        deleteAfterExtract = storage.getBool(forKey: MacZipSettings.deleteArchiveAfterExtract, defaultValue: false)
        openFolderAfterExtract = storage.getBool(forKey: MacZipSettings.openFolderAfterExtract, defaultValue: true)
        showExtractMenu = storage.getBool(forKey: MacZipSettings.showExtractMenu, defaultValue: true)
    }
}

// MARK: - 高级 Tab

struct AdvancedSettingsView: View {
    @State private var debugLogging = false
    @State private var heartbeatInfo: SharedStorageManager.HeartbeatInfo?
    @State private var sevenZipStatus: String = ""

    var body: some View {
        GroupedForm {
            GroupedSection("扩展诊断") {
                InfoRow(title: "扩展进程心跳", value: heartbeatDescription)
                RowDivider()
                InfoRow(title: "7-Zip 引擎", value: sevenZipStatus)
                RowDivider()
                SettingRow("重新载入 Finder 扩展") {
                    Button("重启 Finder") {
                        restartFinder()
                    }
                    .controlSize(.small)
                }
            }

            GroupedSection("日志与诊断") {
                SettingRow("调试日志", subtitle: "记录菜单渲染与动作分发细节") {
                    Toggle("", isOn: $debugLogging)
                        .labelsHidden()
                        .onChange(of: debugLogging) { value in
                            _ = SharedStorageManager.shared.setBool(value, forKey: MacZipSettings.enableDebugLogging)
                        }
                }
                RowDivider()
                SettingRow("运行日志") {
                    HStack(spacing: 8) {
                        Button("打开日志文件") {
                            let url = SharedStorageManager.shared.logFileURL
                            if !FileManager.default.fileExists(atPath: url.path) {
                                FileManager.default.createFile(atPath: url.path, contents: Data("MacZip log\n".utf8))
                            }
                            NSWorkspace.shared.open(url)
                        }
                        .controlSize(.small)
                        Button("清空") {
                            SharedStorageManager.shared.clearLogFile()
                            ToastHUD.showAsync(title: "日志已清空", content: "后续日志会重新写入", isSuccess: true)
                        }
                        .controlSize(.small)
                    }
                }
                RowDivider()
                SettingRow("崩溃报告", subtitle: "删除本应用在系统诊断目录中的历史崩溃报告") {
                    Button("删除崩溃报告") {
                        let count = SharedStorageManager.shared.clearCrashReports()
                        ToastHUD.showAsync(
                            title: count > 0 ? "已删除 \(count) 份崩溃报告" : "没有可清理的崩溃报告",
                            content: "",
                            isSuccess: true
                        )
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var heartbeatDescription: String {
        guard let info = heartbeatInfo else { return "暂无 (扩展未加载)" }
        return "路径数 \(info.observedPathCount) · v\(info.version) · \(info.updatedAt)"
    }

    private func refresh() {
        debugLogging = SharedStorageManager.shared.getBool(forKey: MacZipSettings.enableDebugLogging, defaultValue: false)
        heartbeatInfo = SharedStorageManager.shared.readHeartbeat()
        if ExternalArchiver.shared.isSevenZipAvailable {
            sevenZipStatus = "已就绪 (\(ExternalArchiver.shared.sevenZipPath ?? ""))"
        } else {
            sevenZipStatus = "未找到 (7Z/RAR 相关功能将隐藏,可 brew install 7zz)"
        }
    }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
        ToastHUD.showAsync(title: "Finder 正在重启", content: "重启后右键菜单将重新加载", isSuccess: true)
    }
}
