#!/usr/bin/env bash

# ==============================================================================
# MacZip 自动化编译与打包脚本 (支持 Universal 2 / Finder 扩展 / QuickLook 扩展)
# 参考 MacRightClick 的 raw swiftc 方案,规避 CLT 无 Xcode 环境的 SwiftPM 限制。
# ==============================================================================
set -euo pipefail

echo "🚀 [Build] 开始自动化编译与打包流程..."

# 1. 初始化目录
BUILD_DIR="build"
APP_NAME="MacZip"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXT_NAME="${APP_NAME}Extension"
EXT_BUNDLE="$APP_BUNDLE/Contents/PlugIns/${EXT_NAME}.appex"
QL_NAME="${APP_NAME}QuickLook"
QL_BUNDLE="$APP_BUNDLE/Contents/PlugIns/${QL_NAME}.appex"
DISTRIBUTION_ROUTE="${DISTRIBUTION_ROUTE:-website-dev}"
CODE_SIGN_IDENTITY="-"
CODESIGN_RUNTIME_ARGS=""

if [ "$DISTRIBUTION_ROUTE" = "website-release" ]; then
    if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
        echo "❌ [Build] website-release 需要设置 DEVELOPER_ID_APPLICATION"
        exit 2
    fi
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
    CODESIGN_RUNTIME_ARGS="--options runtime --timestamp"
fi

if [ -n "${VERSION_OVERRIDE:-}" ]; then
    VERSION="$VERSION_OVERRIDE"
elif [ -f "VERSION" ]; then
    VERSION=$(tr -d '\r\n' < VERSION)
else
    VERSION="1.0.0"
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ [Build] VERSION 必须是稳定语义版本,实际为: $VERSION"
    exit 2
fi
echo "🏷️ [Build] 版本号: $VERSION | 分发路线: $DISTRIBUTION_ROUTE"

echo "🧹 [Build] 清理旧编译目录: $BUILD_DIR..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. VFS Overlay 解决 CommandLineTools 的 SwiftBridging 重定义冲突 (与 MacRightClick 同款)
echo "📝 [Build] 创建 VFS Overlay..."
cat << 'EOF' > "$BUILD_DIR/empty.modulemap"
// 空的 modulemap 文件
EOF
cat << EOF > "$BUILD_DIR/overlay.yaml"
{
  'version': 0,
  'roots': [
    {
      'type': 'directory',
      'name': '/Library/Developer/CommandLineTools/usr/include/swift',
      'contents': [
        {
          'type': 'file',
          'name': 'bridging.modulemap',
          'external-contents': '$(pwd)/$BUILD_DIR/empty.modulemap'
        }
      ]
    }
  ]
}
EOF

echo "📂 [Build] 创建 App Bundle 结构..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/PlugIns"
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"
mkdir -p "$QL_BUNDLE/Contents/MacOS"
mkdir -p "$QL_BUNDLE/Contents/Resources"

# 3. 源码清单 (Core 三方共用;QL 只取解析所需子集)
CORE_SOURCES=$(find Sources/MacZipCore -name '*.swift' | sort)

QL_CORE_SOURCES=$(find Sources/MacZipCore/Zip Sources/MacZipCore/Tar Sources/MacZipCore/Logging Sources/MacZipCore/UI -name '*.swift' | sort; echo Sources/MacZipCore/AppConstants.swift; echo Sources/MacZipCore/ArchiveFormat.swift)

