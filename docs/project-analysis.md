# NTFSFormac 项目详细分析

> 版本：0.0.4 ｜ 最后更新：2026-09-29
> 本文是项目的完整技术分析：解决的问题、架构、模块、关键设计、测试体系与已知限制。

---

## 1. 项目定位

**NTFSFormac** 是一个 macOS 26 (Tahoe) / Apple Silicon 上的开源 NTFS 读写工具，由三部分组成：

- **NTFSMounter.app** —— Swift 菜单栏 App（用户操作入口）
- **ntfsctl** —— bash CLI（挂载/卸载/弹出控制核心）
- **LaunchDaemon** —— root 轮询守护（自动挂载 + FSKit 寄生虫清理）

底层依赖 **FUSE-T**（无内核扩展的 FUSE 实现）+ **ntfs-3g**（macos-fuse-t 分支，GPL-2.0）。

### 它解决什么问题

| 现状 | 问题 |
|---|---|
| macOS 13 起移除系统内置 NTFS 写入支持 | 官方无法读写 NTFS |
| macOS 26 的 FSKit 只把 NTFS 挂成只读 | 读都不完整，且会抢占挂载 |
| 传统 macFUSE 方案 | 需要内核扩展 + 关闭 SIP + 恢复模式，门槛高、有安全风险 |

本项目的路线：**纯用户态**，不用内核扩展、不用进恢复模式、不用关 SIP，插入 NTFS 盘自动挂载为读写。

---

## 2. 技术选型与原理

### 2.1 FUSE-T 为什么可行

FUSE-T（macos-fuse-t 项目）是一个**无内核扩展**的 FUSE 实现：

- 传统 FUSE（macFUSE）通过 kext 在内核里提供 `mount` 系统调用钩子；
- FUSE-T 改走 **NFS v4 本地服务器**：挂载点实际是一个回环 NFS 挂载，用户态文件系统通过 NFS 协议对外服务，内核只处理标准 NFS 挂载，**不需要任何内核扩展**。

因此安装 FUSE-T 不需要改 SIP、不需要恢复模式，Apple Silicon 与 macOS 26 均可用。

### 2.2 ntfs-3g 分支选择

主仓库 tuxera/ntfs-3g 面向 Linux FUSE，在 macOS 上默认链到 macFUSE（依赖内核扩展）。本项目使用 **macos-fuse-t/ntfs-3g** 分支，它：

- 编译时 `--with-fuse=external` + `-lfuse-t`，链接 FUSE-T 的 `libfuse-t.dylib`；
- 提供完整 ntfsprogs 工具集（`mkntfs`、`ntfsfix`、`ntfslabel` 等）。

### 2.3 macOS 26 的 FSKit 只读抢占问题

Tahoe 上插入 NTFS 盘时，苹果的 FSKit 驱动会把盘挂成只读（`/dev/diskXsY on /Volumes/X (read-only, fskit)`），并持续尝试重新抢占。这导致：

1. 直接挂 FUSE-T 会与 FSKit 挂载叠加在同一挂载点；
2. 只读挂载会一直存在，掩盖读写挂载。

应对策略（贯穿整个项目）：
- 挂载前**清掉同设备全部竞争者**（包括只读寄生虫与旧 FUSE-T 挂载）；
- 挂载后再清一次（跳过刚挂载的目标挂载点，避免误卸自己）；
- 守护进程每 3 秒巡检，发现新的只读寄生虫立即重新挂载读写。

---

## 3. 系统架构

