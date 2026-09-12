#!/bin/bash
# test-automount.sh — LaunchDaemon 自动挂载验收（需 root，sudo 运行）
# 1) 创建 GPT NTFS 镜像并普通插入（模拟真实插拔，FSKit 会先只读挂载）
# 2) 等待 daemon 自动抢挂为读写
# 3) 验证可写
# 4) eject 后验证 eject marker 阻止 60s 内重挂
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
MKNTFS=/usr/local/bin/mkntfs
IMG=/tmp/ntfs-auto-test.dmg
LABEL=AUTOTEST
PASS=0; FAIL=0
ok(){ printf '  ✔ %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  ✘ %s\n' "$*"; FAIL=$((FAIL+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

step "1. 创建 GPT NTFS 镜像"
rm -f "$IMG"
hdiutil create -size 512m -fs FAT32 -layout GPTSPUD "$IMG" >/dev/null 2>&1 || bad "创建镜像失败"
DEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$DEV" ] || bad "附加失败"
PART="${DEV#/dev/}s1"
sleep 2
"$MKNTFS" -f -L "$LABEL" "/dev/$PART" >/dev/null 2>&1 && ok "mkntfs 格式化 $PART" || bad "mkntfs 格式化失败"
hdiutil detach "$DEV" >/dev/null 2>&1
sleep 1

step "2. 插入镜像（FSKit 只读挂载，等待 daemon 抢挂读写）"
ATT=$(hdiutil attach "$IMG" 2>&1)
echo "$ATT" | tail -2
DEV=$(printf '%s\n' "$ATT" | awk '/GUID_partition_scheme/ {print $1; exit}')
PART="${DEV#/dev/}s1"
[ -n "$DEV" ] && ok "重新附加 -> $DEV (分区 $PART)" || bad "重新附加失败"
sleep 1
RO=$(/sbin/mount | grep "/dev/$PART " | head -1)
[ -n "$RO" ] && printf '   FSKit 只读挂载: %s\n' "$RO" || echo "   （无 FSKit 只读挂载）"

step "3. 等待 daemon 自动挂载读写（最多 24 秒）"
OK=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if /sbin/mount | grep -q "fuse-t:/$LABEL"; then OK=1; break; fi
  sleep 2
done
if [ -n "$OK" ]; then
  ok "daemon 自动挂载: $(/sbin/mount | grep "fuse-t:/$LABEL" | head -1)"
else
  bad "daemon 未自动挂载"
  /usr/local/bin/ntfsctl list --porcelain
fi

step "4. 验证自动挂载后读写"
MP="/Volumes/$LABEL"
if printf 'auto-test\n' > "$MP/auto.txt" 2>/dev/null; then
  ok "可写入 auto.txt"
  [ "$(cat "$MP/auto.txt" 2>/dev/null)" = "auto-test" ] && ok "读回一致" || bad "读回不一致"
else
  bad "写入失败"
fi

step "5. eject + eject marker（daemon 60s 内不应重挂）"
"$NTFSCTL" eject "$PART" >/dev/null 2>&1 && ok "eject $PART" || bad "eject $PART 失败"
sleep 4
if /sbin/mount | grep -q "$LABEL"; then
  bad "eject 后 4 秒内被 daemon 重挂（marker 未生效）"
else
  ok "eject 后 daemon 未重挂（marker 生效）"
fi

step "6. 清理"
hdiutil detach "$DEV" >/dev/null 2>&1 || true
rm -f "$IMG"
printf '\n结果: 通过 %d 项, 失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] && exit 0 || exit 1
