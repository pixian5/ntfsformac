# BitLocker 加密卷内层是 exFAT —— 三种支持与镜像附加挂载

> 版本：0.0.11 ｜ 模型：DeepSeek-V4.1-Flash ｜ 日期：2026-10-14 23:10
> 承接 docs/20261014-2235-未知datum解析修复-DeepSeek-V4.1-Flash.md

## 一、问题

修好「未知 datum 中断遍历」后，用真实密码 `99999999` 解锁用户 U 盘（`/dev/disk4s1`）时，
dislocker **成功解密**（不再有任何元数据/密钥错误），但挂载仍然失败：

```
[ntfsctl] 已解锁: /dev/disk4s1 → /var/run/ntfsformac/bl/disk4s1
[ntfsctl] 错误: ...（ntfs-3g 挂载失败）
```

读解密卷首扇区（`bl_file` 指向的 `dislocker-file`）：

```
首扇区偏移 3 起 8 字节 = "EXFAT   "
```

**结论：该 BitLocker 卷的内层文件系统是 exFAT，不是 NTFS。** 原三层解密链的最后一步是
`dislocker-file --ntfs-3g--> /Volumes/<卷标>`，ntfs-3g 只认 NTFS，自然挂不上。

## 二、为什么不能直接挂

BitLocker 加密的是**卷**（一个块设备），内层文件系统可以是 NTFS、exFAT、FAT 任意一种。
Windows 10+ 对**可移动盘**（BitLocker To Go）默认常用 exFAT，所以真实 U 盘上很常见。

- NTFS：ntfs-3g 是用户态实现（FUSE-T），能直接吃一个**文件**（`dislocker-file`），链路可行。
- exFAT/FAT：macOS **自带读写驱动**（macOS 26 上是 FSKit 实现），但内核/FSKit 驱动只认**块设备**，
  不接受普通文件 → 必须先把 `dislocker-file` 变回一个块设备。

## 三、方案：hdiutil 原始磁盘镜像附加

```
/dev/disk4s1 ──dislocker-fuse──> bl/disk4s1/dislocker-file ──hdiutil attach(CRawDiskImage)──> /dev/diskM
                                                                                          └─diskutil mount──> /Volumes/<卷标>
```

关键命令（`ntfsctl` 内 `bl_attach_inner()`）：

```bash
hdiutil attach -nomount -noverify \
    -imagekey diskimage-class=CRawDiskImage '<容器>/dislocker-file'
diskutil mount /dev/diskM
```

三个要点：

1. **必须 `-imagekey diskimage-class=CRawDiskImage`**：把文件当作「原始裸磁盘镜像」而不是新建
   可读写磁盘映像。不加这个 key 时 hdiutil 可能按 `UDIF`/稀疏映像处理，出现偏移或只读问题。
2. **`-nomount`**：先只附加成设备、不自动挂载，再由我们决定交给哪个驱动挂、挂给谁。
3. **以 GUI 属主身份附加/挂载**（`su -l <owner> -c ...`）：这样 `/Volumes/X` 的属主是登录用户而非
   root，用户能直接读写；失败再回退 root。

## 四、实现改动（scripts/ntfsctl）

