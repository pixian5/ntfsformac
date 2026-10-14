#!/bin/bash
# test-bitlocker.sh — BitLocker 解锁/读写能力测试
#
# 两种模式：
#   sudo bash test/test-bitlocker.sh
#       → 自检（无需真实加密盘）：验证组件安装、签名检测、错误处理、资源清理
#   sudo bash test/test-bitlocker.sh --device disk5s2 --password '密码'
#       → 真实 BitLocker 盘全流程：解锁 → 读写挂载 → 写文件校验 → 卸载 → 重新锁定 → 再解锁读回
#
# 建议整脚本以 root 运行（sudoers 已放行本脚本，免密）。
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
DISLOCKER=/usr/local/bin/dislocker-fuse
NTFS_3G=/usr/local/bin/ntfs-3g
MKNTFS=/usr/local/bin/mkntfs
IMG=/tmp/ntfsformac-bl-test.img.dmg
CNAME=SIGTEST
PASS=0
FAIL=0

ok()  { printf '  ✔ %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  ✘ %s\n' "$*"; FAIL=$((FAIL+1)); }
step(){ printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" = "0" ] || { echo "请以 root 运行：sudo bash $0"; exit 1; }

DEV=""; PW=""; PW_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device)        DEV="${2:-}"; shift 2 ;;
    --password)      PW="${2:-}"; shift 2 ;;
    --password-file) PW_FILE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
DEV="${DEV#/dev/}"

cleanup_image() {
  [ -n "${WDEV:-}" ] && { hdiutil detach "$WDEV" >/dev/null 2>&1 || true; }
  rm -f "$IMG"
}
trap cleanup_image EXIT

# ---------------------------------------------------------------- 1. 组件
step "1. 组件安装检查"
[ -x "$NTFSCTL" ]  && ok "ntfsctl 已安装"  || bad "ntfsctl 缺失（先运行 install-service.sh）"
[ -x "$NTFS_3G" ]  && ok "ntfs-3g 已安装"  || bad "ntfs-3g 缺失（先运行 install-driver.sh）"
[ -x "$DISLOCKER" ] && ok "dislocker-fuse 已安装" || bad "dislocker-fuse 缺失（先运行 install-driver.sh + install-service.sh）"
if [ -x "$DISLOCKER" ]; then
  otool -L "$DISLOCKER" 2>/dev/null | grep -q libfuse-t \
    && ok "dislocker-fuse 已链接 libfuse-t（FUSE-T 兼容）" \
    || bad "dislocker-fuse 未链接 libfuse-t"
  [ -e /usr/local/lib/libdislocker.0.7.dylib ] \
    && ok "libdislocker 已安装到 /usr/local/lib" || bad "libdislocker 缺失"
  # 真正加载一次动态库，确认 @rpath 能解析（-h 会打印用法并退出）
  "$DISLOCKER" -h >/dev/null 2>&1 && ok "dislocker-fuse 可正常启动（动态库解析成功）" || bad "dislocker-fuse 启动失败"
fi

# ---------------------------------------------------- 2. 合成签名镜像检测
step "2. BitLocker 签名检测（合成 -FVE-FS- 镜像，无需真实加密盘）"
rm -f "$IMG"
hdiutil create -size 64m -fs FAT32 -layout GPTSPUD "$IMG" >/dev/null 2>&1 || bad "创建镜像失败"
WDEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
[ -n "$WDEV" ] && ok "附加镜像 -> $WDEV" || bad "附加镜像失败"
PART="${WDEV#/dev/}s1"
sleep 2
"$MKNTFS" -f -L "$CNAME" "/dev/$PART" >/dev/null 2>&1 && ok "mkntfs 格式化 $PART" || bad "mkntfs 格式化失败"
# 把 NTFS 引导扇区偏移 3 起的 OEM 字段改成 BitLocker 签名 "-FVE-FS-"
printf '\xeb\x52\x90-FVE-FS-' | dd of="/dev/$PART" bs=1 seek=0 conv=notrunc >/dev/null 2>&1 \
  && ok "写入 -FVE-FS- 签名（模拟 BitLocker 引导扇区）" || bad "写入签名失败"
hdiutil detach "$WDEV" >/dev/null 2>&1 || bad "detach 失败"
sleep 1
WDEV=$(hdiutil attach -nomount "$IMG" 2>/dev/null | awk '{print $1}' | head -1)
PART="${WDEV#/dev/}s1"
sleep 1

LINE=""
for i in 1 2 3 4 5; do
  LINE=$("$NTFSCTL" list --porcelain | grep "^$PART|")
  [ -n "$LINE" ] && break
  sleep 2
done
if [ -n "$LINE" ]; then
  FS=$(printf '%s' "$LINE" | cut -d'|' -f3)
  ST=$(printf '%s' "$LINE" | cut -d'|' -f5)
  [ "$FS" = "bitlocker" ] && ok "list 识别为 bitlocker: $LINE" || bad "list 未识别为 bitlocker: $LINE"
  [ "$ST" = "locked" ] && ok "未解锁状态为 locked" || bad "状态应为 locked，实为 $ST"
