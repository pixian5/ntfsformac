#!/bin/bash
# ntfs-ctl-dbg.sh — 直接跑 ntfsctl mount 看真实错误（临时）
IMG=/tmp/ntfs-ctl.dmg
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
echo "== ntfsctl list =="
/usr/local/bin/ntfsctl list --porcelain
echo "== NTFS_MOUNT_DEBUG=1 ntfsctl mount =="
NTFS_MOUNT_DEBUG=1 /usr/local/bin/ntfsctl mount "$PART" 2>&1
echo "mount_exit=$?"
sleep 3
echo "== /sbin/mount =="
/sbin/mount | grep -i "我的"
echo "== ls 挂载点 =="
ls -la "/Volumes/我的 移动盘" 2>&1 | head -6
echo "== cleanup =="
pkill -f "ntfs-3g" 2>/dev/null
sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1
rm -f "$IMG"
echo done
