#!/bin/bash
# 构建 FanMenuBar.app（本地 ad-hoc 签名，无公证）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FanMenuBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
clang -fobjc-arc -O2 -Wall \
  -framework Cocoa -framework IOKit \
  src/main.m src/SMCReader.m \
  -o "$APP/Contents/MacOS/FanMenuBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleDisplayName</key><string>风扇管家</string>
    <key>CFBundleExecutable</key><string>FanMenuBar</string>
    <key>CFBundleIdentifier</key><string>local.tools.fanmenubar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>FanMenuBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> 产物: $PWD/$APP"
echo "    安装: cp -R \"$PWD/$APP\" /Applications/  （然后 open /Applications/FanMenuBar.app）"
