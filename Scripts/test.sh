#!/usr/bin/env bash
# ==============================================================================
# MacZip 引擎测试套件 (raw swiftc,兼容无 Xcode 的 CommandLineTools 环境)
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_PATH=$(xcrun --show-sdk-path)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# 收集源码 (bash 3.2 兼容;-print0 处理任意路径)
SOURCES=""
while IFS= read -r -d '' f; do
    SOURCES="$SOURCES $(printf '%q' "$f")"
done < <(find Sources/MacZipCore -name '*.swift' -print0 | sort -z)

echo "🧪 [Test] 编译测试 runner..."
eval swiftc -Onone -sdk \""$SDK_PATH"\" $SOURCES Tests/Runner/main.swift -o \""$OUT/EngineTests"\" -lz

echo "🧪 [Test] 运行..."
"$OUT/EngineTests"
