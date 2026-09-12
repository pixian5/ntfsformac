# NTFSFormac — macOS NTFS 读写菜单栏 App 实现计划

## Context（背景）

macOS 13 起移除了系统内置 NTFS 写入支持，macOS 26 Tahoe 上只有只读（且 FSKit 只读驱动还会抢占挂载）。用户选定的方案：**FUSE-T（无内核扩展）+ ntfs-3g（macos-fuse-t 分支）+ Swift 菜单栏 App（自动挂载/卸载）**，目标是做一个开源工具，在 Apple Silicon / macOS 26 上实现 NTFS 读写。

项目目录 `/Users/x/code/ntfsformac`（当前为空）。用户约定：做成 .app 复制到 /Applications 前台运行、版本号 0.0.1 起步、中文 commit 推送 GitHub（pixian5，可建仓）、经验写 docs/、修改后必须验证成功。

### 已核实的关键事实（决定实现路径）
- 本机已装 macfuse cask 5.x + gromgit/fuse/ntfs-3g-mac 2026.7.7，但其二进制链接 macFUSE 的 `libfuse.2.dylib`，Tahoe 上 kext 无法加载，**实际不可用**（仅其 ntfsprogs 工具 mkntfs/ntfsfix/ntfsls 可用）。
- FUSE-T 已装旧版 1.0.49（`/usr/local/lib/libfuse-t-1.0.49.dylib`、`/Library/Application Support/fuse-t/`），最新 cask 为 1.2.7。
- **`macos-fuse-t/homebrew-fuse-t` tap 不存在（已核实 404）**，FUSE-T 兼容的 ntfs-3g 只能从 `https://github.com/macos-fuse-t/ntfs-3g.git` 源码构建。
- 构建命令（已验证可行）：
  ```
  export CPPFLAGS="-I/usr/local/include/fuse"
  export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig"
  ./autogen.sh  # 若报 ltmain.sh/autoreconf 错则 autoreconf -fi
  ./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin
  make -j$(sysctl -n hw.ncpu) && sudo make install
  ```
  装完必须 `otool -L /usr/local/bin/ntfs-3g | grep libfuse-t` 验证链接正确。
