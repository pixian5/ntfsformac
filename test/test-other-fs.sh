#!/bin/bash
# test-other-fs.sh — 「其它分区」检测 + 只读裸镜像挂载（v0.0.15）
# 验证：非 NTFS/BitLocker 的 FAT 分区（如 Ventoy 的 VTOYEFI，分区类型 macOS 不识别）
#       能被探测、能被只读挂载、能被干净卸载（无残留镜像设备与临时文件）。
# 需 root：sudo -n /bin/bash /Users/x/code/ntfsformac/test/test-other-fs.sh
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
IMG=/tmp/ntfs-otherfs.img
RAW_DIR=/var/run/ntfsformac/raw-image
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

# 以「裸镜像」方式附加测试文件（无分区表），返回形如 /dev/disk30 的设备路径
attach_raw() {
  hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" 2>/dev/null \
    | awk '/^\/dev\/disk/{print $1}' | tail -1
}
cleanup_all() {
  hdiutil info 2>/dev/null | awk -v i="$IMG" '/^image-path/{p=$0} /^\/dev\/disk/{if (p ~ i) print $1}' \
    | while IFS= read -r d; do hdiutil detach "$d" -force >/dev/null 2>&1 || true; done
  rm -f "$IMG"
}
trap cleanup_all EXIT

step "0. 准备：造一个 64MB 的裸 FAT16 分区内容"
dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1 && ok "创建 64MB 空白镜像文件" || bad "创建镜像文件失败"
DEV=$(attach_raw)
[ -n "$DEV" ] && ok "以裸镜像方式附加: $DEV" || bad "附加失败"
newfs_msdos -F 16 -v VTOYEFI "$DEV" >/dev/null 2>&1 && ok "格式化为 FAT16（卷标 VTOYEFI）" || bad "newfs_msdos 失败"
hdiutil detach "$DEV" >/dev/null 2>&1 || true
sleep 1
DEV=$(attach_raw); D="${DEV#/dev/}"
echo "   （测试设备 = ${D}）"

step "1. probe 识别为 FAT16"
out=$("$NTFSCTL" probe "$D" 2>&1)
printf '%s\n' "$out" | sed 's/^/   /'
printf '%s' "$out" | grep -q FAT16 && ok "probe 识别为 FAT16" || bad "probe 未识别为 FAT16"

step "2. 只读挂载（走「其它分区」裸镜像路径）"
"$NTFSCTL" mount "$D" 2>&1 | sed 's/^/   /'
MP=$(/sbin/mount | grep -F " on /Volumes/VTOYEFI " | head -1 | sed 's/^.* on //; s/ (.*$//')
[ -n "$MP" ] && ok "已挂载到 ${MP}" || bad "未挂载"
/sbin/mount | grep -F "/Volumes/VTOYEFI (" | grep -q '\bread-only\b' && ok "确为只读挂载" || bad "不是只读挂载"
[ -f "$RAW_DIR/$D.img" ] && ok "已生成临时镜像文件" || bad "未生成临时镜像文件"

step "3. list 说明"
# 注意：`list` 只收录「外置物理盘」上的其它分区；本测试用的是 hdiutil 镜像（disk image，非 external），
# 因此预期 list 不收录它。真实外置盘上的效果已在手工验证中确认（disk25s2|VTOYEFI|fat16|...|ro）。

step "4. 卸载并清理"
"$NTFSCTL" unmount "$D" 2>&1 | sed 's/^/   /'
/sbin/mount | grep -qF "/Volumes/VTOYEFI (" && bad "卸载后仍存在 VTOYEFI 挂载" || ok "卸载后已无 VTOYEFI 挂载"
[ -e "$RAW_DIR/$D.img" ] && bad "临时镜像文件未清理" || ok "临时镜像文件已清理"
[ -e "$RAW_DIR/$D" ]     && bad "镜像设备记录未清理" || ok "镜像设备记录已清理"

step "5. 清理测试镜像"
cleanup_all
ok "清理完成"

echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
