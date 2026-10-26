#!/bin/bash
# 打包前先从官方 smartmontools 7.5 源码构建 smartctl。
# SMARTCTL_BINARY=/path/to/smartctl SMARTMONTOOLS_SOURCE=/path/to/smartmontools-7.5.tar.gz bash package.sh
set -euo pipefail
cd "$(dirname "$0")"
: "${SMARTCTL_BINARY:?请指定从官方源码构建的 arm64 smartctl}"
: "${SMARTMONTOOLS_SOURCE:?请指定对应的 smartmontools-7.5.tar.gz 官方源码}"
SMARTCTL_BINARY="$(cd "$(dirname "$SMARTCTL_BINARY")" && pwd)/$(basename "$SMARTCTL_BINARY")"
SMARTMONTOOLS_SOURCE="$(cd "$(dirname "$SMARTMONTOOLS_SOURCE")" && pwd)/$(basename "$SMARTMONTOOLS_SOURCE")"
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'build/硬盘盒温度.app/Contents/Info.plist')
# File Provider 管理的目录会自动给 .app 写 FinderInfo；在系统临时目录签名打包。
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/drivetemp-package.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/硬盘盒温度.app"
ditto --norsrc --noextattr 'build/硬盘盒温度.app' "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/ThirdParty"
cp "$SMARTCTL_BINARY" "$APP/Contents/Helpers/smartctl"
chmod 755 "$APP/Contents/Helpers/smartctl"
cp "$SMARTMONTOOLS_SOURCE" "$APP/Contents/Resources/ThirdParty/smartmontools-7.5.tar.gz"
tar -xOf "$SMARTMONTOOLS_SOURCE" smartmontools-7.5/COPYING > "$APP/Contents/Resources/ThirdParty/smartmontools-COPYING.txt"
cp docs/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/ThirdParty/"
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/Helpers/smartctl"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
cp LICENSE "$STAGE/DriveTemp-LICENSE.txt"
cat > "$STAGE/安装说明.txt" <<'TEXT'
DriveTemp / 硬盘盒温度

适用：Apple 芯片 Mac（M 系列），macOS 13 或更新版本。
安装：把「硬盘盒温度.app」拖入「应用程序」或「~/Applications」后打开。
程序在菜单栏显示温度，点击可查看每秒读写速度、SSD 温度及曲线。
面板顶部「命名」可设置自定义名称。点击外部或按 Esc 收起。
安装包已包含 smartctl，无需 Homebrew、Xcode 或自行编译。
温度能否读取仍取决于硬盘和硬盘盒是否透传 SMART。

本应用使用本地临时签名，未通过 Apple 开发者身份签名和公证。
若 macOS 首次阻止打开，请核对下载来源为 LeoLeung89/DriveTemp，
再在「系统设置 > 隐私与安全性」按系统提示允许打开。

第三方工具 smartctl 7.5 的完整官方源码、许可证和构建说明位于：
硬盘盒温度.app/Contents/Resources/ThirdParty/
DriveTemp 源码与更新：https://github.com/LeoLeung89/DriveTemp
TEXT
ARCHIVE="$PWD/build/DriveTemp-Mac-arm64-v$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/硬盘盒温度.app" "$ARCHIVE"
# 添加安装说明与 DriveTemp 许可证，应用本身仍保留完整 bundle 结构。
(cd "$STAGE" && zip -q "$ARCHIVE" 安装说明.txt DriveTemp-LICENSE.txt)
(cd build && shasum -a 256 "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"
echo "已打包：$ARCHIVE"
