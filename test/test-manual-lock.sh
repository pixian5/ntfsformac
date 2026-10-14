#!/bin/bash
# test-manual-lock.sh — 验证「手动锁定标记」机制与守护进程 porcelain 字段解析（v0.0.14）
# 需 root 运行（要读 /var/run/ntfsformac、调用 ntfsctl）：
#   sudo -n /bin/bash /Users/x/code/ntfsformac/test/test-manual-lock.sh
set -uo pipefail

NTFSCTL=/usr/local/bin/ntfsctl
MARKER_DIR=/var/run/ntfsformac
AUTO=/usr/local/sbin/ntfs-automount.sh
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "==== test-manual-lock (v0.0.14) ===="

# ---------- 用例1：守护进程的 porcelain 解析（6 字段）----------
# 复刻 ntfs-automount.sh 里的 read 语句，确认 state 字段被正确切分。
# 背景：v0.0.12 给 porcelain 加了第 6 字段 guid，若 read 只声明 5 个变量，
#       最后一个变量会吞掉「本行剩余」，**第 6 字段非空（BitLocker）时** state 会被污染成 "rw|<guid>"。
echo "== 用例1：守护进程 porcelain 解析 =="
new_out=$(printf 'disk99s1|标签X|bitlocker|/Volumes/标签X|rw|4967D63B-2E29-4AD8-8399-F6A339E3D001\n' \
  | while IFS='|' read -r dev label fs mp state guid _rest; do
      if [ "$state" = "rw" ]; then echo "MATCH-rw"; else echo "NO-MATCH(state=$state)"; fi
    done)
[ "$new_out" = "MATCH-rw" ] && ok "新写法（含 guid+_rest）state 解析为 rw" \
                            || bad "新写法解析错误: $new_out"

# 复现修前的旧写法：**第 6 字段非空（BitLocker）** 时 state 被污染成 "rw|<guid>"，分支失配。
# 这是本回归的真实影响面 —— 只有 BitLocker 卷（guid 非空）会踩到。
old_out=$(printf 'disk99s1|标签X|bitlocker|/Volumes/标签X|rw|GUID\n' \
  | while IFS='|' read -r dev label fs mp state; do
      if [ "$state" = "rw" ]; then echo "MATCH-rw"; else echo "NO-MATCH(state=$state)"; fi
    done)
[ "$old_out" = "NO-MATCH(state=rw|GUID)" ] && ok "复现旧写法在 BitLocker 行上的污染（state=rw|GUID）" \
                                          || bad "未能复现旧写法: $old_out"

# 边界：第 6 字段为空（NTFS 卷）时，**bash 会把尾部的空字段连同分隔符一起剥掉**，
# 所以 NTFS 卷在旧写法下 state 仍是干净的 "ro" → 自动挂载并未失效。
# （曾用 zsh 复现时得到 "ro|"，与 bash 结论不同，误导过排查；本脚本由 /bin/bash 执行，故以 bash 为准。）
bash_ntfs=$(printf 'disk99s1|AUTOTEST|ntfs|/Volumes/AUTOTEST|ro|\n' \
  | while IFS='|' read -r dev label fs mp state; do echo "$state"; done)
[ "$bash_ntfs" = "ro" ] && ok "边界：bash 下 NTFS 行（尾部空字段）state 仍为 ro，未受影响" \
                       || bad "bash 剥除尾部空字段的行为与预期不符: $bash_ntfs"

# zsh 行为对照（不参与判定，仅记录两种 shell 的差异，避免后人再用 zsh 复现时被误导）
zsh_ntfs=$(printf 'disk99s1|AUTOTEST|ntfs|/Volumes/AUTOTEST|ro|\n' \
  | zsh -c 'while IFS="|" read -r dev label fs mp state; do echo "$state"; done' 2>/dev/null)
[ "$zsh_ntfs" = "ro|" ] && ok "对照：zsh 下同样输入得到 ro|（保留尾部字段，与 bash 不同）" \
                        || bad "zsh 行为与预期不符: $zsh_ntfs"

# 已安装的守护脚本必须已修好
grep -q 'read -r dev label fs mp state guid _rest' "$AUTO" \
  && ok "已安装的 $AUTO 使用 6 字段读取" \
  || bad "已安装的 $AUTO 未采用 6 字段读取（BitLocker 行会被污染）"

# ---------- 用例2：prune 清理指向「不存在设备」的标记 ----------
echo "== 用例2：清理失效的手动锁定标记 =="
mkdir -p "$MARKER_DIR"
touch "$MARKER_DIR/locked.disk99s1"          # 该设备节点不存在
"$NTFSCTL" list --porcelain >/dev/null 2>&1  # list 内部会调用 prune_locked_markers
if [ -e "$MARKER_DIR/locked.disk99s1" ]; then
  bad "指向不存在设备的标记未被清理（拔盘后仍会挡住自动解锁）"
else
  ok "指向不存在设备的标记已自动清理"
fi

# ---------- 用例3：eject_one 已纳入互斥锁（源码静态检查）----------
# 弹出会解挂 FUSE + 杀 ntfs-3g + 拆 dislocker 容器 + diskutil eject，
# 与挂载/解锁并发时会互相踩（刚弹出又被挂回、容器半拆），必须持同一把锁。
echo "== 用例3：eject_one 持有互斥锁 =="
eject_src=$(awk '/^eject_one\(\)/,/^}/' "$NTFSCTL")
printf '%s' "$eject_src" | grep -q 'lock_mount' \
  && ok "eject_one 内调用 lock_mount（不再与他人并发）" \
  || bad "eject_one 未持锁"
printf '%s' "$eject_src" | grep -q "trap 'unlock_mount' EXIT" \
  && ok "eject_one 注册 EXIT 释放，异常退出也会解锁" \
  || bad "eject_one 未注册 EXIT 释放"

# lock 也必须持同一把锁（v0.0.13 已修，回归保护）
lock_src=$(awk '/^bl_lock_one\(\)/,/^}/' "$NTFSCTL")
printf '%s' "$lock_src" | grep -q 'lock_mount' \
  && ok "bl_lock_one 内调用 lock_mount" || bad "bl_lock_one 未持锁"

# ---------- 用例4：lock 落标记 / unlock 清标记（源码约定检查）----------
echo "== 用例4：标记的落与清 =="
printf '%s' "$lock_src" | grep -q 'locked\.\$dev' \
  && ok "bl_lock_one 落下 locked.<dev> 标记" || bad "bl_lock_one 未落标记"
unlock_src=$(awk '/^bl_unlock_one\(\)/,/^}/' "$NTFSCTL")
printf '%s' "$unlock_src" | grep -q 'locked_mark_clear' \
  && ok "bl_unlock_one 清除 locked.<dev> 标记" || bad "bl_unlock_one 未清标记"
printf '%s' "$eject_src" | grep -q 'locked_mark_clear' \
  && ok "eject_one 清除 locked.<dev> 标记" || bad "eject_one 未清标记"

# ---------- 用例5：互斥锁本身可获取/释放 ----------
echo "== 用例5：互斥锁可获得与释放 =="
"$NTFSCTL" list --porcelain >/dev/null 2>&1 || true
if mkdir /var/run/ntfsformac/mount.lock 2>/dev/null; then
  rmdir /var/run/ntfsformac/mount.lock
  ok "mount.lock 可原子获取并释放（当前无残留锁）"
else
  bad "mount.lock 已被占用（可能有残留锁，检查 /var/run/ntfsformac/mount.lock）"
fi

echo "==== 结果: PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
