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
   BitLocker 加密卷时挂的是解密后的虚拟卷，按内层文件系统分流：
   ├ 内层 NTFS      /dev/diskN ─dislocker-fuse─▶ <容器>/dislocker-file ─ntfs-3g─▶ /Volumes/<卷标>
   └ 内层 exFAT/FAT /dev/diskN ─dislocker-fuse─▶ dislocker-file ─hdiutil 附加─▶ /dev/diskM
                                                                     ─macOS 原生驱动─▶ /Volumes/<卷标>
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
# 1. 安装驱动（FUSE-T + ntfs-3g 源码构建，已免密化，不再弹管理员授权框）
bash install-driver.sh

# 2. 构建并安装菜单栏 App + 自动挂载服务（已免密化）
bash build-app.sh
```

安装完成后按提示做一次手动授权（必须，否则报 Operation not permitted）：
**系统设置 → 隐私与安全性 → 完全磁盘访问** → 添加 `ntfs-3g` 和 `/bin/bash`（路径分别为 `/usr/local/bin/ntfs-3g`、`/bin/bash`）。

## 使用

- 插入 NTFS 盘后 5~10 秒自动挂载为读写，出现在 `/Volumes/<卷标>`，菜单栏图标显示状态。
- 菜单栏点开：每个盘可「挂载为读写 / 卸载 / 安全弹出 / 在 Finder 中打开」。
- **BitLocker 加密盘**：自动挂载只标记 🔒「加密未解锁」并跳过（**绝不猜密码**）。菜单栏点开有**三种解锁入口**：
  「用密码解锁…」「用恢复密码解锁…」（48 位数字，连字符可省略）「用 .BEK 文件解锁…」（Windows 导出的恢复密钥文件）。
  勾选「记住」会把凭据存入钥匙串（**按 BitLocker 卷 GUID 做键**，跨插拔稳定），下次插入自动解锁。
  也有「锁定 BitLocker（锁定后不再自动解锁）」「忘记已保存的密码」。App 运行日志见 `~/Library/Logs/NTFSFormac/app.log`。
- 报错/提示窗口**不置顶、不抢焦点**，正文可拖选 + ⌘C，另有「复制全部」按钮（整段报错一键入剪贴板）。

- 命令行（可选）：

```bash
ntfsctl list --porcelain   # device|label|<ntfs|bitlocker>|mountpoint|<rw|ro|none|locked>|guid
ntfsctl mount disk4s1      # 挂载读写（按设备或卷标或 all）
ntfsctl eject disk4s1      # 安全弹出
ntfsctl unlock disk4s1 --password-file /path/pw   # 用用户密码解锁 BitLocker 并挂载读写
ntfsctl unlock disk4s1 --recovery 123456-123456-123456-123456-123456-123456-123456-123456
ntfsctl unlock disk4s1 --bek /path/XXXXXXXX.BEK   # 用 BEK 恢复密钥文件解锁
ntfsctl unlock disk4s1 --password 密码 --verbose  # 解锁失败时输出 dislocker 调试日志
ntfsctl lock disk4s1       # 锁定 BitLocker（卸载 + 停止解密，且不会再被 App 自动解锁）
                           #   （标记 /var/run/ntfsformac/locked.<dev>；unlock/eject/拔盘后自动清除）
