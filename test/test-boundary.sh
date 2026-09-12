#!/bin/bash
# test-boundary.sh — 边界测试（需 root，sudo 运行）
# A) 中文+空格卷标的完整解析/挂载/读写
# B) unmount（不弹出）后状态与再次挂载
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
MKNTFS=/usr/local/bin/mkntfs
IMG=/tmp/ntfs-boundary.dmg
PASS=0; FAIL=0
ok(){ printf '  ✔ %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  ✘ %s\n' "$*"; FAIL=$((FAIL+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

step "A. 中文+空格卷标"
rm -f "$IMG"
hdiutil create -size 512m -fs FAT32 -layout GPTSPUD "$IMG" >/dev/null 2>&1 || bad "创建镜像失败"
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${DEV#/dev/}s1"
sleep 2
"$MKNTFS" -f -L "我的 移动盘" "/dev/$PART" >/dev/null 2>&1 && ok "mkntfs 格式化（卷标: 我的 移动盘）" || bad "mkntfs 失败"
hdiutil detach "$DEV" >/dev/null 2>&1
sleep 1
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${DEV#/dev/}s1"
sleep 2
LINE=$("$NTFSCTL" list --porcelain | grep "^$PART|")
printf '   list: %s\n' "$LINE"
echo "$LINE" | grep -q "我的 移动盘" && ok "list 完整显示中文+空格卷标" || bad "卷标被截断: $(echo "$LINE" | cut -d'|' -f2)"
"$NTFSCTL" mount "$PART" >/dev/null 2>&1 && ok "mount $PART" || bad "mount 失败"
sleep 3
/sbin/mount | grep -q "fuse-t:/我的 移动盘" && ok "FUSE-T 挂载（中文挂载点）" || bad "未挂载到中文挂载点"
if printf '边界测试\n' > "/Volumes/我的 移动盘/b.txt" 2>/dev/null; then
  ok "中文挂载点可写"
  [ "$(cat "/Volumes/我的 移动盘/b.txt" 2>/dev/null)" = "边界测试" ] && ok "读回一致" || bad "读回不一致"
else
  bad "写入失败"
fi

step "B. unmount 后再挂载"
"$NTFSCTL" unmount "$PART" >/dev/null 2>&1 && ok "unmount $PART" || bad "unmount 失败"
sleep 2
/sbin/mount | grep -q "fuse-t:/我的 移动盘" && bad "unmount 后仍挂载" || ok "unmount 后已卸载"
STATE=$("$NTFSCTL" list --porcelain | grep "^$PART|" | cut -d'|' -f5)
[ "$STATE" = "none" ] && ok "unmount 后状态 none（不弹出）" || bad "unmount 后状态: $STATE"
"$NTFSCTL" mount "$PART" >/dev/null 2>&1 && ok "再次 mount" || bad "再次 mount 失败"
sleep 3
printf '再挂载\n' > "/Volumes/我的 移动盘/b2.txt" 2>/dev/null && ok "再次挂载后可写" || bad "再次挂载后写入失败"

step "C. 清理"
"$NTFSCTL" eject "$PART" >/dev/null 2>&1 && ok "eject $PART" || bad "eject 失败"
sleep 2
hdiutil detach "$DEV" >/dev/null 2>&1
rm -f "$IMG"
printf '\n结果: 通过 %d 项, 失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] && exit 0 || exit 1
