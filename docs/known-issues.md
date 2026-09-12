# 已知问题与经验（NTFSFormac）

本项目开发中踩过的坑和对应处理，按模块分类记录。

## 驱动安装

### 1. FUSE-T cask 只下载不安装
`brew install --cask macos-fuse-t/homebrew-cask/fuse-t` 有时注册了但 pkg 没真正装（无 pkgutil receipt）。
判断是否装好：`/usr/local/lib/libfuse-t.dylib` 存在 且 `/Library/Application Support/fuse-t/bin/go-nfsv4-*` 存在。
没装好就手动：`sudo installer -pkg <Caskroom 里的 pkg> -target /`。

### 2. ntfs-3g 源码构建时 autoreconf 报 `AC_PROG_LIBTOOL undefined`
macos-fuse-t/ntfs-3g 的 LT_INIT 藏在 `m4_ifdef` 后面，直接 `autoreconf -fi` 会失败。
解决：先 `glibtoolize --force --copy`，如生成了 `../ltmain.sh` 复制回当前目录，再 `autoreconf -fi`。
（Homebrew 的 GNU libtool 命令名带 `g` 前缀：`glibtoolize`。macOS 自带的 `/usr/bin/libtool` 是 Apple 的 Mach-O 工具，**不是** GNU libtool，用 `command -v libtool` 判断会误判已安装。）

### 3. 构建必须链接 libfuse-t
本机同时装有 macFUSE 和 FUSE-T 时，configure/make 可能链到 macFUSE 的 `libfuse.2.dylib`，而 macFUSE kext 在 macOS 26 Tahoe 上无法加载（要 Reduced Security），装出来等于废的。
每次安装/重装后验证：`otool -L /usr/local/bin/ntfs-3g | grep libfuse-t`，必须命中。
构建用：
```
export CPPFLAGS="-I/usr/local/include/fuse"
export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig"
./configure --prefix=/usr/local --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin
```

### 4. 同名公式冲突
`gromgit/fuse/ntfs-3g-mac`（macFUSE 版）与本项目装的 FUSE-T 版同名 `ntfs-3g`，且它在 `/opt/homebrew/bin` 占 PATH 优先位。
必须先构建好 FUSE-T 版（装到 /usr/local/bin）再 `brew uninstall ntfs-3g-mac`，避免出现无驱动窗口期。

## 运行权限

### 5. 完全磁盘访问（FDA）必配
macOS Sequoia+ 的 TCC 下，即使 root 进程访问 `/dev/diskX` 也会被拦（Operation not permitted）。
需手动在「系统设置 → 隐私与安全性 → 完全磁盘访问」添加：
- `/usr/local/bin/ntfs-3g`
- `/bin/bash`（自动挂载守护进程的解释器）

FDA 授权绑定二进制哈希：重装 ntfs-3g 后要重新添加。

### 6. FUSE-T 的 NFS 卷读不了（Operation not permitted）
FUSE-T 底层用 NFS，macOS 会拦网络卷访问。
系统设置 → 隐私与安全性 → 文件与文件夹 → 对使用的终端 / App 打开「网络宗卷」。

## macOS 26 Tahoe 特性

### 7. FSKit 只读寄生虫挂载
Tahoe 内置 FSKit NTFS 驱动会把 NTFS 自动挂成只读，且在我们挂载读写后会**反复**尝试再挂一个只读的。
处理：挂载前/后各清一次竞争者；守护进程每轮对已 RW 的盘检查 `/sbin/mount` 是否又冒出 `read-only|fskit`，有就重挂读写。
识别行：`/dev/diskXsY on /Volumes/xxx (read-only, ...)` 或含 `fskit`。

### 8. 僵尸 ntfs-3g 进程
USB 拔出后 `ntfs-3g` 可能残留，继续持有 `/Volumes/<label>`。
处理：eject 时按 `/dev/diskX` 匹配 `pgrep -f "ntfs-3g .*/dev/diskX"`，先 SIGTERM 优雅退出（让 FUSE-T 正常注销 NFS），1 秒后仍存活才 KILL。
**严禁直接 kill -9**：会撕掉 FUSE-T 的 NFS 通道，macOS 会像断电一样弹掉整个 USB 设备。

## 挂载细节

### 9. FUSE-T 挂载点 diskutil 不认
FUSE-T 挂载是 NFS 卷，`diskutil info` 不报挂载点，`diskutil eject` 也必然失败。
处理：eject 前先按 **label 精确匹配** `fuse-t:/<label>` 解挂（避免两盘并存时误杀另一块），再 SIGTERM ntfs-3g，最后才 `diskutil eject` 父盘。

### 10. Spotlight / fseventsd 锁文件
NTFS 卷上 Spotlight 和 fseventsd 会占用文件，导致 Finder 删除报「占用」。
处理：每次挂载后 `mdutil -i off <mp>` + 建 `.fseventsd/no_log`。

### 11. root 挂载导致 uid=0
守护进程以 root 挂载时若不带 uid/gid，挂出来的文件全是 root 所有，普通用户写不了。
处理：属主解析链 `NTFS_OWNER_USER` env → `stat -f '%Su' /dev/console`（GUI 登录用户）→ dscl 找第一个 uid≥501；解析到 0 则拒绝挂载。挂载参数带 `uid=,gid=`。

### 12. 防止 eject 后守护进程立刻重挂
eject 时在 `/var/run/ntfsformac/ejecting.<dev>` 写标记，守护进程 60 秒 TTL 内跳过该盘，超时自动删除。

### 13. 卷标/挂载点含空格时 awk 字段解析全部失效
`/sbin/mount` 输出形如 `fuse-t:/我的 移动盘 on /Volumes/我的 移动盘 (nfs)`，空格分词后 `$1=fuse-t:/我的`，永远匹配不上 `fuse-t:/我的 移动盘`。
症状：中文+空格卷标的盘 `ntfsctl list` 状态永远 none、unmount/eject 实际没卸载却报成功、僵尸挂载残留。
处理：**禁止用 awk 按字段匹配挂载表**。统一改用：
- `grep -F "/dev/$dev on "` / `grep -F "fuse-t:/$label on "` 全行匹配；
- `sed 's/^.* on //; s/ ([^)]*)$//'` 提取挂载点。
（`diskutil list` 解析卷标时也要把中间字段 join 起来，不能只取第 3 个字段。）

### 14. 手动 unmount 后守护进程 3 秒内自动重挂
守护进程每 3 秒轮询，手动卸载后 state=none，下一轮立刻重挂读写，导致「卸载」无效。
处理：unmount 时同样写 `ejecting.<dev>` 标记（60s TTL），尊重手动卸载意图；eject 是卸载+弹父盘，unmount 是只卸载不弹。

## 其它

### 15. 测试镜像盘的坑
- `hdiutil create -size 512m -layout NONE xxx.img` 会生成 `xxx.img.dmg`，attach 时要带 `.dmg`。
- `hdiutil attach -nomount` 可避免 macOS 自动挂载；`diskutil eject` 对磁盘镜像等价 detach。
- 用镜像盘测试正好能复现 Tahoe 的 FSKit 只读自动挂载行为。

### 16. macOS bash 是 3.2
无关联数组、无 `printf '%(...)T'`。脚本一律用空格字符串模拟集合、用 case 状态机。
