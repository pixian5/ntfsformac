#!/bin/bash
# final-check.sh — 最后一次授权：配置 sudoers 免密 + 安装 ntfsctl + 跑全量测试
echo "== 1. 配置 sudoers NOPASSWD =="
printf 'x ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/ntfsformac
chmod 440 /etc/sudoers.d/ntfsformac
/usr/sbin/visudo -c >/dev/null 2>&1 || { echo "visudo 校验失败，撤销配置"; rm -f /etc/sudoers.d/ntfsformac; exit 1; }
echo "sudoers 已配置并校验通过"

echo "== 2. 验证 sudo 免密 =="
su x -c "sudo -n true" && echo "sudo 免密 OK" || echo "sudo 免密验证失败"

echo "== 3. 安装 ntfsctl =="
install -m 755 /Users/x/code/ntfsformac/scripts/ntfsctl /usr/local/bin/ntfsctl
echo "ntfsctl 已安装"

echo "== 4. 跑全量测试 =="
bash /Users/x/code/ntfsformac/test/test-ntfs-rw.sh 2>&1
echo "测试退出码: $?"
