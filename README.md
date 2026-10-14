# NTFSFormac

macOS 26 (Tahoe) / Apple Silicon 上的开源 NTFS 读写工具 —— 菜单栏 App + 自动挂载/卸载。

底层使用 **FUSE-T**（无内核扩展，纯用户态 NFS 实现）+ **ntfs-3g**（macos-fuse-t 分支，GPL-2.0）。

## 为什么

macOS 13 起移除了系统内置 NTFS 写入支持；macOS 26 上苹果的 FSKit 只会把 NTFS 挂成只读，还会抢占挂载。传统方案（macFUSE）需要内核扩展 + 降低安全设置，本工具走 FUSE-T 路线：**不用装内核扩展、不用进恢复模式、不用关 SIP**。

## 组成

```
┌────────────────────────────────────────────┐
│ NTFSMounter.app（Swift 菜单栏 App，用户态） │
│  显示 NTFS 盘 + RW/RO 状态                 │
│  挂载为读写 / 卸载 / 安全弹出 / 在 Finder 打开│
│  特权操作 = sudo 免密（ntfsctl，无授权框）  │
└───────────────┬────────────────────────────┘
                │ ntfsctl list --porcelain
┌───────────────┴────────────────────────────┐
│ /usr/local/bin/ntfsctl（bash CLI，root/用户）│
│  list/mount/unmount/eject/auto             │
│  FSKit 只读寄生虫清理 / 僵尸进程清理         │
└───────────────┬────────────────────────────┘
                │ 挂载参数
┌───────────────┴────────────────────────────┐
│ /usr/local/bin/ntfs-3g（macos-fuse-t 分支） │
│  ← 链接 libfuse-t（FUSE-T 运行时）          │
└───────────────┬────────────────────────────┘
   BitLocker 加密卷时 ntfs-3g 挂的是解密后的虚拟卷：
   /dev/diskN ──dislocker-fuse──▶ <容器>/dislocker-file ──ntfs-3g──▶ /Volumes/<卷标>
┌────────────────────────────────────────────┐
│ /usr/local/bin/dislocker-fuse（v0.7.3）     │
│  解锁 BitLocker：用户密码/恢复密码/BEK       │
└────────────────────────────────────────────┘
┌────────────────────────────────────────────┐
│ LaunchDaemon com.x.ntfsformac.automount    │
│  root 轮询 3s：新 NTFS 盘自动挂载读写，     │
│  持续清除 Tahoe FSKit 的只读寄生虫挂载      │
└────────────────────────────────────────────┘
```

## 安装

```bash
# 1. 安装驱动（FUSE-T + ntfs-3g 源码构建，需要一次管理员密码）
bash install-driver.sh

# 2. 构建并安装菜单栏 App + 自动挂载服务（需要一次管理员密码）
bash build-app.sh
```

安装完成后按提示做一次手动授权（必须，否则报 Operation not permitted）：
**系统设置 → 隐私与安全性 → 完全磁盘访问** → 添加 `ntfs-3g` 和 `/bin/bash`（路径分别为 `/usr/local/bin/ntfs-3g`、`/bin/bash`）。

## 使用

- 插入 NTFS 盘后 5~10 秒自动挂载为读写，出现在 `/Volumes/<卷标>`，菜单栏图标显示状态。
- 菜单栏点开：每个盘可「挂载为读写 / 卸载 / 安全弹出 / 在 Finder 中打开」。
- **BitLocker 加密盘**：自动挂载只标记 🔒「加密未解锁」并跳过（**绝不猜密码**）。菜单栏点开有**三种解锁入口**：
  「用密码解锁…」「用恢复密码解锁…」（48 位数字，连字符可省略）「用 .BEK 文件解锁…」（Windows 导出的恢复密钥文件）。
  勾选「记住」会把凭据存入钥匙串，下次插入自动解锁。也有「重新锁定」「忘记已保存的密码」。
- 命令行（可选）：

