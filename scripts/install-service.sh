#!/bin/bash
# install-service.sh — 安装 ntfsctl + 自动挂载 LaunchDaemon（需以 root 运行）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OWNER_USER="${1:-}"

echo "[service] 安装 ntfsctl -> /usr/local/bin/ntfsctl"
install -m 755 "$SRC_DIR/scripts/ntfsctl" /usr/local/bin/ntfsctl

echo "[service] 安装自动挂载守护脚本 -> /usr/local/sbin/ntfs-automount.sh"
mkdir -p /usr/local/sbin
install -m 755 "$SRC_DIR/scripts/ntfs-automount.sh" /usr/local/sbin/ntfs-automount.sh

echo "[service] 写入 LaunchDaemon plist"
if [ -z "$OWNER_USER" ]; then
  OWNER_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
fi
sed "s/__NTFS_OWNER_USER__/$OWNER_USER/" \
  "$SRC_DIR/scripts/com.x.ntfsformac.automount.plist" \
  > /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

echo "[service] 重载 LaunchDaemon"
launchctl bootout system/com.x.ntfsformac.automount 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

echo "[service] 完成（属主: ${OWNER_USER}）"