- 参考项目（MIT，只借鉴模式不照抄）：[ArrivaRUS/ntfs-mounter-macos](https://github.com/ArrivaRUS/ntfs-mounter-macos) — 同路线：bash CLI + root LaunchDaemon 轮询 + 单文件 Swift 菜单栏 App。

## 冲突处理决策
1. **macfuse cask 保留不动**：FUSE-T fork 用 `-lfuse-t` 显式链接，不碰 macFUSE 库；卸载 macfuse 风险高无收益。唯一注意：`/usr/local/include/fuse` 头文件路径共用，以 `otool -L` 兜底验证。
2. **卸载 gromgit/fuse/ntfs-3g-mac**（构建好 FUSE-T 版之后再卸，避免无驱动窗口期）：同名二进制在 /opt/homebrew/bin 占 PATH 优先位，留着会静默链到 macFUSE 版。FUSE-T fork `make install` 会装全套 ntfsprogs（mkntfs/ntfsfix/ntfsls）到 /usr/local/bin，功能不损失。

## 项目结构
```
/Users/x/code/ntfsformac/
├── VERSION                      # 0.0.1，build-app.sh 构建后 +0.0.1（满十进一）
├── .gitignore                   # build/ *.img *.dmg .DS_Store 等
├── README.md                    # 安装/使用/架构
├── install-driver.sh            # 驱动安装：FUSE-T + ntfs-3g(fork 源码构建)
├── scripts/
│   ├── ntfsctl                  # bash3.2 CLI：list/mount/unmount/eject/auto
│   ├── ntfs-automount.sh        # LaunchDaemon 轮询（root，3s）
│   └── com.x.ntfsformac.automount.plist
├── NTFSMounter.swift            # 菜单栏 App（单文件 swiftc 编译）
├── make-icon.swift              # AppKit 画 1024x1024 icns
├── build-app.sh                 # 编译+打包+.app 装 /Applications+前台运行+版本号+1
├── test/test-ntfs-rw.sh         # 无真实盘验收：hdiutil+mkntfs+读写+eject 全流程
└── docs/
    ├── known-issues.md          # FUSE-T 安装坑/FDA/Network Volumes/FSKit 复发/僵尸进程
    └── driver-install.md        # 驱动安装/重装/卸载手册
```

## 各组件要点

### install-driver.sh
1. 环境检查（arm64、macOS>=26、brew、xcode-select）。
2. `brew install --cask macos-fuse-t/homebrew-cask/fuse-t`（1.2.7）；验证 `/usr/local/lib/libfuse-t.dylib` 与 `/Library/Application Support/fuse-t/bin/go-nfsv4*`，cask 只下不装则手动 `sudo installer -pkg <pkg> -target /`。
3. `brew install autoconf automake libtool pkg-config libgcrypt`。
4. clone macos-fuse-t/ntfs-3g 到 /tmp，按上文命令构建（autogen.sh 报错则 autoreconf -fi）。
5. `brew uninstall ntfs-3g-mac`（卸 gromgit）。
6. 三验证：`ntfs-3g --version` / `otool -L` 含 libfuse-t / `mkntfs --version`，全过才算成功。
7. FDA 指引打印（脚本无法自动授权）。

### scripts/ntfsctl（bash 3.2 兼容，不用 set -e，不用关联数组）
- 固定路径 `NTFS_3G=/usr/local/bin/ntfs-3g`、`MARKER_DIR=/var/run/ntfsformac`。
- `list [--porcelain]`：`diskutil list` awk 抓 `Windows_NTFS|Microsoft Basic Data` 的 `diskXsY` → `diskutil info` 取 label/mount；挂载点缺失时回退 `/sbin/mount`（按 /dev 匹配 → 按 `fuse-t:/label` → 按 /Volumes/label 猜测）。`--porcelain` 输出 `device|label|fs|mountpoint|state`（state：`fuse-t:|ntfs-3g`→RW，`read-only|fskit`→RO）。
- `mount <disk|label|all>`：解析设备 → 清理竞争者（同 /dev 或同 label 的只读挂载）→ sleep 3 等 FSKit 释放 → 确保 /dev/diskXsY 存在 → `sudo mkdir -p /Volumes/<label>` → 执行：
  ```
  sudo /usr/local/bin/ntfs-3g /dev/diskXsY /Volumes/<label> -o "recover,remove_hiberfile,auto_xattr,allow_other,big_writes,noatime,uid=$UID,gid=$GID,local,volname=<label>"
  ```
  → 再清一次竞争者 → `sudo mdutil -i off <mp>` + `.fseventsd/no_log`（防 Spotlight 锁文件）。
- `unmount <disk|label|all>`：diskutil unmount，失败 sudo umount。
- `eject <disk|label|all>`：① `sudo touch $MARKER_DIR/ejecting.<id>`（TTL 60s，防 daemon 重挂）② 按 label 精确解挂 `fuse-t:/<label>`（防多盘互杀）③ pgrep ntfs-3g PID，先 SIGTERM（让 NFS 正常注销），1s 后仍存活才 KILL（**严禁上来 -9**，否则 macOS 直接弹 USB）④ rmdir 空挂载点 ⑤ `diskutil eject` 父盘，失败重试清理。
- owner 解析（root 挂载避免 uid=0）：`NTFS_OWNER_USER` env → `stat -f '%Su' /dev/console` → `id -un` → dscl 找 uid>=501；为 0 则拒绝挂载。
- `NTFS_MOUNT_DEBUG=1` 输出 [trace]。

### ntfs-automount.sh + plist（daemon root）
- plist：RunAtLoad+KeepAlive，日志 /var/log/ntfsformac-automount.log，env 注入 NTFS_OWNER_USER 和 PATH。
- 每 3s `ntfsctl list --porcelain`；HANDLED 用空格包裹字符串模拟集合；尊重 eject marker；状态机：RW → 只查该盘是否又冒出 `fskit|read-only` 寄生虫，有则清；RO/空 → debounce 2s 后挂载。

### NTFSMounter.swift
- `NSStatusBar` + `LSUIElement=true`；`Process` 跑 `ntfsctl list --porcelain` 3s 定时刷新 + NSWorkspace didMount/didUnmount 即时刷新。
- 每个盘子菜单：挂载为读写/卸载/安全弹出/在 Finder 打开（已挂载才显示）；底部：重新扫描/驱动状态/退出。中文 UI。
- 特权操作：`NSAppleScript "do shell script \"ntfsctl eject diskXsY\" with administrator privileges"`；错误弹中文 NSAlert（含 FDA 指引）。
- 驱动缺失时菜单显示"未检测到驱动，点击安装"。

### build-app.sh + make-icon.swift
- VERSION 读版本 → `pkill -f NTFSMounter`（失败 -9）→ `rm -rf /Applications/NTFSMounter.app` → `swiftc -O -framework Cocoa -o build/... NTFSMounter.swift` → 组装 .app（Info.plist：CFBundleShortVersionString=$VERSION、LSUIElement）→ make-icon.swift + `iconutil -c icns` → `cp -R` 到 /Applications → `open` 前台运行 → 构建后 VERSION +0.0.1（满十进一）。
- 内置验证：编译成功 + .app 结构完整 + `pgrep -f NTFSMounter`。

### test/test-ntfs-rw.sh
1. `hdiutil create -size 512m -fs none` + attach → /dev/diskN。
2. `sudo mkntfs -f /dev/diskN`（顺带观察 Tahoe FSKit 只读自动挂载）。
3. `ntfsctl list --porcelain` 断言该盘出现且 state 为 RO 或空。
4. `ntfsctl mount diskN` → 断言 `/sbin/mount` 出现 `fuse-t:/label` 且**无 read-only 行**（验证 FSKit 寄生虫被清）。
5. `echo hello > /Volumes/<label>/rw-test.txt && diff` 校验；`mdutil -s` 断言 disabled。
6. `ntfsctl eject diskN` → 断言无挂载、无 ntfs-3g 进程 → `hdiutil detach`。
7. 清理镜像。任何断言失败 exit 1。

## 里程碑顺序（每步验证后再进下一步）
1. **M1 驱动安装**：install-driver.sh → 三验证。
2. **M2 底层验证**：mkntfs 格式镜像 → ntfs-3g 手动挂 → 写读校验 → umount（不依赖 ntfsctl，先证底层可用）。
3. **M3 ntfsctl**：list→mount→unmount→eject 逐命令实现测试；验证 FSKit 只读挂载被清。
4. **M4 LaunchDaemon**：plist+轮询 → bootstrap → attach 镜像 → 断言自动 RW 挂载；eject marker 生效。
5. **M5 菜单栏 App**：NTFSMounter.swift + build-app.sh → 版本 0.0.1 → 装 /Applications 前台运行 → 逐按钮验证。
6. **M6 全量测试**：test-ntfs-rw.sh 全流程 + 边界（两盘并存、无盘状态）。
7. **M7 文档 + git**：README.md、docs/*.md → git init + .gitignore → 中文 commit → `gh repo create ntfsformac --public --source . --push`。

## 验证方式（端到端）
- 驱动层：`otool -L /usr/local/bin/ntfs-3g` 含 libfuse-t。
- CLI/daemon：镜像盘 attach 后自动出现 RW 挂载、写入/读出一致、eject 后无残留进程。
- App：菜单栏可见、各按钮可用、osascript 提权弹窗正常。
- 全流程：`bash test/test-ntfs-rw.sh` 通过。

## 风险与回退
| 风险 | 处理 |
|---|---|
| autogen.sh autoreconf/ltmain.sh 错误 | `autoreconf -fi` 重跑；仍失败改从 tuxera 官方 tarball + 手动 patch |
| FDA 拦截（Operation not permitted） | 打印指引：系统设置→完全磁盘访问→添加 ntfs-3g、/bin/bash；写入 docs |
| NFS 卷读不了（Operation not permitted） | FUSE-T 已知坑：文件与文件夹→启用"网络宗卷" |
| Tahoe FSKit 反复挂只读 | 挂前/挂后/daemon 每轮三处清理 |
| 构建链到 macFUSE | otool -L 断言 libfuse-t |
