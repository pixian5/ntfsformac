# 驱动安装 / 重装 / 卸载手册

## 一、安装

```bash
bash install-driver.sh
```

脚本做的事（可重复运行，已装好的步骤会跳过）：

1. 检查 FUSE-T 运行时（`/usr/local/lib/libfuse-t.dylib` + `/Library/Application Support/fuse-t/bin/go-nfsv4-*`），缺失则装 cask `macos-fuse-t/homebrew-cask/fuse-t`。
2. 安装构建依赖：autoconf automake glibtoolize pkg-config libgcrypt。
3. 从 `https://github.com/macos-fuse-t/ntfs-3g.git` 克隆源码，`autogen.sh`（失败则 glibtoolize + autoreconf -fi）→ configure（`--with-fuse=external`，链接 libfuse-t）→ make → `make install`（此步弹管理员密码）。
4. 卸载 gromgit 的 macFUSE 版 `ntfs-3g-mac`（避免同名冲突）。
5. 三项验证：`ntfs-3g --version`、`otool -L` 命中 libfuse-t、`mkntfs --version`。

安装产物：
- `/usr/local/bin/ntfs-3g`、`/usr/local/bin/mkntfs`、`/usr/local/bin/ntfsfix` 等（ntfsprogs 全套）
- `/usr/local/lib/libntfs-3g.dylib`、`/usr/local/lib/ntfs-3g/`（插件）

安装后必须手动做一次：**系统设置 → 隐私与安全性 → 完全磁盘访问** → 添加 `/usr/local/bin/ntfs-3g` 和 `/bin/bash`。

## 二、重装 / 升级

```bash
rm -f /usr/local/bin/ntfs-3g
rm -rf /tmp/ntfs-3g-fuse-t-build
bash install-driver.sh     # 会重新构建
```

重装后记住：
- FDA 授权绑定哈希，重新添加 ntfs-3g 到完全磁盘访问。
- `otool -L /usr/local/bin/ntfs-3g` 确认链到 libfuse-t（不是 macFUSE）。

## 三、卸载

```bash
# 1. 停守护进程
sudo launchctl bootout system/com.x.ntfsformac.automount
sudo rm -f /Library/LaunchDaemons/com.x.ntfsformac.automount.plist

# 2. 删二进制与脚本
sudo rm -f /usr/local/bin/ntfs-3g /usr/local/bin/mkntfs /usr/local/bin/ntfsfix \
           /usr/local/bin/ntfsls /usr/local/bin/ntfsctl \
           /usr/local/bin/lowntfs-3g /usr/local/bin/ntfs-3g.probe \
           /usr/local/bin/ntfscp /usr/local/bin/ntfsclone \
           /usr/local/bin/ntfscluster /usr/local/bin/ntfscat \
           /usr/local/bin/ntfslabel /usr/local/bin/ntfsresize \
           /usr/local/bin/ntfsundelete /usr/local/bin/ntfsinfo
sudo rm -f /usr/local/sbin/mount.ntfs-3g /usr/local/sbin/ntfs-automount.sh
sudo rm -rf /usr/local/lib/ntfs-3g /usr/local/include/ntfs-3g
sudo rm -rf /var/run/ntfsformac

# 3. 卸 FUSE-T（可选，其它工具可能也用）
brew uninstall --cask macos-fuse-t/homebrew-cask/fuse-t
# 或手动删：/usr/local/lib/libfuse-t*、/usr/local/include/fuse*、/Library/Application Support/fuse-t
```