| 函数 | 作用 |
|---|---|
| `bl_inner_fs` | **新增**：读解密卷首扇区判内层 FS（`NTFS `→ntfs / `EXFAT `→exfat / 偏移 0x52 的 `FAT32 `/`FAT16 `→fat / other / none） |
| `bl_attach_inner` | **新增**：hdiutil 附加 + diskutil mount + 就绪探测；进入前先 `bl_detach_inner` 清残留 |
| `bl_detach_inner` | **新增**：卸载并 `diskutil eject /dev/diskM`，再清镜像记录 |
| `bl_image_dev` / `bl_outer_mp` | **新增**：记录（`/var/run/ntfsformac/bl-image/<dev>`）/读取镜像设备号与其挂载点 |
| `mount_line` | **改**：按 `fuse-t:/<label>` 找不到时（exFAT 无 fuse-t 挂载），再按「镜像设备 /dev/diskM on」查 |
| `mount_state` | **改**：`fskit` 标记不再一律视为只读（详见下节） |
| `mount_one` | **改**：BitLocker 分支先判内层 FS，exFAT/FAT 走镜像附加路径，NTFS 走原 ntfs-3g 路径，其它 FS 明确报错 |
| `unmount_one` | **改**：卸载后若存在镜像设备，一并摘下（避免幽灵 /dev/diskM 与下次重复附加） |
| `bl_close_container` | **改**：先 `bl_detach_inner` 再停 dislocker；并把 SIGTERM→等待→SIGKILL→确认死亡 的收尾做扎实（防残留进程占用 `/dev/<dev>`） |
| `eject_one` | 复用 `bl_close_container` 的新清理逻辑（弹出物理盘前必先摘下镜像设备，否则弹不掉） |

## 五、踩坑：macOS 26 的 FSKit exFAT 挂载带 `fskit` 标记，但它是**可读写**的

挂载结果：

```
/dev/disk24 on /Volumes/Ventoy15.1 (exfat, local, nodev, nosuid, noowners, noatime, fskit, mounted by x)
```

`mount_state()` 原有的启发式规则是「挂载行含 `fskit` 即视为只读」——那是为识别 macOS 26 上
**FSKit 的 NTFS 只读寄生虫挂载**而加的。但 FSKit 的 **exFAT/FAT 实现是可读写的**，
若沿用该规则，会把这块刚挂上的可写 exFAT 解密卷误报成 `ro`，进而让守护进程/App 反复尝试"修复挂载"。

修正：仅当挂载行**不是我们附加的镜像设备**时，才把 `fskit` 当只读。

```bash
if printf '%s' "$line" | grep -q 'fskit'; then
  idev=$(bl_image_dev "$dev")
  if [ -z "$idev" ] || ! printf '%s' "$line" | grep -qF "/dev/$idev on "; then
    echo "ro"; return
  fi
fi
```

## 六、验证（真实 U 盘 disk4s1，密码 99999999）

```
✔ unlock       → 已解锁 + 已挂载读写(BitLocker/exfat): Ventoy15.1 → /Volumes/Ventoy15.1
✔ list         → disk4s1|Ventoy15.1|bitlocker|/Volumes/Ventoy15.1|rw
✔ 目录内容     → 看到盘上真实文档（辩词.docx / 起诉状-2026.docx / 证据目录…）
✔ 写入 8MB 随机数据 → 读回 SHA-256 与写入一致（★ 读写一致性 OK）→ 删除 OK
✔ unmount      → 挂载消失、/dev/disk24 消失、dislocker 进程仍在（解密链保留）
✔ mount        → 重新挂载成功，且**只有 1 个** /dev/disk24（无重复附加）
✔ lock         → 镜像已摘、dislocker 进程已退、list 回 locked、无任何残留
✔ 再 unlock    → 数据仍在（持久化 OK）
✔ eject        → "Disk disk4 ejected"，disk4 从系统消失，无残留进程/挂载
✔ 自检         → test/test-bitlocker.sh 17 项全绿
```

## 七、产品意义

至此 BitLocker 支持覆盖两种真实形态：

| 形态 | 内层 | 挂载方式 | 读写 |
|---|---|---|---|
| 笔记本/内置盘 BitLocker | NTFS（绝大多数） | ntfs-3g + FUSE-T | 原生读写 |
| U 盘 BitLocker To Go | **exFAT**、NTFS、FAT | hdiutil 原始镜像附加 + macOS 原生驱动 | 原生读写 |

App 侧无需改动：菜单栏「解锁」仍调用同一个 `ntfsctl unlock`，内层 FS 的判定与挂载方式由
`ntfsctl` 自动选择；`list` 的状态仍为 `rw`，钥匙串自动解锁链路照旧。