else
  bad "list 未检测到 $PART"
fi

# ---------------------------------------------------- 3. 未解锁不自动挂载
step "3. 未解锁的加密卷不被自动挂载（不猜密码）"
"$NTFSCTL" mount "$PART" >/dev/null 2>&1
sleep 1
if /sbin/mount 2>/dev/null | grep -qF "/$PART on "; then
  bad "未解锁却被挂载了"
else
  ok "未解锁：mount 正确跳过，未产生挂载"
fi

# ------------------------------------------------- 4. 错误密码的清理保证
step "4. 解锁失败时资源清理（容器目录 / 互斥锁）"
OUT=$("$NTFSCTL" unlock "$PART" --password "wrong-password-test" 2>&1); RC=$?
[ "$RC" != "0" ] && ok "错误密码返回非零（预期）" || bad "错误密码竟然成功了"
printf '    输出: %s\n' "$OUT"
[ -d "/var/run/ntfsformac/bl/$PART" ] && bad "残留容器目录 /var/run/ntfsformac/bl/$PART" || ok "无残留容器目录"
[ -d /var/run/ntfsformac/mount.lock ] && bad "残留互斥锁 mount.lock" || ok "无残留互斥锁"
pgrep -f "dislocker-fuse .*/dev/$PART" >/dev/null \
  && bad "残留 dislocker-fuse 进程" || ok "无残留 dislocker-fuse 进程"
/sbin/mount 2>/dev/null | grep -qF "/ntfsformac/bl/$PART" && bad "残留容器挂载" || ok "无残留容器挂载"

# ------------------------------------------------------------ 5. 真实盘流程
if [ -z "$DEV" ]; then
  step "5. 真实加密盘全流程 — 跳过（未提供 --device）"
  printf '    如需端到端验证：插入 BitLocker 加密盘后运行\n'
  printf '      sudo bash %s --device diskXsY --password ""你的密码""\n' "$0"
else
  step "5. 真实加密盘全流程：$DEV"
  [ -n "$PW_FILE" ] && [ -r "$PW_FILE" ] && { PW=$(cat "$PW_FILE"); ok "从 $PW_FILE 读取密码"; }
  [ -n "$PW" ] || { bad "缺少 --password / --password-file"; }

  LINE=$("$NTFSCTL" list --porcelain | grep "^$DEV|" || true)
  printf '    list: %s\n' "$LINE"
  printf '%s' "$LINE" | grep -q '|bitlocker|' && ok "$DEV 是 BitLocker 卷" || bad "$DEV 不是 BitLocker 卷"

  "$NTFSCTL" unlock "$DEV" --password "$PW" >/dev/null 2>&1 \
    && ok "解锁成功" || bad "解锁失败"

  LABEL=$("$NTFSCTL" list --porcelain | grep "^$DEV|" | cut -d'|' -f2)
  MP="/Volumes/$LABEL"
  printf '    解密卷标: %s（挂载点 %s）\n' "$LABEL" "$MP"
  if /sbin/mount 2>/dev/null | grep -qF "fuse-t:/$LABEL on "; then
    ok "解密卷已挂载为读写"
    if printf 'bitlocker-rw-test\n' > "$MP/bl-rw-test.txt" 2>/dev/null; then
      ok "写入 bl-rw-test.txt"
      [ "$(cat "$MP/bl-rw-test.txt" 2>/dev/null)" = "bitlocker-rw-test" ] && ok "读回一致" || bad "读回不一致"
    else
      bad "写入失败"
    fi
  else
    bad "解密卷未挂载"
  fi

  "$NTFSCTL" unmount "$DEV" >/dev/null 2>&1 && ok "卸载解密卷" || bad "卸载失败"
  sleep 1
  "$NTFSCTL" lock "$DEV" >/dev/null 2>&1 && ok "重新锁定" || bad "锁定失败"
  sleep 1
  pgrep -f "dislocker-fuse .*/dev/$DEV" >/dev/null && bad "锁定后仍有 dislocker-fuse 进程" || ok "锁定后无 dislocker-fuse 进程"

  "$NTFSCTL" unlock "$DEV" --password "$PW" >/dev/null 2>&1 && ok "再次解锁" || bad "再次解锁失败"
  sleep 1
  if [ -f "$MP/bl-rw-test.txt" ]; then
    [ "$(cat "$MP/bl-rw-test.txt" 2>/dev/null)" = "bitlocker-rw-test" ] \
      && ok "重新解锁后数据仍在（读写持久化正常）" || bad "重新解锁后数据不一致"
  else
    bad "重新解锁后找不到写入的文件"
  fi
  "$NTFSCTL" eject "$DEV" >/dev/null 2>&1 && ok "安全弹出" || bad "安全弹出失败"
fi

printf '\n结果: 通过 %d 项, 失败 %d 项\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] && exit 0 || exit 1
