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
│  特权操作 = osascript 管理员弹窗            │
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
- 命令行（可选）：

```bash
ntfsctl list --porcelain   # device|label|ntfs|mountpoint|rw|ro|none
ntfsctl mount disk4s1      # 挂载读写（按设备或卷标或 all）
ntfsctl eject disk4s1      # 安全弹出
```

## ⚠ 注意事项

- **永远先「安全弹出」再拔盘**：FUSE-T 有写缓存，直接拔会损坏 NTFS 日志。
- Windows 快速启动后首次写入，可能弹「需要检查磁盘」——是 NTFS 日志标志翻转，点跳过即可。
- macOS 没有完整 NTFS 修复工具；`ntfsfix` 只能回放日志。出现目录删不掉等 MFT 损坏，请接回 Windows 跑 `chkdsk /f`。
- 遇到「Operation not permitted」读不到卷内容：系统设置 → 隐私与安全性 → 文件与文件夹 → 给相关 App 打开「网络宗卷」权限（FUSE-T 底层是 NFS）。

## 开发

- 版本号：`VERSION` 文件，`build-app.sh` 每次构建后 +0.0.1（满十进一）。
- 测试（无需真实盘）：`bash test/test-ntfs-rw.sh`（推荐整脚本用管理员方式执行，一次授权跑完）。
- 更多坑与经验见 [docs/known-issues.md](docs/known-issues.md)。

## 许可

本项目 MIT。ntfs-3g 来自 [macos-fuse-t/ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g)（GPL-2.0 + LGPL-2.0）；FUSE-T 见 [macos-fuse-t/fuse-t](https://github.com/macos-fuse-t/fuse-t)。实现思路参考了 [ArrivaRUS/ntfs-mounter-macos](https://github.com/ArrivaRUS/ntfs-mounter-macos)（MIT）。
