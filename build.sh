#!/bin/bash
# DriveTemp 构建脚本
# 用法：./build.sh          只编译到 build/ 目录
#      ./build.sh install  编译并安装到 ~/Applications

set -e

APP_NAME="硬盘盒温度"
EXEC_NAME="DriveTemp"
BUNDLE_ID="com.leo.tbtemp"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> 检查依赖"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "缺少 swiftc，请先安装 Xcode Command Line Tools：" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if [ ! -x "$HOME/.local/bin/smartctl" ] && ! command -v smartctl >/dev/null 2>&1; then
  echo "警告：未找到 smartctl，应用能启动但读不到任何数据。" >&2
  echo "  安装方式：brew install smartmontools" >&2
fi

echo "==> 编译"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macosx13.0 main.swift DiskIO.swift DeviceIdentity.swift -o "$APP/Contents/MacOS/$EXEC_NAME" -framework Cocoa -framework IOKit

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.1.2</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> 完成：$APP"

if [ "$1" = "install" ]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  if [ -e "$DEST" ]; then
    echo "已存在已安装版本：$DEST。请先备份并手动处理，避免覆盖现有应用。" >&2
    exit 1
  fi
  cp -R "$APP" "$DEST"
  echo "==> 已安装：$DEST"
  open "$DEST"
fi

echo
echo "首次使用请在 系统设置 > 通用 > 登录项 里添加这个 app，即可开机自启。"
