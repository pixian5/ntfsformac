#!/bin/bash
# uninstall.sh — 完全卸载 NTFSFormac（驱动 + 服务 + App）
# 用法:
#   bash uninstall.sh             # 连 FUSE-T 一起卸载
#   bash uninstall.sh --keep-fuse-t   # 保留 FUSE-T（其它工具可能也在用）
set -uo pipefail

log() { printf '[uninstall] %s\n' "$*"; }

# 0. 结束 App
log "结束 NTFSMounter ..."
pkill -f NTFSMounter 2>/dev/null
sleep 1
pgrep -f NTFSMounter >/dev/null && pkill -9 -f NTFSMounter 2>/dev/null || true

# 1. 停自动挂载守护进程并删除 plist
log "停止自动挂载服务 ..."
sudo launchctl bootout system/com.x.ntfsformac.automount 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

# 2. 删除二进制、脚本、库与运行目录
log "删除驱动与服务文件 ..."
sudo rm -f /usr/local/bin/ntfs-3g /usr/local/bin/mkntfs /usr/local/bin/ntfsfix \
           /usr/local/bin/ntfsls /usr/local/bin/ntfsctl /usr/local/bin/lowntfs-3g \
           /usr/local/bin/ntfs-3g.probe /usr/local/bin/ntfscp /usr/local/bin/ntfsclone \
           /usr/local/bin/ntfscluster /usr/local/bin/ntfscat /usr/local/bin/ntfslabel \
           /usr/local/bin/ntfsresize /usr/local/bin/ntfsundelete /usr/local/bin/ntfsinfo
sudo rm -f /usr/local/sbin/mount.ntfs-3g /usr/local/sbin/ntfs-automount.sh
sudo rm -rf /usr/local/lib/ntfs-3g /usr/local/include/ntfs-3g
sudo rm -f /usr/local/lib/libntfs-3g.dylib
sudo rm -rf /var/run/ntfsformac

# 3. 移除 sudoers 免密配置（build-app.sh / 安装服务时写入）
log "移除 sudoers 免密配置 ..."
sudo rm -f /etc/sudoers.d/ntfsformac

# 4. 删除 App
log "删除 /Applications/NTFSMounter.app ..."
sudo rm -rf "/Applications/NTFSMounter.app"

# 5. 卸载 FUSE-T（默认；--keep-fuse-t 保留）
if [ "${1:-}" != "--keep-fuse-t" ]; then
  log "卸载 FUSE-T ..."
  if command -v brew >/dev/null 2>&1 && brew list --cask 2>/dev/null | grep -q "^fuse-t$"; then
    brew uninstall --cask macos-fuse-t/homebrew-cask/fuse-t 2>/dev/null || log "FUSE-T cask 卸载失败，可手动运行 brew uninstall --cask fuse-t"
  else
    sudo rm -rf "/Library/Application Support/fuse-t"
    sudo rm -f /usr/local/lib/libfuse-t* /usr/local/include/fuse*
  fi
else
  log "保留 FUSE-T（--keep-fuse-t）"
fi

log "卸载完成。若安装过 pkg（com.x.ntfsformac.pkg），可再运行: sudo pkgutil --forget com.x.ntfsformac.pkg"