```
┌──────────────────────────────────────────────────────────────┐
│ NTFSMounter.app（Swift 菜单栏 App，LSUIElement，用户态）        │
│   · 3 秒轮询 ntfsctl list --porcelain 刷新状态                 │
│   · 每盘子菜单：挂载读写 / 卸载 / 安全弹出 / Finder 打开        │
│   · 特权操作 = sudo -n（免密，无授权框）                        │
└──────────────────────────┬───────────────────────────────────┘
                           │ /usr/local/bin/ntfsctl
┌──────────────────────────▼───────────────────────────────────┐
│ ntfsctl（bash CLI，root 或 sudo 运行）                         │
│   list | mount | unmount | eject | auto                       │
│   · FSKit 只读寄生虫清理 · 僵尸 ntfs-3g 清理 · eject marker    │
│   · 挂载互斥锁（防守护进程与手动并发叠加挂载）                  │
└──────────────────────────┬───────────────────────────────────┘
                           │ ntfs-3g -o recover,uid=...,gid=...
┌──────────────────────────▼───────────────────────────────────┐
│ /usr/local/bin/ntfs-3g（macos-fuse-t 分支）                   │
│   · 链 libfuse-t.dylib（FUSE-T 运行时）                        │
│   · 挂载点 = NFS 回环挂载（/Volumes/<卷标>）                   │
└──────────────────────────┬───────────────────────────────────┘
                           │ 轮询 3s / 巡检寄生虫
┌──────────────────────────▼───────────────────────────────────┐
│ LaunchDaemon com.x.ntfsformac.automount（root）               │
│   /usr/local/sbin/ntfs-automount.sh                           │
│   · 新盘自动挂载读写 · 只读寄生虫重挂 · eject marker 尊重      │
└──────────────────────────────────────────────────────────────┘
```

### 数据流（以插入 U 盘为例）

```
插入 NTFS U 盘
  → diskutil 注册 /dev/diskXsY
  → FSKit 抢先挂成只读 /Volumes/<label>（read-only, fskit）
  → 守护进程轮询 ntfsctl list → state=ro/none
  → ntfsctl mount diskXsY：
      1. 加挂载互斥锁（mkdir /var/run/ntfsformac/mount.lock）
      2. 清理同设备全部只读/旧挂载
      3. ntfs-3g 挂载到 /Volumes/<label>（读写，属主=GUI 用户）
      4. 再清一次寄生虫（跳过自己）
      5. mdutil -i off + .fseventsd/no_log 防索引锁文件
  → 菜单栏 App 3 秒内显示 ● RW
```

---

## 4. 模块详解

### 4.1 scripts/ntfsctl（核心 CLI，~340 行 bash 3.2）

**命令**：`list [--porcelain]`、`mount <disk|label|all>`、`unmount <disk|label|all>`、`eject <disk|label|all>`、`auto`。

关键实现点：

| 模块 | 说明 |
|---|---|
| `ntfs_devices()` | 解析 `diskutil list`：兼容 `Windows_NTFS` 与 `Microsoft Basic Data`（GPT）两种分区类型行，卷标含空格也能提取完整 label |
| `mount_line()` / `mp_of_line()` | 在 `/sbin/mount` 输出中定位挂载；**用 `grep -F` 全行匹配**而非 awk 字段匹配——卷标含空格时按字段匹配必然失效（历史 bug #13） |
| `mount_state()` | 由挂载行判断 rw / ro / none（含 `read-only` 或 `fskit` 关键字判定） |
| `resolve_devices()` | 支持 `/dev/diskXsY`、`diskXsY`、卷标、`all` 四种目标；按 label 匹配时走 `ntfs_devices` |
| `lock_mount()` / `unlock_mount()` | **mkdir 原子锁**（30s TTL，崩溃残留自动接管），串行化守护进程与手动挂载，防同一盘叠加两份挂载（bug #16 修复） |
| `mount_one()` | 完整挂载流程：label 兜底（NO NAME 重试 5 次、含斜杠兜底）→ 加锁 → 幂等检查 → 清竞争者 → 等设备 → 挂载 → 再清 → 关 Spotlight |
| `unmount_competitors()` | 两级清理：按 `/dev/<dev>`（FSKit 只读寄生虫，含目标挂载点上的）+ 按 `fuse-t:/<label>`（旧 FUSE-T，`skip_target=1` 时跳过刚挂载的目标点） |
| `unmount_one()` | 卸载不弹出；**写 eject marker**（60s TTL），让守护进程尊重手动卸载意图（bug #14 修复） |
| `eject_one()` | 安全弹出五步：写 marker → 按 label 精确解挂 FUSE-T → SIGTERM→SIGKILL 停 ntfs-3g → 清空挂载点 → `diskutil eject` 父盘（失败重试一次） |
| `resolve_owner()` | root 场景下避免 uid=0：取 `/dev/console` 属主 → 兜底取 UID≥501 的第一个用户，支持 `NTFS_OWNER_USER` 环境变量覆盖 |

