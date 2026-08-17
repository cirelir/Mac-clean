#!/bin/bash
# 打包 Mac Clean release DMG：release 构建 -> 组装 .app -> 签名 -> 创建 DMG。
# 用法: ./scripts/package-release.sh [版本号，默认 0.2.0]
# 在你自己（无沙箱限制）的终端里运行。
set -euo pipefail

VERSION="${1:-0.2.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 构建 release (v$VERSION)"
swift build -c release --product MacCleanApp --disable-sandbox

TEMPLATE_DMG="MacClean-0.1.0.dmg"
TEMPLATE_APP="dist/MacClean.app"
ICON_ASSET="$ROOT/Assets/AppIcon.icns"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [ ! -f "$ICON_ASSET" ]; then
    echo "缺少 App 图标资源: $ICON_ASSET" >&2
    exit 1
fi

# 1. 准备 .app 模板：优先复用已组装的 dist/MacClean.app，否则从旧 DMG 提取。
if [ ! -d "$TEMPLATE_APP" ]; then
    echo "==> 从 $TEMPLATE_DMG 提取 .app 模板"
    MOUNT="$(mktemp -d)"
    hdiutil attach -nobrowse "$TEMPLATE_DMG" -mountpoint "$MOUNT" >/dev/null
    mkdir -p dist
    cp -R "$MOUNT/MacClean.app" "$TEMPLATE_APP"
    hdiutil detach "$MOUNT" >/dev/null
fi

echo "==> 替换二进制并更新版本号"
cp .build/release/MacCleanApp "$TEMPLATE_APP/Contents/MacOS/MacCleanApp"
chmod +x "$TEMPLATE_APP/Contents/MacOS/MacCleanApp"
rm -rf "$TEMPLATE_APP/Contents/_CodeSignature"
mkdir -p "$TEMPLATE_APP/Contents/Resources"
cp "$ICON_ASSET" "$TEMPLATE_APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIconFile AppIcon" \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion 2" \
    "$TEMPLATE_APP/Contents/Info.plist"

echo "==> 签名 (ad-hoc)"
codesign --force --deep --sign - "$TEMPLATE_APP"
codesign --verify --deep --strict "$TEMPLATE_APP"

echo "==> 组装 DMG"
mkdir -p "$STAGING"
cp -R "$TEMPLATE_APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
OUTPUT="$ROOT/MacClean-$VERSION.dmg"
rm -f "$OUTPUT"
hdiutil create -volname "Mac Clean" -srcfolder "$STAGING" -ov -format UDZO "$OUTPUT"

echo "==> 验证 DMG"
VERIFY_MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse "$OUTPUT" -mountpoint "$VERIFY_MOUNT" >/dev/null
codesign --verify --deep --strict "$VERIFY_MOUNT/MacClean.app"
echo "DMG 内签名验证通过"
hdiutil detach "$VERIFY_MOUNT" >/dev/null

echo "==> 完成: $OUTPUT"
ls -lh "$OUTPUT"
