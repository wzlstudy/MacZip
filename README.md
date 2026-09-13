# MacZip

一款参考 [FastZip](https://www.better365.cn/fastzip.html) 功能与页面样式复刻的 macOS 快速压缩解压工具，项目架构参考 [MacRightClick](https://github.com/guyue55/MacRightClick)（raw swiftc 直编 + Finder Sync 扩展 + App Group 中介通信），**最低支持 macOS 12 Monterey**。

![icon](Resources/AppIcon.png)

## 功能特性

### 自研多线程压缩引擎（ZIP）
- **多线程压缩**：每个文件独立 deflate，线程池规模 = CPU 核心数，两阶段流水线（并行压缩 → 串行装配）
- **大文件分块并行**：单文件 ≥ 2×64MiB 时按块并行 deflate / 并行 inflate（块边界记入私有 extra field 0x6D7A，拼接流仍是合法 deflate，外部工具照常可解；压缩提速约 7 倍、解压约 4 倍 @8 核）
- **流式加解密**：ZipCrypto 加解密按 1 MiB 分块流水，加解密过程内存占用与文件大小无关
- **多线程解压**：条目级并行 inflate，逐条 CRC 校验
- **容错解压**：损坏条目自动跳过继续解压，完成后汇总提示（取消与磁盘 I/O 错误仍会中止）
- **压缩等级**：仅存储 / 快速 / 标准 / 极限（zlib level 0/1/6/9 真实映射）
- **压缩后自动校验**：ZIP 压缩完成立即重读校验，损坏当场提示（设置页可关）
- **加密压缩**：WinZip AES-256（强；系统 CommonCrypto 实现 PBKDF2 + AES-CTR + HMAC-SHA1，与 WinZip / 7-Zip / pyzipper 双向互通）或 ZipCrypto 传统加密（弱但兼容性最好），设置页可选
- **ZIP64**：>4GB 文件与 >65535 条目支持
- **中文文件名**：UTF-8 文件名标志位（EFS）；未置位却写 GBK 字节的压缩包自动按 GB18030 回退解码，杜绝中文乱码
- **自定义排除规则**：设置页按行配置 glob（`*.log`、`node_modules`、`build/*` 等），ZIP 压缩时叠加于系统杂质过滤之上
- **归档注释**：预览窗口查看/编辑 ZIP 归档注释（仅重写 EOCD 尾部，秒级完成，ZIP64 同样支持）
- **分卷压缩**：切分产出 `.zip.001/.002…`；解压支持数字号系列与 WinZip 惯例（`data.z01…zNN + data.zip` 末卷），任一分卷入口自动合并

### Finder 右键集成（Finder Sync 扩展）
- 顶层主项：`压缩为 "xxx.zip"`（跟随设置里的默认格式）、`解压到 "xxx/"` / `解压到当前位置`
- 更多压缩选项：ZIP / TAR.GZ / 7Z / 加密压缩… / 分卷压缩… / 固实压缩（7Z）
- 更多解压选项：解压到当前位置 / 解压到 "xxx/" / 解压到… / 测试压缩包
- 未安装 7-Zip 时 7Z/RAR 相关项自动隐藏（优雅降级）

### 空格预览压缩包（QuickLook 扩展）
- 选中 ZIP 按空格，直接列出内部文件清单（文件名 / 大小 / 修改时间），无需解压
- 显示加密标记与压缩包统计摘要

### 压缩包内容预览窗口（双击打开 / 设置选“预览”）
- 支持 ZIP / JAR / TAR / TAR.GZ 四种格式的内容清单与单文件预览（TAR 系由内建解析器读取，TAR.GZ 先解压再解析）
- 左侧条目表（名称 / 大小 / 修改日期 / 种类，四列完整显示，支持多选）+ 右侧内容预览的分栏布局
- 选中任意文件即显示其真实内容，文本 / 代码 / 图片 / PDF / 音视频 / Office 等由系统 QuickLook 统一渲染
- 按需单条目解压到临时文件（会话结束自动清理），仅解压当前选中项，大压缩包秒开
- 加密条目先试密码本，未命中再弹窗询问，可一键保存到密码本
- **内容编辑**（仅 ZIP / JAR）：增加文件/目录、提取所选、删除所选（目录连同子树）、清理系统隐藏文件
  - 删除/清理采用“原样搬运”策略：只重组中央目录，保留原压缩率与加密状态，**删除加密包内条目无需密码**
  - 全部操作先写临时文件再原子替换，中途失败不损坏原包
- 提供「用默认程序打开」，超大文件（>200MB）跳过内容预览仅展示元信息

### 密码本
- 保存常用密码（App Group 容器内 JSON，权限 0600）
- 解压加密包时按密码本自动逐个匹配，全部失败再弹窗询问
- 弹窗支持「保存到密码本」一键沉淀

### 其他
- 格式路由：ZIP / JAR 内建引擎处理；TAR / TAR.GZ 预览走内建 TAR 解析器、解压走系统 `tar`；7Z / RAR 自动探测 7-Zip（bundle 内置优先，其次 Homebrew 路径）
- 解压行为可配置：冲突策略（重命名/覆盖/跳过）、解压后删除压缩包、解压后打开文件夹、完成提示音
- 跨进程通信：App Group 容器动作队列（原子写 + 租约 + 崩溃孤儿回收）+ 分布式通知双保险
- 进度浮窗（字节级进度 + 取消）与磨砂玻璃 HUD 通知

## 页面样式

设置窗口复刻 FastZip 风格：品牌头（图标 + 名称 + 版本）+ 顶部分段 Tab（通用 / 压缩 / 解压 / 密码本 / 高级）+ 圆角分组卡片，全部 SwiftUI（仅用 macOS 12 可用 API，无 NavigationStack / LabeledContent 等 13+ 控件）。

## 构建与测试

要求：macOS 12+ 与 Xcode Command Line Tools（无需完整 Xcode，SwiftPM 在无 Xcode 的 CLT 14.x 上有 manifest 编译损坏，故走 raw swiftc 方案规避）。

```bash
# 引擎测试套件（31 项断言：回环/加密/互操作/分卷/格式识别/密码本）
./Scripts/test.sh

# 构建 Universal 2（arm64 + x86_64）.app + zip + DMG
./Scripts/build.sh

# 只编译不打包（迭代调试）
SKIP_PACKAGE=1 ./Scripts/build.sh

# 单架构加速
ARCH_OVERRIDE=x86_64 SKIP_PACKAGE=1 ./Scripts/build.sh
```

产物：

```
build/MacZip.app          # 主程序（含 PlugIns/MacZipExtension.appex + MacZipQuickLook.appex）
build/MacZip.zip          # 绿色免安装版
build/MacZip.dmg          # 拖拽安装版
```

发布签名（可选）：

```bash
DISTRIBUTION_ROUTE=website-release \
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
./Scripts/build.sh   # 启用 hardened runtime；notarization 需额外 NOTARY_PROFILE
```

## 安装与启用

1. 将 `MacZip.app` 拖入「应用程序」并启动（菜单栏出现拉链图标）
2. 首次使用需启用 Finder 扩展：设置 → 通用 → 「启用扩展…」→ 勾选 MacZip（或 `pluginkit -e use -i wzl.MacZip.Extension`）
3. 在访达右键任意文件/文件夹即可使用压缩解压；选中 ZIP 按空格预览内容

## 架构

```
Sources/
├── MacZipCore/               # 三进程共享（每 target 以同模块源码形式编译）
│   ├── Zip/                  #   自研 ZIP 引擎：CRC32 / ZipCrypto / WinZipAES / ExcludeMatcher / ZlibCodec / 多线程 ZipWriter / ZipReader / ZipArchiveEditor
│   ├── Tar/                  #   内建 TAR 读取器 + 统一内容读取器 (含 tar.gz 解压)
│   ├── ArchiveService.swift  #   高层编排：格式路由 / 密码本联动 / 分卷合并 / 进度协议
│   ├── ArchiveFormat.swift   #   格式识别 + 分卷切分/合并
│   ├── ArchiveAction.swift   #   右键动作注册表与分发器
│   ├── ExternalArchiver.swift#   7-Zip / tar 桥接
│   ├── PasswordBook.swift    #   密码本存储
│   └── SharedStorageManager.swift # App Group 容器 / 配置 / 动作队列 / 心跳
├── MacZip/                   # 主 App（菜单栏常驻 + 设置窗口 + 动作消费 + 进度窗/HUD/弹窗）
├── MacZipExtension/          # Finder Sync 扩展（右键菜单渲染与入队）
├── MacZipQuickLook/          # QuickLook 预览扩展（空格预览 ZIP 清单）
├── MacZipCLI/                # 无头 CLI（引擎测试 / 脚本化压缩解压）
└── Tests/Runner/             # 测试套件入口（Scripts/test.sh 编译运行）
```

跨进程动作链路（与 MacRightClick 同款模式）：

```
FinderSync(沙盒) ──写 JSON──▶ App Group/PendingActions ──kqueue+分布式通知──▶ 主App 消费租约
      ▲                                                                        │
      └────────── config.json 配置变更广播 / 心跳 / 密码本 ◀──────────────────────┘
```

## 与 FastZip 功能对照

| FastZip 功能 | MacZip 状态 |
|---|---|
| 多线程压缩引擎 | ✅ 自研（并行 deflate + 并行 inflate） |
| 空格预览压缩包 | ✅ QuickLook 扩展 |
| 19 项右键菜单 | ✅ 核心子集（压缩/解压/加密/分卷/固实/测试，均可开关） |
| 密码本自动解密 | ✅ |
| 加密压缩/解压 | ✅ WinZip AES-256（原生读写）+ ZipCrypto |
| 分卷压缩 | ✅ 切分 .001 序列；解压 .001 与 WinZip z01+zipped 双惯例 |
| 固实压缩 | ✅ 7Z（需 7-Zip，未装自动隐藏） |
| 多格式支持 | ✅ zip/jar/gz/tar/tar.gz/tar.bz2/tar.xz/7z/rar（后四类读） |
| 压缩等级 | ✅ 四档真实映射 |

## 已知限制

- macOS 自带的老版 `unzip` 处理 UTF-8 中文文件名存在已知缺陷（Illegal byte sequence）；用 BetterZip / Windows / 本引擎解压均正常
- 7Z / RAR 压缩解压依赖外部 7-Zip 引擎（`brew install 7zz`），未安装时相关菜单自动隐藏

## License

MIT