### 4.2 scripts/ntfs-automount.sh（守护进程，~55 行）

由 launchd 启动、root 运行，无限循环：

- 每 3 秒：过期 eject marker 清理 → `ntfsctl list --porcelain` 逐盘巡检；
- `state=ro|none` → 自动 `ntfsctl mount`；
- `state=rw` 但又有只读寄生虫 → 重新挂载读写；
- 日志写 `/var/log/ntfsformac-automount.log`。

### 4.3 scripts/com.x.ntfsformac.automount.plist

LaunchDaemon 配置：`RunAtLoad + KeepAlive`（崩溃自动拉起）、注入 `NTFS_OWNER_USER`（sed 占位符替换）、PATH 覆盖、stdout/stderr 合并到日志。

### 4.4 scripts/install-service.sh

安装三件事：
1. `ntfsctl` → `/usr/local/bin/ntfsctl`
2. `ntfs-automount.sh` → `/usr/local/sbin/`
3. plist（替换 owner 占位符）→ `/Library/LaunchDaemons/` + `launchctl bootout/bootstrap` 重载

### 4.5 NTFSMounter.swift（菜单栏 App，~240 行）

- `@main @MainActor AppDelegate`，`LSUIElement` 纯菜单栏（无 Dock 图标）；
- `Timer 3s` + `NSWorkspace didMount/didUnmount` 通知双路刷新；
- 解析 `ntfsctl list --porcelain`（`device|label|ntfs|mountpoint|state`）；
- 每盘子菜单：挂载为读写 / Finder 打开 / 卸载 / 安全弹出；
- 附加菜单：驱动状态、重新扫描(⌘R)、打开日志、退出(⌘Q)；
- **特权执行 `runAdmin()` 走 `sudo -n`**（配合 /etc/sudoers.d 免密），彻底消灭 osascript 授权框（用户强需求）；
- 状态图标：● RW / ○ RO / ○ 未挂载。

### 4.6 build-app.sh（构建打包，~90 行）

流程：结束旧进程(含强杀) → 删旧 .app → `swiftc -parse-as-library` 编译 → `make-icon.swift` 生成图标 → sips 多尺寸 → iconutil 打包 icns → 组装 .app + Info.plist（`LSUIElement`）→ codesign ad-hoc → sudo 装到 /Applications → 装服务 → `open` 前台运行 → 验证进程存活 → **版本号 +0.0.1（满十进一）** 写回 VERSION。

### 4.7 install-driver.sh（驱动安装）

幂等脚本：FUSE-T 检测与 cask 安装 → 构建依赖检查 → 克隆 macos-fuse-t/ntfs-3g → 构建（autogen 失败走 glibtoolize + autoreconf 兜底，configure 用 `--with-fuse=external` 链 libfuse-t）→ `make install` → 卸载 gromgit 的 ntfs-3g-mac 冲突公式 → 三验证（version / otool 链 libfuse-t / mkntfs）。

### 4.8 make-icon.swift

纯 AppKit 程序化生成 1024×1024 图标（蓝渐变圆角底 + 硬盘条 + NTFS 字样），无外部素材。

---

## 5. 关键设计决策

