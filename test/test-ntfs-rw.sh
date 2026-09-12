#!/bin/bash
# test-ntfs-rw.sh — 无真实 NTFS 盘的端到端验收（镜像盘全流程）
# 以 root 运行时直接执行；以普通用户运行时会提示 sudo 密码。
# 建议整脚本用 osascript 管理员方式执行：一次授权跑完全部。
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
MKNTFS=/usr/local/bin/mkntfs
IMG=/tmp/ntfs-test.img.dmg
LABEL=NTFSTEST
PASS=0
FAIL=0

ok()  { printf '  ✔ %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  ✘ %s\n' "$*"; FAIL=$((FAIL+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

step "1. 创建并附加磁盘镜像（GPT 分区表，模拟真实 NTFS 移动硬盘）"
rm -f "$IMG"
# GPTSPUD: 单分区 GPT 布局。GPT 下 NTFS 分区类型为 "Microsoft Basic Data"，
# 无需修改 MBR 分区类型字节（MBR 的 mkntfs 不会改类型字节，diskutil 仍显示 DOS_FAT_32）
hdiutil create -size 512m -fs FAT32 -layout GPTSPUD "$IMG" >/dev/null 2>&1 || bad "创建镜像失败"
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$DEV" ] && ok "附加镜像 -> $DEV" || bad "附加镜像失败"
PART="${DEV#/dev/}s1"
sleep 2   # 等待磁盘设备就绪，避免 mkntfs 立即操作失败

step "2. 格式化为 NTFS，拔出后重新插入（让 diskutil 探测出卷标）"
# 注意: mkntfs 需要完整设备路径 /dev/diskNs1，ntfsctl 则用无前缀 diskNs1
"$MKNTFS" -f -L "$LABEL" "/dev/$PART" >/dev/null 2>&1 && ok "mkntfs 格式化 $PART" || bad "mkntfs 格式化失败"
hdiutil detach "$DEV" >/dev/null 2>&1 || bad "detach 失败"
sleep 1
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${DEV#/dev/}s1"
[ -n "$DEV" ] && ok "重新附加 -> $DEV (分区 $PART)" || bad "重新附加失败"
sleep 1

step "3. list 检测"
LINE=""
for i in 1 2 3 4 5; do
  LINE=$("$NTFSCTL" list --porcelain | grep "^$PART|")
  [ -n "$LINE" ] && break
  sleep 2
done
[ -n "$LINE" ] && ok "list 检测到 $PART: $LINE" || bad "list 未检测到 $PART"
STATE=$(printf '%s' "$LINE" | cut -d'|' -f5)
printf '   初始状态: %s\n' "$STATE"

step "4. 挂载为读写"
"$NTFSCTL" mount "$PART" >/dev/null 2>&1 && ok "mount $PART" || bad "mount $PART 失败"
sleep 3
MOUNT_LINE=$(/sbin/mount | grep "fuse-t:/$LABEL" | head -1)
[ -n "$MOUNT_LINE" ] && ok "FUSE-T 挂载: $MOUNT_LINE" || bad "未发现 FUSE-T 挂载"
if /sbin/mount | grep -qE "/dev/$PART .*(read-only|fskit)"; then
  bad "存在只读寄生虫挂载"
else
  ok "无只读寄生虫挂载"
fi

step "5. 写入并校验"
MP="/Volumes/$LABEL"
if printf 'hello ntfsformac\n' > "$MP/rw-test.txt" 2>/dev/null; then
  ok "写入 rw-test.txt"
  [ "$(cat "$MP/rw-test.txt" 2>/dev/null)" = "hello ntfsformac" ] && ok "读回一致" || bad "读回不一致"
else
  bad "写入失败"
fi
if mdutil -s "$MP" 2>/dev/null | grep -qi "disabled"; then ok "Spotlight 已关闭"; else bad "Spotlight 未关闭"; fi

step "6. 弹出"
"$NTFSCTL" eject "$PART" >/dev/null 2>&1 && ok "eject $PART" || bad "eject $PART 失败"
sleep 2
/sbin/mount | grep -q "$LABEL" && bad "eject 后仍有挂载" || ok "eject 后无挂载"
pgrep -f "ntfs-3g .*/dev/$PART" >/dev/null && bad "eject 后仍有 ntfs-3g 进程" || ok "eject 后无 ntfs-3g 进程"
hdiutil detach "$DEV" >/dev/null 2>&1 && ok "detach $DEV" || ok "镜像已随 eject 分离"

printf '\n结果: 通过 %d 项, 失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] && exit 0 || exit 1
