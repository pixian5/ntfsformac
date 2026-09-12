#!/bin/bash
# ntfs-space-dbg.sh — 诊断含空格中文挂载点挂载失败（临时）
IMG=/tmp/ntfs-space.dmg
rm -f "$IMG"
hdiutil create -size 512m -fs FAT32 -layout GPTSPUD "$IMG" >/dev/null 2>&1
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${DEV#/dev/}s1"
sleep 2
/usr/local/bin/mkntfs -f -L "我的 移动盘" "/dev/$PART" >/dev/null 2>&1
hdiutil detach "$DEV" >/dev/null 2>&1
sleep 1
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${DEV#/dev/}s1"
echo "PART=$PART"
echo "== mkdir 中文挂载点 =="
mkdir -p "/Volumes/我的 移动盘" && echo "mkdir OK"
echo "== 手动 ntfs-3g 挂载（完整输出）=="
/usr/local/bin/ntfs-3g "/dev/$PART" "/Volumes/我的 移动盘" -o "recover,noatime,uid=501,gid=20,volname=我的 移动盘,local" 2>&1
echo "mount_exit=$?"
sleep 3
echo "== /sbin/mount =="
/sbin/mount | grep -i "我的"
echo "== ls /Volumes/我的 移动盘 =="
ls -la "/Volumes/我的 移动盘" 2>&1 | head -5
echo "== cleanup =="
pkill -f "ntfs-3g" 2>/dev/null
sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1
rm -f "$IMG"
echo done