| 决策 | 理由 |
|---|---|
| 不用 macFUSE | 需内核扩展/SIP/恢复模式，Apple Silicon 与 macOS 26 兼容性差 |
| 用 FUSE-T + NFS 回环 | 纯用户态，安装即用；代价是底层走 NFS 协议，**App 需"网络宗卷"权限**才能读卷内容 |
| 守护进程 root 轮询 3s | Tahoe FSKit 会反复抢挂，事件驱动不够，必须主动巡检 |
| eject marker 机制 | 区分"系统插盘"与"用户手动弹出"，手动弹出后 60s 不重挂 |
| mkdir 互斥锁 | 守护进程与手动操作并发时防止同一盘叠加两份挂载（双写损坏风险） |
| grep -F 全行匹配 | 卷标含中文/空格时 awk 字段匹配必然失效（第 13 号坑的根因） |
| sudo 免密替代 osascript | 用户要求彻底消灭授权框；App 与脚本统一走 `sudo -n` |
| GPTSPUD 镜像测试 | MBR 布局下 mkntfs 不改分区类型字节，diskutil 认不出 NTFS（第 17 号坑） |

---

## 6. 测试体系（test/）

| 脚本 | 覆盖 |
|---|---|
| `test-ntfs-rw.sh` | 端到端：建镜像 → mkntfs → 拔出重插 → list 检测 → 挂载读写 → 写读校验 → 无寄生虫 → 弹出 → 无残留进程（14 项） |
| `test-boundary.sh` | 边界：中文+空格卷标（"我的 移动盘"）全流程 + unmount/remount |
| `test-automount.sh` | 守护进程：自动挂载、eject marker 尊重、寄生虫重挂 |
| `final-check.sh` | 安装后快速检查（驱动/服务/App 状态） |
| `ntfs-ctl-dbg.sh` / `ntfs-space-dbg.sh` | 调试辅助 |

核心技巧：**用 hdiutil 磁盘镜像模拟真实 NTFS 移动盘**——attach 后是真实 `/dev/diskX` 块设备，能完整复现 FSKit 只读自动挂载行为，无需真盘、可无限重复。

---

## 7. 版本管理

- 版本号存 `VERSION` 文件（当前 0.0.4）；
- `build-app.sh` 每次构建后自动 +0.0.1，满十进一（`awk` 数值进位算法）；
- 版本写入 Info.plist（`CFBundleShortVersionString`），菜单栏头部显示。

---

## 8. 已知问题与限制（详见 docs/known-issues.md 共 21 条）

1. **必须先安全弹出再拔盘**：FUSE-T 有写缓存，直接拔损坏 NTFS 日志。
2. **Windows 快速启动后的首次写入**可能提示检查磁盘——NTFS 日志标志翻转，点跳过即可。
3. **macOS 无完整 NTFS 修复工具**：MFT 损坏需回 Windows 跑 `chkdsk /f`。
4. **"Operation not permitted"**：需给相关 App 开"网络宗卷"权限（FUSE-T 底层 NFS）。
5. **Parallels 引用式 dmg 会锁文件**：同一 dmg 给虚拟机用后 macOS 读不出分区表，需停 VM 删设备解锁（#19-21）。
6. **同一 NTFS 卷不能 macOS/Windows 同时写**：轮流独占。

---

## 9. 安全与权限模型

| 层 | 权限 |
|---|---|
| LaunchDaemon | root（launchd 管理），只能跑 `/usr/local/sbin/ntfs-automount.sh` |
| ntfsctl | root 直接执行 / 普通用户经 sudo；挂载属主解析为 GUI 用户避免 uid=0 |
| 菜单栏 App | `sudo -n` 免密执行（/etc/sudoers.d/ntfsformac 白名单命令）；FDA 需手动授权 ntfs-3g 与 /bin/bash |
| FUSE-T | 挂载点为 NFS，访问需"网络宗卷"授权 |

---

## 10. 后续路线（建议）

- [ ] 打包成安装器（pkg），一键装驱动 + 服务 + App
- [ ] 物理 U 盘长时间读写稳定性压测（当前主要用镜像盘验证）
- [ ] 支持 ntfs-3g 之外的回退驱动（如 Tahoe 原生 FSKit 写支持成熟后）
- [ ] 通知中心弹窗提示挂载/弹出事件
- [ ] 开机自启菜单栏 App（当前 LSUIElement 但未注册登录项）
