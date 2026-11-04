#!/bin/zsh
# 编译并打包 Limen.app（不需要 Xcode，只要命令行工具）
#   ./build.sh          只生成 build/Limen.app
#   ./build.sh --dmg    同时生成 Limen.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Limen.app"
BIN="$APP/Contents/MacOS/Limen"
OBJ="$ROOT/build/obj"

echo "→ 清理"
rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

echo "→ 编译（arm64 + x86_64）"
compile() {
  swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -target "$1-apple-macos14.0" \
    -framework AppKit \
    -framework SwiftUI \
    "$ROOT"/Sources/*.swift \
    -o "$OBJ/limen-$2"
}
compile arm64 arm64
compile x86_64 x86_64
lipo -create "$OBJ/limen-arm64" "$OBJ/limen-x86_64" -output "$BIN"

echo "→ 打包"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
# 图标资源：app 图标 + 菜单栏模板图
if [ -d "$ROOT/Resources" ]; then
  cp "$ROOT/Resources"/* "$APP/Contents/Resources/" 2>/dev/null || true
fi

echo "→ 签名（本地临时签名）"
codesign --force --sign - "$APP" 2>/dev/null || echo "   （签名跳过，仍可用）"

echo "→ 校验"
codesign --verify --strict "$APP" && echo "   签名 OK"
echo "   架构：$(lipo -archs "$BIN")"

if [ "${1:-}" = "--dmg" ]; then
  echo "→ 制作 DMG"
  STAGE="$ROOT/build/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -sfn /Applications "$STAGE/Applications"
  rm -f "$ROOT/Limen.dmg"
  hdiutil create -quiet -volname "Limen" -srcfolder "$STAGE" \
    -ov -format UDZO "$ROOT/Limen.dmg"
  echo "   DMG：$ROOT/Limen.dmg"
fi

echo "✓ 完成：$APP"