ntfsctl info -v disk4s1    # 读 BitLocker 元数据（无需凭据，诊断用）
ntfsctl dump disk4s1       # 导出卷头与元数据副本原始字节（离线排错用）
```

## ⚠ 注意事项

- **永远先「安全弹出」再拔盘**：FUSE-T 有写缓存，直接拔会损坏 NTFS 日志。
- Windows 快速启动后首次写入，可能弹「需要检查磁盘」——是 NTFS 日志标志翻转，点跳过即可。
- macOS 没有完整 NTFS 修复工具；`ntfsfix` 只能回放日志。出现目录删不掉等 MFT 损坏，请接回 Windows 跑 `chkdsk /f`。
- 遇到「Operation not permitted」读不到卷内容：系统设置 → 隐私与安全性 → 文件与文件夹 → 给相关 App 打开「网络宗卷」权限（FUSE-T 底层是 NFS）。

## 当前开发进度

NTFS 与 **BitLocker** 核心功能已全部完成并验证：驱动安装（含 dislocker）、ntfsctl CLI、自动挂载守护进程、
菜单栏 App（v0.0.17）、BitLocker 三种凭据（用户密码 / 恢复密码 / .BEK 文件）解锁 + 读写 + 锁定 + 钥匙串自动解锁。

v0.0.10 修复了真实 U 盘上的 dislocker 解析缺陷（**未知 value_type 的 datum 会中断整个元数据遍历**，
导致其后的 FVEK 与 VIRTUALIZATION_INFO 读不到、解锁报 `Unable to compute regions`），
并新增诊断三件套 `ntfsctl info -v` / `ntfsctl dump` / `unlock --verbose`。

v0.0.11 支持 **BitLocker 内层是 exFAT/FAT** 的情形（BitLocker To Go 可移动盘很常见）：
macOS 自带读写驱动只认块设备，故把解密文件用 `hdiutil` 附加成块设备后再交原生驱动挂载。
**真实 U 盘（Ventoy15.1, exFAT）已端到端跑通**：解锁 → 挂载读写 → 8MB 写入并 SHA-256 校验一致 →
卸载/重挂（不重复附加）→ 重新锁定无残留 → 再解锁数据仍在 → 安全弹出。

v0.0.12 修复**「记住密码」完全失效**（三个叠加根因：`security` 会把含换行的值存成十六进制文本、
钥匙串用会变的设备名做键、`autoTried` 标记时机错误），改用**卷 GUID**做键；
并新增加密盘/杂项分区的**挂载前 NTFS 签名预检**，消除守护日志被非 NTFS 分区 `ntfs-3g` 失败刷屏。
v0.0.13 补上验证中发现的 `lock` 未持互斥锁缺口（避免「解锁报成功、随即回退 locked」的假成功）。

v0.0.14 解决用户反馈的三件事：
① 报错弹窗从 `NSAlert + runModal()` 改为自定义 `NSPanel` —— **不置顶、不抢焦点、不阻塞 App**，
   正文改用可拖选的 `NSTextView` 并新增「复制全部」按钮；
② `eject_one` 纳入 `lock_mount` 互斥锁（`mount/unmount/lock/unlock/eject` 五者彻底串行化）；
③ 新增**手动锁定标记** `locked.<dev>`，命令行 `ntfsctl lock` 不再被 App 在 3 秒内自动解开
   （标记在 unlock/eject/拔盘后自动清除，含「标记先落再卸载」的竞态修正）。
另**顺带修复守护进程 porcelain 解析**：v0.0.12 给 porcelain 加第 6 字段 `guid` 后，守护脚本仍按 5 字段 `read`，
导致 **BitLocker 行**（guid 非空）的 `state` 被污染成 `rw|<guid>`、分支失配（已改为 6 字段 + `_rest` 兜底）；
NTFS 行因 bash 会剥掉行尾空字段而不受影响（详见 known-issues #40/#44 —— 初版结论曾因用 zsh 复现而出错）。

v0.0.15 解决两件事：
① **其它分区检测 + 只读浏览**：外置盘上非 NTFS/BitLocker 的 FAT 家族分区（如 Ventoy 的 VTOYEFI，
   分区类型 0xEF 被 macOS 拒绝识别）现在能被 `list` 列出，`ntfsctl mount <dev>` 走「dd 导出 →
   免分区表镜像附加」只读浏览（写入不会回写原分区），`unmount`/`eject` 全闭环清理；
   **绝不改分区表类型**（改 0xEF 会让 Ventoy 无法 UEFI 启动）。
② **根除 Touch ID 指纹弹窗**：ntfsctl 的 `as_root` 从交互式 sudo 改为非交互（`sudo -n`，
   免密不可用直接失败），并新增「裸跑免密重入」——终端直接跑 `ntfsctl ...` 自动经白名单提权，
   实测 list/mount/unmount 全链路零弹窗。

v0.0.16 **根治「多分区有的找不出来、找出来了不能用」**，并**免密化驱动安装**：
① 两个隐蔽根因（详见 [known-issues.md](docs/known-issues.md) #45/#46）：
   - 卷**已挂载**时读 `/dev/diskXsY`（缓冲设备）会 `Resource busy` → 0 字节，导致真 NTFS 盘被误判 unreadable；
     → 所有内容读取/整分区导出改走 `/dev/rdiskXsY`（裸设备，新增 `dev_io()`）。
   - 裸设备**只接受扇区对齐读** → exFAT 卷标（非对齐偏移）读不出；新增 `dev_read_bytes()`（扇区对齐 dd + 切片）。
② **分区类型与内容解耦**：分区类型同为 `Microsoft Basic Data`，内容却可能是 exFAT/FAT32；
   一律按首扇区内容归并，FAT 家族自动走只读裸镜像路径，未知内容明确提示用 `ntfsctl probe` 查看。
③ **`MSWIN4.1` 消歧**：FAT 家族与 BitLocker-To-Go 共用该 OEM 名；用 FAT 类型串 + `dislocker-metadata` 二次判定，
   FAT32 不再被误判成加密盘。
④ 新增 exFAT 卷标解析（读根目录 0x83 卷标条目）、`prune_raw_images()` 失效镜像记录清理。
⑤ **install-driver.sh 免密化**：原先两处 `osascript ... with administrator privileges` 管理员授权框
   改为「特权子命令 + `sudo -n` 免密重入」，实测以普通用户运行零弹窗（详见 `scripts/install-service.sh` 白名单）。

详情见 [docs/20261015-2108-多分区找不到不能用根治与驱动免密-DeepSeek-V4.1-Flash.md](docs/20261015-2108-多分区找不到不能用根治与驱动免密-DeepSeek-V4.1-Flash.md)。

v0.0.17 补齐真盘复验中发现的一处非致命残留：`/var/run/ntfsformac/bl/` 与 `bl-image/`
（BitLocker 容器目录 + 镜像记录）在设备消失后不自动清理，盘号漂移会累积空目录/旧记录。
新增 `prune_bl_dirs()` 挂在 `list` 心跳点，按「原设备节点是否还存在」清理，保守起见容器仍处于
挂载态时不硬拆。真实场景已验证：上一轮残留 `disk25s1` 被自动清掉，在用的 `disk4s1` 完整保留。

## 下一步待实现

大分区镜像挂载的体积/耗时提示、ext4 浏览、ErrorPanel 保存到文件等。

详情见 [docs/20261015-0745-下一步待实现-DeepSeek-V4.1-Flash.md](docs/20261015-0745-下一步待实现-DeepSeek-V4.1-Flash.md)。

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
| [20261014-2235-未知datum解析修复-DeepSeek-V4.1-Flash.md](docs/20261014-2235-未知datum解析修复-DeepSeek-V4.1-Flash.md) | 真实 U 盘解锁失败根因：未知 datum 中断遍历（含诊断三件套） |
| [20261014-2310-BitLocker内层exFAT挂载-DeepSeek-V4.1-Flash.md](docs/20261014-2310-BitLocker内层exFAT挂载-DeepSeek-V4.1-Flash.md) | BitLocker 内层 exFAT：hdiutil 原始镜像附加 + macOS 原生驱动挂载（真实 U 盘端到端） |
| [20261014-2351-记住密码修复与挂载签名预检-DeepSeek-V4.1-Flash.md](docs/20261014-2351-记住密码修复与挂载签名预检-DeepSeek-V4.1-Flash.md) | 「记住密码」失效三根因（security hex 化 / 设备名做键 / autoTried 时机）+ 卷 GUID 键 + 挂载前签名预检 + lock 互斥锁缺口 |
| [20261015-0045-报错弹窗重构与手动锁定标记-DeepSeek-V4.1-Flash.md](docs/20261015-0045-报错弹窗重构与手动锁定标记-DeepSeek-V4.1-Flash.md) | 报错弹窗改可复制非阻塞 NSPanel + eject 互斥锁 + 手动锁定标记（含竞态修正）+ porcelain 6 字段回归 |
| [20261014-2145-恢复密码与BEK解锁入口-DeepSeek-V4.1-Flash.md](docs/20261014-2145-恢复密码与BEK解锁入口-DeepSeek-V4.1-Flash.md) | 恢复密码 / .BEK 文件解锁入口（含 dislocker 55 字符铁律） |
| [20261015-0745-其它分区检测与只读镜像挂载-DeepSeek-V4.1-Flash.md](docs/20261015-0745-其它分区检测与只读镜像挂载-DeepSeek-V4.1-Flash.md) | 其它分区（VTOYEFI 等）检测与只读裸镜像挂载 + 根除 Touch ID 指纹弹窗（免密重入） |
| [20261015-2108-多分区找不到不能用根治与驱动免密-DeepSeek-V4.1-Flash.md](docs/20261015-2108-多分区找不到不能用根治与驱动免密-DeepSeek-V4.1-Flash.md) | 多分区「找不到/不能用」根治（裸设备读取 + 分区类型与内容解耦 + MSWIN4.1 消歧 + exFAT 卷标）+ 驱动安装免密化 |
| [20261015-0745-当前开发进度-DeepSeek-V4.1-Flash.md](docs/20261015-0745-当前开发进度-DeepSeek-V4.1-Flash.md) | 最新里程碑完成情况与功能清单 |
| [20261015-0745-下一步待实现-DeepSeek-V4.1-Flash.md](docs/20261015-0745-下一步待实现-DeepSeek-V4.1-Flash.md) | 后续开发计划 |
| [20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md](docs/20261014-2116-当前开发进度-DeepSeek-V4.1-Flash.md) | 历史里程碑（v0.0.12 阶段） |
| [20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md](docs/20261014-2116-下一步待实现-DeepSeek-V4.1-Flash.md) | 历史计划（P0/P1/P2 分级） |

## 许可

本项目 MIT。ntfs-3g 来自 [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g)（GPL-2.0 + LGPL-2.0）；FUSE-T 见 [macos-fuse-t/fuse-t](https://github.com/macos-fuse-t/fuse-t)。实现思路参考了 [ArrivaRUS/ntfs-mounter-macos](https://github.com/ArrivaRUS/ntfs-mounter-macos)（MIT）。
