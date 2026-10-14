#!/bin/bash
# build-app.sh — 编译打包 NTFSMounter.app 并安装运行（版本号构建后 +0.0.1）
# 流程: 结束旧进程 → 删旧 .app → 编译 → 图标 → 组装 → 装服务 → 前台运行 → 验证 → 版本+1
set -uo pipefail
cd "$(dirname "$0")" || exit 1

APP_NAME=NTFSMounter
BUNDLE_ID=com.x.ntfsformac.mounter
APP_DIR="/Applications/$APP_NAME.app"
ROOT="$(pwd)"
VER=$(tr -d ' \n' < VERSION)
BUILD="$ROOT/build"

log() { printf '[build] %s\n' "$*"; }
die() { printf '[build] 错误: %s\n' "$*" >&2; exit 1; }

# 0. 结束旧进程（App 由 install-service.sh 在 /Applications 覆盖安装）
log "结束旧进程 ..."
pkill -f "$APP_NAME" 2>/dev/null
sleep 1
pgrep -f "$APP_NAME" >/dev/null && pkill -9 -f "$APP_NAME" 2>/dev/null
mkdir -p "$BUILD"

# 1. 编译
log "编译 Swift 代码 (v$VER) ..."
swiftc -parse-as-library -O -framework Cocoa -o "$BUILD/$APP_NAME" NTFSMounter.swift || die "swiftc 编译失败"

# 2. 图标
log "生成图标 ..."
swift make-icon.swift "$BUILD/icon.png" >/dev/null 2>&1 || true
if [ -f "$BUILD/icon.png" ]; then
  ICONSET="$BUILD/icon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    sips -z $((s*2)) $((s*2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$BUILD/icon.icns" >/dev/null 2>&1 || true
fi

# 3. 组装 .app（先建到 build 目录，再整体拷入 /Applications，只需一次 sudo）
log "组装 $APP_NAME.app ..."
STAGE="$BUILD/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD/$APP_NAME" "$STAGE/Contents/MacOS/"
[ -f "$BUILD/icon.icns" ] && cp "$BUILD/icon.icns" "$STAGE/Contents/Resources/icon.icns"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>NTFS 工具</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VER</string>
	<key>CFBundleVersion</key><string>$VER</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$STAGE" >/dev/null 2>&1 || true

# 4. 安装到 /Applications + 安装 ntfsctl / 自动挂载服务 / sudoers 白名单
#    （所有提权收口到 install-service.sh，sudoers 仅放行该脚本与 ntfsctl）
log "安装到 /Applications 与安装服务 ..."
sudo bash "$ROOT/scripts/install-service.sh" "$USER" "$STAGE" \
  && log "服务安装完成" || log "警告: 服务安装未完成，可稍后手动运行 scripts/install-service.sh"

# 5. 前台运行
log "启动 $APP_NAME ..."
open "$APP_DIR"

# 6. 验证
sleep 2
[ -x "$APP_DIR/Contents/MacOS/$APP_NAME" ] || die ".app 结构不完整"
if pgrep -f "$APP_NAME" >/dev/null; then
  log "验证通过 ✔ $APP_NAME 正在运行（v${VER}）"
else
  log "警告: 未检测到 $APP_NAME 进程"
fi

# 7. 版本号 +0.0.1（满十进一）
NEW=$(awk -F. '{v=$1*10000+$2*100+$3+1; printf "%d.%d.%d\n", int(v/10000), int(v/100)%100, v%100}' <<<"$VER")
echo "$NEW" > VERSION
log "版本号已更新: $VER -> $NEW"
