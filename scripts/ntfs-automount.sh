#!/bin/bash
# ntfs-automount.sh — 自动挂载守护进程（root，由 launchd 启动）
# 每 3 秒扫描一次 NTFS 盘：
#   - 新盘(未挂载/只读) → 挂载为读写
#   - 已读写挂载但 Tahoe FSKit 又挂了个只读寄生虫 → 清理
# 尊重 /var/run/ntfsformac/ejecting.<dev> 标记（用户手动弹出后 60s 内不重挂）
set -uo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin"
NTFSCTL=/usr/local/bin/ntfsctl
MARKER_DIR=/var/run/ntfsformac
MARKER_TTL=60
POLL=3

log() { printf '[automount %s] %s\n' "$$" "$*"; }

mkdir -p "$MARKER_DIR" 2>/dev/null || true

log "自动挂载守护进程已启动 (NTFS_OWNER_USER=${NTFS_OWNER_USER:-auto})"

while true; do
  # 过期 eject marker 清理
  now=$(date +%s)
  for m in "$MARKER_DIR"/ejecting.*; do
    [ -e "$m" ] || continue
    if [ $(( now - $(stat -f '%m' "$m" 2>/dev/null || echo 0) )) -gt "$MARKER_TTL" ]; then
      rm -f "$m"
    fi
  done

  # 扫描
  "$NTFSCTL" list --porcelain 2>/dev/null | while IFS='|' read -r dev label fs mp state; do
    [ -n "$dev" ] || continue
    # eject 中 → 跳过
    [ -e "$MARKER_DIR/ejecting.$dev" ] && continue

    case "$state" in
      rw)
        # 检查是否又有只读寄生虫（Tahoe FSKit 会反复挂）
        if /sbin/mount 2>/dev/null | grep -qE "/dev/$dev .*read-only"; then
          log "检测到 $dev ($label) 的只读寄生虫挂载，重新挂载读写"
          "$NTFSCTL" mount "$dev" >>/var/log/ntfsformac-automount.log 2>&1
        fi
        ;;
      ro|none)
        log "自动挂载读写: $dev ($label, state=$state)"
        "$NTFSCTL" mount "$dev" >>/var/log/ntfsformac-automount.log 2>&1
        sleep 2
        ;;
    esac
  done

  sleep "$POLL"
done
