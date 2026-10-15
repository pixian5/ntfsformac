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

step "5. exFAT / FAT32 卷标读取（macOS 不识别时卷名只能自己读）"
# exFAT 的卷标**不在 BPB 里**，而在根目录的 0x83 卷标条目中，需按簇堆参数换算偏移 —— 见 exfat_label()
for FS in "exfat:EXXTEST:newfs_exfat" "fat32:FAT32TST:newfs_msdos -F 32"; do
  kind="${FS%%:*}"; rest="${FS#*:}"; want="${rest%%:*}"; mkcmd="${rest#*:}"
  rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1
  DEV=$(attach_raw)
  if [ "$kind" = "exfat" ]; then
    /sbin/newfs_exfat -v "$want" "$DEV" >/dev/null 2>&1
  else
    $mkcmd -v "$want" "$DEV" >/dev/null 2>&1
  fi
  hdiutil detach "$DEV" >/dev/null 2>&1 || true; sleep 1
  DEV=$(attach_raw); D="${DEV#/dev/}"
  out=$("$NTFSCTL" probe "$D" 2>&1); printf '%s\n' "$out" | sed 's/^/   /'
  # 注意：变量后紧跟全角字符（「（」「，」等）必须写 ${var} 定界，否则变量名会被吞掉
  # （本项目已多次踩此坑，见 known-issues #38）
  printf '%s' "$out" | grep -q "卷标=$want" && ok "${kind} 卷标读取正确（${want}）" \
                                          || bad "${kind} 卷标读取失败（期望 ${want}）"
  hdiutil detach "$DEV" >/dev/null 2>&1 || true
done
rm -f "$IMG"

step "6. MSWIN4.1 歧义签名的消歧（FAT32 不得被误判为 BitLocker）"
# 背景：Windows 格式化的 FAT32 也写 MSWIN4.1 签名，若仅凭签名判 BitLocker，会出现
# 「分区找出来了却显示加密未解锁、不能挂」——用户反馈的「不能用」正是这一类。
# 这里把 is_bitlocker() 及其依赖 dev_io() 从源码里抽出来直接跑（脚本无法 source，用 awk 提取函数体）。
blsrc=$(awk '/^is_bitlocker\(\)/,/^}/' "$NTFSCTL")
iosrc=$(awk '/^dev_io\(\)/,/^}/' "$NTFSCTL")
[ -n "$blsrc" ] && [ -n "$iosrc" ] && ok "已从源码提取 is_bitlocker() 与 dev_io()" \
                                   || bad "未能提取 is_bitlocker() / dev_io()"
as_root_np() { "$@"; }     # 本测试以 root 运行：禁用提权包装，直接执行
eval "$iosrc"
eval "$blsrc"

# 6a. MSWIN4.1 + FAT32 BPB → 不是 BitLocker
rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1
DEV=$(attach_raw); newfs_msdos -F 32 -v FAT32TST "$DEV" >/dev/null 2>&1
printf 'MSWIN4.1' | dd of="$DEV" bs=1 seek=3 conv=notrunc >/dev/null 2>&1
if is_bitlocker "${DEV#/dev/}"; then bad "MSWIN4.1 的 FAT32 被误判为 BitLocker"; else ok "MSWIN4.1 的 FAT32 判定为非 BitLocker（BPB 类型串消歧）"; fi
hdiutil detach "$DEV" >/dev/null 2>&1 || true

# 6b. 经典 BitLocker 签名 -FVE-FS- → 仍判为 BitLocker（回归保护：签名路径不得被削弱）
rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1
DEV=$(attach_raw); printf -- '-FVE-FS-' | dd of="$DEV" bs=1 seek=3 conv=notrunc >/dev/null 2>&1
if is_bitlocker "${DEV#/dev/}"; then ok "-FVE-FS- 仍判为 BitLocker（签名路径未削弱）"; else bad "-FVE-FS- 被漏判"; fi
hdiutil detach "$DEV" >/dev/null 2>&1 || true

# 6c. MSWIN4.1 且 BPB 无类型串 → 走 dislocker-metadata 回退，无 BitLocker 元数据 → 非 BitLocker
rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1
DEV=$(attach_raw); printf 'MSWIN4.1' | dd of="$DEV" bs=1 seek=3 conv=notrunc >/dev/null 2>&1
if is_bitlocker "${DEV#/dev/}"; then bad "无 BPB 类型串的 MSWIN4.1 被误判为 BitLocker"; else ok "dislocker-metadata 回退判定为非 BitLocker"; fi
hdiutil detach "$DEV" >/dev/null 2>&1 || true

# 6d. 真实 BitLocker 盘（若已插入）→ dislocker-metadata 应能解析出卷头
if [ -b /dev/disk25s1 ]; then
  if is_bitlocker disk25s1; then ok "真实 BitLocker 盘 disk25s1 判定正确"; else bad "真实 BitLocker 盘被漏判（disk25s1）"; fi
else
  echo "   （disk25s1 未插入，跳过真实盘判定）"
fi
rm -f "$IMG"

step "7. 失效只读镜像的自动清理（拔盘未 eject 时的残留）"
mkdir -p "$RAW_DIR"
# (a) 失效：记录指向「不存在的设备节点」
touch "$RAW_DIR/disk99s9"; printf 'disk98' > "$RAW_DIR/disk99s9"; touch "$RAW_DIR/disk99s9.img"
touch "$RAW_DIR/disk99s8"; printf 'disk97' > "$RAW_DIR/disk99s8"
# (b) 有效：记录指向「真实存在的设备」（用刚附加的镜像设备名），应被保留
rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=64 >/dev/null 2>&1
DEV=$(attach_raw); LIVE="${DEV#/dev/}"
touch "$RAW_DIR/$LIVE"; printf 'disk96' > "$RAW_DIR/$LIVE"
"$NTFSCTL" list --porcelain >/dev/null 2>&1
[ -e "$RAW_DIR/disk99s9" ]     && bad "失效记录 disk99s9 未清理"   || ok "失效记录已清理（记录文件）"
[ -e "$RAW_DIR/disk99s9.img" ] && bad "失效镜像文件未清理"          || ok "失效镜像文件已清理"
[ -e "$RAW_DIR/disk99s8" ]     && bad "失效记录 disk99s8 未清理"   || ok "另一条失效记录也已清理"
[ -e "$RAW_DIR/$LIVE" ]        && ok "设备仍在的记录被保留（${LIVE}，未误删）" \
                              || bad "有效记录被误删（会给在用挂载造成麻烦）"
rm -f "$RAW_DIR/$LIVE"; hdiutil detach "$DEV" >/dev/null 2>&1 || true; rm -f "$IMG"

step "8. 清理测试镜像"
cleanup_all
ok "清理完成"

echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