HOST_SOURCES="$CORE_SOURCES"
for f in Sources/MacZip/*.swift Sources/MacZip/Views/*.swift; do
    HOST_SOURCES="$HOST_SOURCES $f"
done

EXT_SOURCES="$CORE_SOURCES Sources/MacZipExtension/FinderSync.swift"

QL_SOURCES="$QL_CORE_SOURCES Sources/MacZipQuickLook/PreviewViewController.swift"

write_rsp() {
    # swiftc 响应文件:每行一个源路径,规避 shell 转义问题
    local rsp="$1"; shift
    : > "$rsp"
    for f in "$@"; do
        echo "$f" >> "$rsp"
    done
}

# 4. Info.plist:主 App
echo "📝 [Build] 生成主程序 Info.plist..."
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>wzl.MacZip</string>
    <key>CFBundleName</key>
    <string>MacZip</string>
    <key>CFBundleDisplayName</key>
    <string>MacZip</string>
    <key>CFBundleExecutable</key>
    <string>MacZip</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 MacZip. MIT License.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>ZIP 压缩包</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>com.pkware.zip-archive</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JAR 压缩包</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.sun.java-archive</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>TAR 归档</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>7Z 压缩包</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.7-zip.7-zip-archive</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>RAR 压缩包</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.rarlab.rar-archive</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.7-zip.7-zip-archive</string>
            <key>UTTypeDescription</key>
            <string>7Z 压缩包</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>7z</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.rarlab.rar-archive</string>
            <key>UTTypeDescription</key>
            <string>RAR 压缩包</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.archive</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>rar</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# 5. Info.plist:Finder 扩展
echo "📝 [Build] 生成 Finder 扩展 Info.plist..."
cat <<EOF > "$EXT_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>wzl.MacZip.Extension</string>
    <key>CFBundleName</key>
    <string>MacZipExtension</string>
    <key>CFBundleDisplayName</key>
    <string>MacZip 访达扩展</string>
    <key>CFBundleExecutable</key>
    <string>MacZipExtension</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key>
        <string>FinderSync</string>
    </dict>
</dict>
</plist>
EOF

# 6. Info.plist:QuickLook 预览扩展 (空格预览压缩包)
echo "📝 [Build] 生成 QuickLook 扩展 Info.plist..."
cat <<EOF > "$QL_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>wzl.MacZip.QuickLook</string>
    <key>CFBundleName</key>
    <string>MacZipQuickLook</string>
    <key>CFBundleDisplayName</key>
    <string>MacZip 预览插件</string>
    <key>CFBundleExecutable</key>
    <string>MacZipQuickLook</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>PreviewViewController</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>com.pkware.zip-archive</string>
                <string>com.sun.java-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
            </array>
            <key>QLIsDataBasedPreview</key>
            <false/>
        </dict>
    </dict>
</dict>
</plist>
EOF

# 7. AppIcon
if [ -f "Resources/AppIcon.png" ]; then
    echo "🎨 [Build] 合成 AppIcon.icns..."
    ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    sips -z 16 16     "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null 2>&1 || true
    sips -z 32 32     "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null 2>&1 || true
    sips -z 32 32     "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null 2>&1 || true
    sips -z 64 64     "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null 2>&1 || true
    sips -z 128 128   "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null 2>&1 || true
    sips -z 256 256   "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null 2>&1 || true
    sips -z 256 256   "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null 2>&1 || true
    sips -z 512 512   "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null 2>&1 || true
    sips -z 512 512   "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null 2>&1 || true
    sips -z 1024 1024 "Resources/AppIcon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null 2>&1 || true
    if command -v iconutil >/dev/null; then
        iconutil -c icns "$ICONSET_DIR" -o "$BUILD_DIR/AppIcon.icns"
        cp "$BUILD_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        echo "🟢 [Build] AppIcon.icns 注入完成"
    fi
else
    echo "⚠️ [Build] 未找到 Resources/AppIcon.png,跳过图标打包"
fi

# 8. 编译 (arm64 + x86_64 → Universal 2)
SDK_PATH=$(xcrun --show-sdk-path)
# -O 为默认:ZipCrypto 逐字节循环、中央目录解析等 Swift 热路径对优化等级敏感,
# -Onone 有数倍引擎性能差距。迭代调试时可用 DEBUG_BUILD=1 回退 -Onone 加快编译。
BUILD_OPT="-O"
if [ "${DEBUG_BUILD:-0}" = "1" ]; then
    BUILD_OPT="-Onone"
fi
COMMON_FLAGS="$BUILD_OPT -parse-as-library -sdk $SDK_PATH -vfsoverlay $BUILD_DIR/overlay.yaml"

ARCHES="arm64 x86_64"
if [ -n "${ARCH_OVERRIDE:-}" ]; then
    ARCHES="$ARCH_OVERRIDE"
fi

compile_universal() {
    # $1=rsp 文件路径 (已含全部源码行) $2=arm64 输出 $3=x86_64 输出 $4=最终产物
    local rsp="$1" output_arm="$2" output_x86="$3" final="$4"
    local arch out
    for arch in $ARCHES; do
        if [ "$arch" = "arm64" ]; then out="$output_arm"; else out="$output_x86"; fi
        echo "🛠️ [Build] 编译 $(basename "$final") ($arch)..."
        # shellcheck disable=SC2086
        swiftc $COMMON_FLAGS -target "$arch"-apple-macosx12.0 @"$rsp" -o "$out" -lz
    done
    if [ "$ARCHES" = "arm64" ]; then
        cp "$output_arm" "$final"
    elif [ "$ARCHES" = "x86_64" ]; then
        cp "$output_x86" "$final"
    else
        lipo -create -output "$final" "$output_arm" "$output_x86"
    fi
}

write_rsp "$BUILD_DIR/host.sources.rsp" $HOST_SOURCES
write_rsp "$BUILD_DIR/ext.sources.rsp" $EXT_SOURCES
write_rsp "$BUILD_DIR/ql.sources.rsp" $QL_SOURCES

compile_universal "$BUILD_DIR/host.sources.rsp" "$BUILD_DIR/MacZip_arm64" "$BUILD_DIR/MacZip_x86_64" \
    "$APP_BUNDLE/Contents/MacOS/MacZip"
compile_universal "$BUILD_DIR/ext.sources.rsp" "$BUILD_DIR/MacZipExtension_arm64" "$BUILD_DIR/MacZipExtension_x86_64" \
    "$EXT_BUNDLE/Contents/MacOS/MacZipExtension"
compile_universal "$BUILD_DIR/ql.sources.rsp" "$BUILD_DIR/MacZipQuickLook_arm64" "$BUILD_DIR/MacZipQuickLook_x86_64" \
    "$QL_BUNDLE/Contents/MacOS/MacZipQuickLook"

# 9. 签名 (嵌套:先扩展后宿主)
echo "🔐 [Build] 嵌套签名..."
cp entitlements/host.entitlements "$BUILD_DIR/MacZip.entitlements"
cp entitlements/extension.entitlements "$BUILD_DIR/MacZipExtension.entitlements"
cp entitlements/quicklook.entitlements "$BUILD_DIR/MacZipQuickLook.entitlements"

codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZipExtension.entitlements" "$EXT_BUNDLE/Contents/MacOS/MacZipExtension"
codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZipExtension.entitlements" "$EXT_BUNDLE"

codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZipQuickLook.entitlements" "$QL_BUNDLE/Contents/MacOS/MacZipQuickLook"
codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZipQuickLook.entitlements" "$QL_BUNDLE"

codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZip.entitlements" "$APP_BUNDLE/Contents/MacOS/MacZip"
codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_RUNTIME_ARGS \
    --entitlements "$BUILD_DIR/MacZip.entitlements" "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"

if [ "${SKIP_PACKAGE:-}" = "1" ]; then
    echo "✅ [Build] SKIP_PACKAGE=1,跳过 zip/DMG 打包。产物: $APP_BUNDLE"
    exit 0
fi

# 10. 打包 zip + DMG
echo "📦 [Build] 打包绿色免安装 zip..."
cd "$BUILD_DIR"
zip -r -q "MacZip.zip" "$APP_NAME.app"
cd ..

echo "📦 [Build] 构建 DMG..."
DMG_TEMP_DIR="$BUILD_DIR/dmg_temp"
mkdir -p "$DMG_TEMP_DIR"
cp -R "$APP_BUNDLE" "$DMG_TEMP_DIR/"
ln -s /Applications "$DMG_TEMP_DIR/Applications"

RAW_DMG="$BUILD_DIR/MacZip_raw.dmg"
hdiutil detach "/Volumes/MacZip" >/dev/null 2>&1 || true
rm -f "$RAW_DMG"
hdiutil create -volname "MacZip" -srcfolder "$DMG_TEMP_DIR" -ov -format UDRW "$RAW_DMG" >/dev/null 2>&1

if [ "${SKIP_DMG_STYLING:-}" != "1" ]; then
    device=$(hdiutil attach -nobrowse -readwrite "$RAW_DMG" | egrep '/Volumes/' | awk '{print $1}')
    sleep 1.5
    osascript <<EOF || echo "⚠️ [Build] headless 环境跳过 DMG 视觉排版"
tell application "Finder"
    tell disk "MacZip"
        open
        delay 1
        set containerWindow to container window of disk "MacZip"
        set current view of containerWindow to icon view
        set toolbar visible of containerWindow to false
        set statusbar visible of containerWindow to false
        set the bounds of containerWindow to {400, 200, 980, 580}
        set icon size of icon view options of containerWindow to 128
        set arrangement of icon view options of containerWindow to not arranged
        set position of item "MacZip.app" to {170, 190}
        set position of item "Applications" to {410, 190}
        delay 1
        close containerWindow
    end tell
end tell
EOF
    sleep 1
    hdiutil detach "$device" >/dev/null || true
    sleep 1
fi

FINAL_DMG="$BUILD_DIR/MacZip.dmg"
hdiutil convert "$RAW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RAW_DMG"
rm -rf "$DMG_TEMP_DIR"

echo "=============================================================================="
echo "🎉 [Build] 成功!"
echo "📍 宿主应用: $APP_BUNDLE"
echo "📦 绿色免安装版: $BUILD_DIR/MacZip.zip"
echo "📀 拖拽安装版: $BUILD_DIR/MacZip.dmg"
echo "=============================================================================="
