#!/bin/bash
# install-service.sh — 安装 NTFSFormac（App + ntfsctl + 自动挂载服务 + sudoers 白名单）
# 用法:
#   install-service.sh <owner-user> [<app-source-stage>]   # 需以 root 运行
#   <app-source-stage> 为组装好的 .app 目录（build-app.sh 传入），省略则只装服务
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OWNER_USER="${1:-}"
APP_SRC="${2:-}"

# 零参数调用时自行推导（build-app.sh 通过 sudoers 白名单以「零参数」形式免密调用本脚本；
# sudo 1.9.17 要求 NOPASSWD 命令的参数完全匹配，因此不能传参）：
#   OWNER_USER ← SUDO_USER（提权发起者），回退到控制台登录用户
#   APP_SRC    ← build-app.sh 的固定产物 build/NTFSMounter.app
[ -n "$OWNER_USER" ] || OWNER_USER="${SUDO_USER:-}"
[ -n "$OWNER_USER" ] || OWNER_USER="$(stat -f '%Su' /dev/console 2>/dev/null)"
[ -n "$APP_SRC" ] || APP_SRC="$SRC_DIR/build/NTFSMounter.app"

# 0. 安装 App（build-app.sh 组装好的 .app 整目录拷入 /Applications，只需一次提权）
if [ -n "$APP_SRC" ] && [ -d "$APP_SRC" ]; then
  echo "[service] 安装 App -> /Applications/NTFSMounter.app"
  rm -rf "/Applications/NTFSMounter.app"
  cp -R "$APP_SRC" "/Applications/NTFSMounter.app"
fi

# 1. 安装 ntfsctl
echo "[service] 安装 ntfsctl -> /usr/local/bin/ntfsctl"
install -m 755 "$SRC_DIR/scripts/ntfsctl" /usr/local/bin/ntfsctl

# 1.5 安装 dislocker（BitLocker 解锁/读写；二进制由 install-driver.sh 构建并暂存到 build/dislocker）
#     dislocker-fuse 通过 @rpath 找 libdislocker.0.7.dylib 与 libfuse-t.dylib（都在 /usr/local/lib）
if [ -x "$SRC_DIR/build/dislocker/dislocker-fuse" ]; then
  echo "[service] 安装 dislocker -> /usr/local/bin/"
  install -m 755 "$SRC_DIR/build/dislocker/dislocker-bek" \
                 "$SRC_DIR/build/dislocker/dislocker-file" \
                 "$SRC_DIR/build/dislocker/dislocker-fuse" \
                 "$SRC_DIR/build/dislocker/dislocker-metadata" /usr/local/bin/
  echo "[service] 安装 libdislocker -> /usr/local/lib/"
  cp -R "$SRC_DIR"/build/dislocker/libdislocker* /usr/local/lib/ 2>/dev/null || true
  chmod 755 /usr/local/lib/libdislocker.0.7.2.dylib 2>/dev/null || true
else
  echo "[service] 跳过 dislocker（$SRC_DIR/build/dislocker 无产物，请先运行 install-driver.sh）"
fi

# 2. 安装自动挂载守护脚本
echo "[service] 安装自动挂载守护脚本 -> /usr/local/sbin/ntfs-automount.sh"
mkdir -p /usr/local/sbin
install -m 755 "$SRC_DIR/scripts/ntfs-automount.sh" /usr/local/sbin/ntfs-automount.sh

# 3. 写入 LaunchDaemon plist
echo "[service] 写入 LaunchDaemon plist"
if [ -z "$OWNER_USER" ]; then
  OWNER_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
fi
sed "s/__NTFS_OWNER_USER__/$OWNER_USER/" \
  "$SRC_DIR/scripts/com.x.ntfsformac.automount.plist" \
  > /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

echo "[service] 重载 LaunchDaemon"
launchctl bootout system/com.x.ntfsformac.automount 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

# 4. 写入 sudoers 免密（白名单最小化，保持零弹窗）
#    放行：ntfsctl（App 日常操作）+ 项目固定路径的构建/测试/卸载脚本（自动化验证）
#    其余命令一律需要密码，杜绝 NOPASSWD: ALL
echo "[service] 写入 sudoers 免密（白名单最小化）"
SUDOERS_FILE=/etc/sudoers.d/ntfsformac
SUDOERS_TMP=$(mktemp /tmp/ntfsformac.sudoers.XXXXXX)
{
  printf '# NTFSFormac: 白名单最小化（其余命令需要密码）\n'
  printf '%s ALL=(ALL) NOPASSWD: /usr/local/bin/ntfsctl\n' "$OWNER_USER"
  # 注意：sudo 1.9.x 对带参数的 NOPASSWD 规则要求参数完全匹配，
  # 因此这里用通配符 *，既允许零参数调用也允许带 --device/--password-file 等参数
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/scripts/install-service.sh\n' "$OWNER_USER" "$SRC_DIR"
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/scripts/uninstall.sh\n' "$OWNER_USER" "$SRC_DIR"
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/test/test-ntfs-rw.sh*\n' "$OWNER_USER" "$SRC_DIR"
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/test/test-boundary.sh*\n' "$OWNER_USER" "$SRC_DIR"
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/test/test-automount.sh*\n' "$OWNER_USER" "$SRC_DIR"
  printf '%s ALL=(ALL) NOPASSWD: /bin/bash %s/test/test-bitlocker.sh*\n' "$OWNER_USER" "$SRC_DIR"
} > "$SUDOERS_TMP"
install -m 440 -o root -g wheel "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"
visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1 || { echo "[service] 警告: sudoers 语法校验失败，请检查 $SUDOERS_FILE"; }

echo "[service] 完成（属主: ${OWNER_USER}）"
