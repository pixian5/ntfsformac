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

  # 拔盘残留清理：FUSE-T 挂载的卷对应的设备节点已消失（盘被拔出/换盘）
  # 注意：不能用 ntfsctl list 快照判断（diskutil 在 detach/抢占瞬间可能输出异常导致误判），
  #       必须核对设备节点 /dev/diskXsY 是否真的不存在。
  /sbin/mount 2>/dev/null | grep "fuse-t:/" | while IFS= read -r mline; do
    mp=$(printf '%s' "$mline" | sed 's/^.* on //; s/ ([^)]*)$//')
    [ -n "$mp" ] || continue
    # 从 ntfs-3g 进程命令行提取该挂载点对应的设备节点（如 /dev/disk5s1）
    dev=$(ps -axo command 2>/dev/null | grep "ntfs-3g " | grep -F " $mp" | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^\/dev\/disk/) print $i}')
    # 无对应进程或设备节点仍在 → 正常挂载，跳过
    [ -n "$dev" ] || continue
    [ -e "$dev" ] && continue
    log "检测到残留挂载（设备 $dev 已消失）: $mp，清理中"
    diskutil unmount force "$mp" >/dev/null 2>&1 || umount -f "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
  done

  # 扫描
  # 字段: device|label|fs|mountpoint|state|guid
  # read 的最后一个变量会吞下「本行剩余全部」（含分隔符），必须把 6 个字段都声明出来，
  # 并多留一个 _rest 兜底（以后再加字段也不会重演）。
  #
  # 实测（bash 3.2，IFS='|'）：
  #   5 字段读「disk26s1|AUTOTEST|ntfs|/Volumes/AUTOTEST|ro|」 → state="ro"      ← 尾部空字段被剥掉
  #   5 字段读「disk4s1|Ventoy|bitlocker|/Volumes/V|rw|4967D63B-…」→ state="rw|4967D63B-…" ← 被污染
  # 所以 v0.0.12 加 guid 之后的实际影响面是：**NTFS 卷（guid 为空）不受影响**（bash 剥掉尾部空字段），
  # 只有 **BitLocker 卷（guid 非空）** 的 state 被污染，导致其 rw / ro|none 分支失配
  # （表现为不清理只读寄生虫、ro/none 时不自动挂载）。
  # 注意 zsh 的 read 不会剥掉尾部空字段（会得到 "ro|"），调试时若用 zsh 复现会得到与 bash 不同的结论——
  # 本脚本由 launchd 以 /bin/bash 执行，务必用 bash 复现。
  "$NTFSCTL" list --porcelain 2>/dev/null | while IFS='|' read -r dev label fs mp state guid _rest; do
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