```bash
ntfsctl list --porcelain   # device|label|<ntfs|bitlocker>|mountpoint|<rw|ro|none|locked>
ntfsctl mount disk4s1      # 挂载读写（按设备或卷标或 all）
ntfsctl eject disk4s1      # 安全弹出
ntfsctl unlock disk4s1 --password-file /path/pw   # 用用户密码解锁 BitLocker 并挂载读写
ntfsctl unlock disk4s1 --recovery 123456-123456-123456-123456-123456-123456-123456-123456
ntfsctl unlock disk4s1 --bek /path/XXXXXXXX.BEK   # 用 BEK 恢复密钥文件解锁
ntfsctl lock disk4s1       # 重新锁定 BitLocker（卸载 + 停止解密）
```

## ⚠ 注意事项

- **永远先「安全弹出」再拔盘**：FUSE-T 有写缓存，直接拔会损坏 NTFS 日志。
- Windows 快速启动后首次写入，可能弹「需要检查磁盘」——是 NTFS 日志标志翻转，点跳过即可。
- macOS 没有完整 NTFS 修复工具；`ntfsfix` 只能回放日志。出现目录删不掉等 MFT 损坏，请接回 Windows 跑 `chkdsk /f`。
- 遇到「Operation not permitted」读不到卷内容：系统设置 → 隐私与安全性 → 文件与文件夹 → 给相关 App 打开「网络宗卷」权限（FUSE-T 底层是 NFS）。

## 当前开发进度

NTFS 与 **BitLocker** 核心功能已全部完成并验证：驱动安装（含 dislocker）、ntfsctl CLI、自动挂载守护进程、
菜单栏 App（v0.0.9）、BitLocker 三种凭据（用户密码 / 恢复密码 / .BEK 文件）解锁 + 读写 + 重新锁定 + 钥匙串自动解锁、
全量测试全绿。BitLocker 真实加密镜像盘端到端 29 项全绿。

详情见 [docs/20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md](docs/20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md)。

## 下一步待实现

优先级最高的三件事：物理 BitLocker 盘压测、卸载脚本、pkg 安装器；另有开机自启、事件通知等规划。

详情见 [docs/20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md](docs/20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md)。

## 开发

- 版本号：`VERSION` 文件，`build-app.sh` 每次构建前 +0.0.1（满十进一）。
- 测试（无需真实盘）：`bash test/test-ntfs-rw.sh`（推荐整脚本用管理员方式执行，一次授权跑完）。
- BitLocker 测试（无需真实盘）：`bash test/test-bitlocker.sh`（自检 17 项）；接真实加密盘再加 `--device diskXsY --password '密码'`。

## docs 文档索引

> 完整索引另见根目录 [文档索引.md](文档索引.md)。

| 文档 | 作用 |
|---|---|
| [project-analysis.md](docs/project-analysis.md) | 项目完整技术分析：架构、模块、设计决策、测试体系、限制 |
| [known-issues.md](docs/known-issues.md) | 开发踩坑经验（FSKit 抢占、卷标解析、Parallels 锁文件、FUSE-T 就绪窗口等） |
| [driver-install.md](docs/driver-install.md) | 驱动安装 / 重装 / 卸载手册 |
| [20261014-2116-BitLocker支持-DeepSeek-V4.1-Flash.md](docs/20261014-2116-BitLocker支持-DeepSeek-V4.1-Flash.md) | BitLocker 解锁/读写方案与验证全过程 |
| [20261014-2145-恢复密码与BEK解锁入口-DeepSeek-V4.1-Flash.md](docs/20261014-2145-恢复密码与BEK解锁入口-DeepSeek-V4.1-Flash.md) | 恢复密码 / .BEK 文件解锁入口（含 dislocker 55 字符铁律） |
| [20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md](docs/20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md) | 最新里程碑完成情况与功能清单 |
| [20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md](docs/20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md) | 后续开发计划（P0/P1/P2 分级） |

## 许可

本项目 MIT。ntfs-3g 来自 [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g)（GPL-2.0 + LGPL-2.0）；FUSE-T 见 [macos-fuse-t/fuse-t](https://github.com/macos-fuse-t/fuse-t)。实现思路参考了 [ArrivaRUS/ntfs-mounter-macos](https://github.com/ArrivaRUS/ntfs-mounter-macos)（MIT）。
