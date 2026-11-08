#!/bin/zsh
# 构建 LanChat.app（release + ad-hoc 签名），输出到 build/LanChat.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/LanChat.app
VERSION=${VERSION:-1.0.0}
# UNIVERSAL=1 时同时编译 Apple Silicon 和 Intel（发布用）
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCH_FLAGS[@]}"
BIN=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/LanChat

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LanChat"

# 生成应用图标（SF Symbol 渲染为 icns）
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null && \
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "⚠️ 图标生成失败，跳过"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LanChat</string>
  <key>CFBundleDisplayName</key><string>LanChat</string>
  <key>CFBundleIdentifier</key><string>local.lanchat.app</string>
  <key>CFBundleExecutable</key><string>LanChat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>LanChat 需要访问本地网络，以发现同一局域网内的设备并收发消息和文件。</string>
  <key>NSBonjourServices</key>
  <array><string>_lanchat._tcp</string></array>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "✅ 已生成 $APP（$(lipo -archs "$APP/Contents/MacOS/LanChat")）"

# ZIP=1 时额外打包 build/LanChat-<版本>.zip（ditto 保留签名和扩展属性）
if [[ "${ZIP:-0}" == 1 ]]; then
  ZIPFILE="build/LanChat-${VERSION}.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "✅ 已打包 $ZIPFILE"
fi
