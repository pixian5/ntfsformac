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

### 15. 守护进程与手动挂载并发导致同一盘叠加多个 FUSE-T 挂载
守护进程每 3 秒轮询，与用户手动 mount 并发时，两个 `ntfs-3g` 进程会先后挂到**同一个挂载点**（`/sbin/mount` 出现两行 `fuse-t:/<label> on ...`），同一 NTFS 设备多个写者，有损坏风险。
产生条件：A 执行 `unmount_competitors` 时 B 还没挂上 → A 挂载成功 → B 随后也挂载成功，双方互不可见。
处理三层：
- 挂载互斥锁：`/var/run/ntfsformac/mount.lock`（mkdir 原子锁，30s TTL 防进程崩溃残留），守护进程与手动操作共用，串行化挂载；
- 幂等检查：锁内先看目标挂载点是否已有 `fuse-t:/<label>` 挂载，有则直接复用返回；
- `unmount_competitors` 增加 `skip_target` 参数：挂载前全卸（含目标挂载点），挂载后清理时跳过目标挂载点。

### 16. 守护进程在卷标未探测到时抢挂到 /Volumes/NO NAME
NTFS 盘刚插入、diskutil 还没读出 NTFS 卷标时，`diskutil list` 显示 `NO NAME`，守护进程可能挂到 `/Volumes/NO NAME` 留下垃圾挂载。
处理：`mount_one` 里 label 为 `NO NAME`/空时等待重试（最多 10 秒），确认卷标后再挂载。

## 其它

### 17. 测试镜像盘的坑
- `hdiutil create -size 512m -layout NONE xxx.img` 会生成 `xxx.img.dmg`，attach 时要带 `.dmg`。
- `hdiutil attach -nomount` 可避免 macOS 自动挂载；`diskutil eject` 对磁盘镜像等价 detach。
- 用镜像盘测试正好能复现 Tahoe 的 FSKit 只读自动挂载行为。

### 18. macOS bash 是 3.2
无关联数组、无 `printf '%(...)T'`。脚本一律用空格字符串模拟集合、用 case 状态机。

## Parallels 虚拟机联动（Windows 里测同一块 NTFS 盘）

### 19. dmg → Parallels hdd 的两种转换
- `prl_disk_tool create --hdd <x.hdd> --dmg <x.dmg>` 生成的是**引用式**磁盘（DiskDescriptor.xml 里 `Type=DMG File=/tmp/x.dmg` 直接指向 dmg），零拷贝，但 dmg/hdd 都不能移动或删除，否则虚拟机打不开。
- 添加：`prlctl set "VM名" --device-add hdd --image /tmp/x.hdd --iface sata`，**添加后必须重启虚拟机**（热连接/热断开都会提示需要重启，`--device-connect/disconnect` 对运行中的 VM 无效）。
- 验证 Windows 侧：`prlctl exec "VM名" powershell -NoProfile -Command "Get-Disk | Select Number,Size"`。

### 20. Parallels 引用 dmg 时会锁文件，macOS 无法再读该镜像
同一 dmg 被 Parallels 作为虚拟盘挂给 Windows 后，macOS 侧 `hdiutil attach -nomount` 虽能建出磁盘节点，但**分区表读不出来**（`diskutil list` 只见 GUID_partition_scheme、无分区），`hdiutil detach -force` 也报「资源忙」。
处理：必须**停止虚拟机** → `prlctl set "VM名" --device-del hddX` 删除设备（运行中删不掉）→ 才能解锁 dmg 供 macOS 挂载。
注意：Windows 里安全弹出 I: 只释放 guest 访问，Parallels 进程仍持锁，macOS 照样读不了。

### 21. 同盘切系统使用 = 轮流独占
同一个 dmg 里的 NTFS 卷不能 macOS（FUSE-T）与 Windows（Parallels）**同时**写，否则损坏。
- 切给 Windows：macOS 先 `ntfsctl eject <dev>` → 重新添加 hdd 设备 → 重启虚拟机。
- 切回 macOS：Windows 先安全弹出盘 → 停虚拟机删设备 → macOS attach + `ntfsctl mount`。
- 数据互通验证：Windows 生成的 `$RECYCLE.BIN`、`System Volume Information` 在 macOS 挂载后可见；中文文件名在 cmd 里显示乱码是 GBK/UTF-8 编码问题，文件本身正常。

## BitLocker 支持（dislocker + FUSE-T）

### 22. FUSE-T 双层堆叠有约 0.5 秒「未就绪窗口」
BitLocker 解密链是 `ntfs-3g` 叠在 `dislocker-fuse` 之上（两层 FUSE-T）。挂载刚返回时，
**用户身份的首个写入会返回 EACCES（Permission denied）**，实测第 1 次失败（约 6ms）、第 2 次（约 0.5s 后）成功。
这不是权限配置问题（挂载点已是属主的 0777），而是双层 NFS/FUSE 初始化未完成的瞬态。
- 修复：`ntfsctl` 挂载 BitLocker 卷后调用 `bl_wait_ready`，以**属主身份**试建/删探针文件，
  成功才返回（最多等 5 秒，超时也放行）。修好后 `unlock` 返回即写入成功。
- 排查提示：用 root 探测不可靠（root 与 uid=501 的权限路径不同），必须用真实属主身份探测。

### 23. FUSE-T 写回缓存：锁定前先 sync
`bl_close_container` 中先 `sync`，再 `diskutil unmount` 容器，最后才 SIGTERM `dislocker-fuse`，
确保 `ntfs-3g` 写入 `dislocker-file` 的数据落到后端设备。
实测：即使不 sync，写→立即 lock→重新解锁数据仍在（层层 flush 有效），sync 只是安全网。

### 24. sudo 1.9.x 对带参数的 NOPASSWD 规则要求参数**完全匹配**
sudoers 里写 `/bin/bash <脚本>` 时，调用 `/bin/bash <脚本> foo` **不会**命中免密，会重新弹密码框。
- 修复：需要传参的脚本（如 `test/test-bitlocker.sh --device ...`）白名单用 `*` 通配
  （`/bin/bash <脚本>*`，`*` 也可匹配空串，零参数同时命中）；
- `build-app.sh` 改为零参数调用 `install-service.sh`，由脚本内部从 `SUDO_USER`/`/dev/console` 推导属主与源路径。

### 25. dislocker v0.7.3 在 FUSE-T 上的构建要点
- 必须用 **v0.7.3**（`FUSE_USE_VERSION=26`）；master 要求 FUSE 3.14，与 FUSE-T 不兼容。
- 三处补丁：`ssl_bindings.h.in`（mbedTLS3 用 `mbedtls_config.h`+`compat-2.x.h`）、
  `CMakeLists.txt`（`osxfuse`→`fuse-t`）、`dislocker-fuse.c`（去掉 osxfuse 头分支）。
- mbedTLS 用 `brew install mbedtls@3`（keg-only，头文件在 `include/mbedtls/mbedtls_config.h`，
  容易误写成 `include/mbedtls_config.h`）。
- cmake 4.x 拒绝低版本 minimum：需 `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`；
  `FindPolarSSL.cmake` 只找 `/usr/local/include`，需显式传 `-DPOLARSSL_INCLUDE_DIRS`/`-DPOLARSSL_LIBRARIES`。
- 补丁函数幂等判断要**先判断 old 是否存在**再判断 new，否则 new 是原文子串会误判「已修改」而跳过。

### 26. 无真实加密盘时如何造一块「真实」BitLocker 卷
- BitCracker 项目提供真实加密测试镜像：`Images/imgWin10Compat.vhd`（40MB，Windows 10 兼容模式 AES-CCM）。
- 它是 **fixed VHD 整盘**：解析 MBR 找到 BitLocker 分区（偏移 65536，签名 `-FVE-FS-`），提取该区域为裸卷；
  口令见 `Dictionary/user_passwords.txt`。
- macOS 上裸卷文件无分区表，`diskutil` 识别为无分区，`ntfsctl list` 看不到 →
  用 Python 把裸卷包进**标准 GPT 磁盘镜像**（分区类型 Microsoft Basic Data），即可呈现为 `diskXs1` 走完整流程。
- 排错：Parallels 虚拟机盘是 Compressed 格式（`DiskDescriptor.xml` `Type=Compressed`）非裸盘，dislocker 读不了；
  picoCTF 的 bitlocker 镜像 CDN 已失效。

### 27. dislocker 的恢复密码必须是 **55 字符**带连字符格式
`dislocker -p` 走的 `is_valid_key()`（`src/accesses/rp/recovery_password.c`）第一件事就是
`if(strlen(...) != 48+7)` 直接返回失败，之后按「6 位数字 + 1 个连字符」分组（`rp += 7`）逐块解析。
因此**既不能只传 48 位纯数字，也不能带多余空格/换行**，必须传 `123456-123456-…`（48 位 + 7 个连字符）。
- 现象：传纯数字会看到 `Error handling the recovery password: Wrong length (has to be 55)`；
  传对格式但密钥错误时才是 `Unable to compute regions`。
  这个差异可以用来**在不掌握真实密钥的情况下验证格式链路是否正确**。
- 处理：ntfsctl `--recovery` 先 `tr -cd '0-9'` 只留数字 → 校验 48 位 → `sed` 按 6 位插回连字符，用户随便怎么粘都能用。

### 28. 校验"字符串是否编进二进制"时别被 Swift 小字符串优化误导
Swift 会把 **≤15 字节**的 UTF-8 字面量内联存储，不落在 `__TEXT,__cstring`，
于是 `strings`/`grep` 完全找不到，容易误判"代码没编进去"。
- 例：`用密码解锁…`(18 字节) 找得到；`--bek`(5 字节)、`已忘记凭据`(15 字节) 找不到。
- 正确做法：用 Python 逐字节 `bytes.count(s.encode('utf-8'))` 统计，并明确"找不到 ≠ 没编进去"。
  更可靠的等价验证是核对上游数据契约（如 `ntfsctl list --porcelain` 的字段数与含义）再做静态推理。

### 29. dislocker 遇到「未知 value_type」的 datum 会中断整个遍历（真实 U 盘解锁失败根因）
`src/metadata/datums.c` 的 `get_next_datum()` 用 `get_header_safe()` 校验每个 datum 头，
而该函数在 `value_type > NB_DATUMS_VALUE_TYPES`（本版本已知表只到 22）时返回 FALSE，
原代码据此 **`break` 掉整个遍历**（而不是跳过这一个）。
- 后果：新式 Windows 卷里的未知 datum（实测 entry_type=46 / value_type=37）会挡住**它后面**的
  `FVEK(entry 3)` 与 `VIRTUALIZATION_INFO(value 15)`，导致 `end_compute_regions()` 找不到 type 15 →
  `Unable to compute regions. Abort.`。**这个错误与密码对错无关**（`ntfsctl info` 无凭据也报同样的错）。
- 修复：改为读出 datum 头后，仅以 `datum_size >= sizeof(datum_header_safe_t)`(8) 为门槛继续遍历
  （保证偏移单调前进不死循环），把未知 value_type 降级为「可跳过」。见
  docs/20261014-2235-未知datum解析修复-DeepSeek-V4.1-Flash.md。
- 顺带修 `print_metadata.c` 的 `print_data()` 同构循环，否则 `ntfsctl info -v` 也列不全 datum。

### 30. 区分「元数据解析失败」与「凭据错误」的两类报错
排查 BitLocker 解锁失败时，先看错误落在哪一层，能省掉大量试密码的时间：
- **结构层**：`Unable to compute regions` / `找不到 VIRTUALIZATION datum type 15` → 解析器问题（见 #29）。
- **凭据层**：`MAC check failed for AES-CCM key ...` → `Unable to get the VMK (error 0x800c0006)` →
  `Can't initialize dislocker` → dislocker 已用凭据派生密钥并做了 AES-CCM 校验，**校验失败即凭据不匹配**。
- 辅助判据：`ntfsctl info`（无凭据）若能成功列出全部 datum，则结构正常，问题在凭据；
  若 `info` 也失败，则是解析/结构问题。
- 排错工具三件套：`ntfsctl info -v`（datum 列表）、`ntfsctl dump`（导原始元数据副本离线核对）、
  `ntfsctl unlock --verbose`（看它选了哪个 VMK / 用了什么盐值 / 哪种解密方式）。

### 31. BitLocker 卷的内层文件系统可能是 exFAT（不是 NTFS！）
BitLocker 加密的是「卷」（块设备），内层 FS 可为 NTFS / exFAT / FAT；Windows 10+ 对**可移动盘**
（BitLocker To Go）默认常用 **exFAT**，真实 U 盘上非常常见。
- 症状：密码正确、dislocker 解密成功，但 ntfs-3g 挂载失败（它只认 NTFS）。
- 判定：读解密卷（`/var/run/ntfsformac/bl/<dev>/dislocker-file`）首扇区偏移 3 起 8 字节，
  `NTFS    `=NTFS；`EXFAT   `=exFAT；偏移 0x52 起 `FAT32   `/`FAT16   `=FAT。
- 解决：exFAT/FAT 不能交给 ntfs-3g，改用 **macOS 自带读写驱动**，但内核/FSKit 驱动只认块设备，
  因此需先把解密文件「附加成块设备」：
  ```bash
  hdiutil attach -nomount -noverify -imagekey diskimage-class=CRawDiskImage <dislocker-file>
  diskutil mount /dev/diskM
  ```
  **`-imagekey diskimage-class=CRawDiskImage` 必须带**（按原始裸磁盘镜像处理，否则可能被当作
  UDIF/稀疏映像导致偏移或只读）。以 GUI 属主身份附加+挂载，`/Volumes/X` 属主才是登录用户。
- 收尾：卸载/弹出前必须先 `diskutil eject /dev/diskM` 摘掉镜像设备，否则会残留幽灵磁盘、
  下次重复附加出第二个 `/dev/diskM`（同一卷被挂两次的隐患）。
- 详见 docs/20261014-2310-BitLocker内层exFAT挂载-DeepSeek-V4.1-Flash.md。

### 32. macOS 26 的 `fskit` 挂载标记 ≠ 只读（仅 NTFS 才是只读）
`/sbin/mount` 输出里带 `fskit` 表示该 FS 由 macOS 的 FSKit 用户态框架实现。
- FSKit 的 **NTFS** 实现是只读寄生虫（本项目要识别并清理）。
- FSKit 的 **exFAT/FAT** 实现是**原生读写**（实测 `/dev/disk24 on /Volumes/X (exfat, ..., fskit, ...)`
  可正常写入）。
- 教训：不能把「挂载行含 fskit」一律当作只读，否则会把刚挂上的可写 exFAT 解密卷误报成 `ro`，
  引发守护进程/App 反复"修复挂载"。判定只读时应排除「我们附加的镜像设备」这种情况。

### 33. 同一 NTFS 卷被挂两次的另一条路径：重复 attach 镜像
`unmount` 若只卸载文件系统而不摘下 `hdiutil attach` 出来的镜像设备，再次 `mount` 会**又 attach 一次**，
得到第二个 `/dev/diskM`。虽然两者都指向同一 `dislocker-file`（不比两块独立挂载危险），但仍属叠加挂载。
- 修复：`unmount_one` 在卸载后立刻 `bl_detach_inner`；`bl_attach_inner` 进入前也先清理残留镜像记录。

### 34. `security` 会把「非可打印 ASCII」的钥匙串值存成十六进制文本
macOS 的 `security add-generic-password -w <值>` 在值含有**可打印 ASCII 之外的字节**时，
会把值改存为该值的**十六进制文本**，`find-generic-password -w` 读出来也是那段 hex 文本。
实测：

| 写入 | 读回 | 被 hex 化？ |
|---|---|---|
| `u99999999`（纯 ASCII 可打印） | `u99999999` | 否 ✔ |
| `99999999`+换行+`u` | `39393939393939390a75` | **是** ✘ |
| `ab`+制表符+`cd` | `6162096364` | **是** ✘ |
| `密码9999`（中文多字节） | `e5af86e7a08139393939` | **是** ✘ |

- 后果：App 旧版用 `<凭据>\n<方法码>` 存，**必然含换行** → **每一条**都被 hex 化 →
  「记住密码」100% 失效（读回当密码用，dislocker 必然 MAC 校验失败）。
- 修复：把 `<方法码><凭据>` 整体 UTF-8 **十六进制编码**后再存（纯 ASCII 文本，`security` 不再改写）。
- 注意：**含中文的密码**没有控制字符也会被 hex 化，修复必须覆盖所有字节，不能只处理换行。
- 详见 docs/20261014-2351-记住密码修复与挂载签名预检-DeepSeek-V4.1-Flash.md。

### 35. 钥匙串里的设备凭据必须用「卷 GUID」做键，不能用设备名
`diskXsY` 是 macOS 每次枚举时分配的，**重新插拔（甚至重新 attach 同一镜像）都会变**
（`disk4s1` → `disk6s1`）。用它当钥匙串 account，键变了就永远查不到旧条目 →
即便记住了密码也不会自动解锁。
- 正解：用 BitLocker 卷头里**明文可读**的 **Volume GUID**（跨插拔稳定）。
  取法按签名区分偏移：`-FVE-FS-` → 卷头 `0xa0`；`MSWIN4.1` → 卷头 `0x1a8`；各取 16 字节，
  还原 Windows 混序端序（前 4/2/2 字节组内反转，后 8 字节保序）。
- 验证方法（无需真盘）：把同一份 BitLocker 镜像复制两份副本分别 attach（设备号必然不同），
  读出的 GUID 应完全一致。
- App 侧建议：读取先查 GUID、再回退设备名（兼容旧条目）；保存用 GUID 键并**顺带删除旧设备名条目**。

### 36. `autoTried` 这类「已尝试」标记必须在确认有凭据之后再写
旧版 `refresh()` 在**读取钥匙串之前**就写入 `autoTried`：
先标记、后读凭据。于是「第一次插入时还没记住密码」的盘被本会话**永久标记为已尝试**，
之后哪怕保存了凭据也永远不会再自动解锁。
- 正解：`guard let (...) = loadCredential(...) else { continue }` **之后**才 `autoTried.insert(key)`。
- 配套：另设 `noCredChecked` 只记「确无凭据」，保存凭据成功时清掉该盘的两个标记。

### 37. 挂载前签名预检：读到空必须 fail-open（继续挂载），不能跳过
为防非 NTFS 分区刷屏而加的「首扇区签名预检」，最初实现为「读不到也跳过」（fail-closed），
导致 `test-automount.sh` 失败：
- 原因：卷**已被 macOS/FSKit 只读挂载**时，裸设备读取会因 `EBUSY` 失败（读到空）。
  而这恰是最需要抢挂成读写的场景（Tahoe 上 FSKit 会把 NTFS 挂成只读寄生虫）。
- 正解：**只在「确实读到了签名、且签名不是 NTFS」时跳过**；读到空一律继续走正常挂载流程。
  （`NTFS    ` 的十六进制是 `4e54465320202020`。）
- 实现细节：用 `od -An -tx1` 取十六进制串比对，**不经 shell 变量承载原始字节**——
  非 NTFS 分区该处常含 NUL 字节，bash 命令替换会丢弃它们并刷噪音。
- 位置：必须放在 `is_bitlocker` 判断**之后**的非 BitLocker 分支，否则会把所有加密盘都跳过。

### 38. bash 中 `$var` 紧跟多字节字符会吞掉变量名
`log "跳过 $dev：首扇区签名非 NTFS"` 输出成 `跳过 ：首扇区签名非 NTFS`——`$dev` 消失了。
原因是 `$dev` 后面紧跟**全角冒号**（多字节 UTF-8），bash 解析变量名时把后续字节也算了进去。
- 教训：变量后紧跟多字节字符（中文标点、中文词）时，一律用 `${var}` 界定：
  `log "跳过 ${dev}：..."`、`die "$dev 解密卷内层为 ${ifs}，暂不支持挂载"`。

### 39. `lock` 必须与 `unlock`/挂载共享同一把互斥锁，否则出现「解锁假成功」
`bl_lock_one`（`ntfsctl lock`）最初**没有**走 `lock_mount` 互斥锁，而 `bl_unlock_one` / `mount_one` 都走了。
于是「锁定」可以和另一进程刚建立的解锁并发：`bl_close_container` 会把刚挂好的 dislocker-fuse 容器拆掉，
表现为 **App 日志报「自动解锁成功」，但几秒后卷又变回 `locked`（且 dislocker-fuse 进程为 0）**。
- 复现方式：同时（或紧接）发起 `ntfsctl lock` 与 App 自动解锁。实测因此误判过一次「自动解锁不生效」，
  实为测试步骤自身造成的竞态。
- 修复：`bl_lock_one` 全程持有 `lock_mount`（`trap 'unlock_mount' EXIT` 兜底）。
- 启发：凡是会**改动同一设备挂载态**的子命令（lock / eject / mount / unmount）都应共享这把锁。
  v0.0.14 已把 `eject_one` 也纳入（见 #41 附近的验证清单），至此四者全部串行化。

### 40. `read` 的最后一个变量会吞掉「本行剩余」——但影响面取决于「行尾字段是否为空」
`ntfs-automount.sh` 的扫描循环原本是 `IFS='|' read -r dev label fs mp state`（5 个变量）。
v0.0.12 给 `ntfsctl list --porcelain` 加了第 6 个字段 `guid` 后，`read` 的最后一个变量会吃下「本行剩余」，
于是 `state` 被污染成 `rw|<guid>`。
- **修正后的真实影响面**（初版本文档把它写成「自动挂载彻底静默失效」，是经 zsh 复现得出的**错误结论**）：
  - 第 6 字段**非空**（BitLocker 卷，guid 非空）→ `state="rw|4967D63B-…"` → `case` 失配 →
    `rw` 分支的只读寄生虫清理不执行、`ro`/`none` 时不自动挂载。
  - 第 6 字段**为空**（NTFS 卷）→ **bash 会把尾部空字段连同分隔符一起剥掉**，`state` 仍是干净的 `ro`/`none`，
    **NTFS 自动挂载一直正常**。
- 复现（**必须在 bash 下**，见 #44）：
  ```
  printf 'a|b|c|d|ro|\n'  | /bin/bash -c 'while IFS="|" read -r v1 v2 v3 v4 state; do echo "[$state]"; done'  # [ro]
  printf 'a|b|c|d|rw|GUID\n' | /bin/bash -c 'while IFS="|" read -r v1 v2 v3 v4 state; do echo "[$state]"; done'  # [rw|GUID]
  ```
- 修复：`read -r dev label fs mp state guid _rest`（多读一个 `_rest` 兜底，以后再加字段也不重演）。
- 教训：**行式协议的字段数一旦变化，必须检查所有消费方**；「多出的字段用兜底变量接住」应成为书写习惯。
  这类回归不报错、不写日志，只表现为功能莫名不工作。

### 41. 手动锁定标记必须**先落**，再卸载/停容器（否则存在竞态窗口）
菜单栏 App 每 3 秒轮询，看到 `locked` 且钥匙串有凭据就自动解锁 —— 会让命令行 `ntfsctl lock` 白做。
第一版把 `touch /var/run/ntfsformac/locked.<dev>` 放在 `bl_close_container` **之后**，验证时撞上竞态：
- 时序：`lock` 执行中卷已 unmount、marker 还未创建 → App 恰好在此窗口读到 `locked` 且看不到 marker
  → 自动解锁 → 调 `ntfsctl unlock` → 反而把 marker 清掉。
- 证据：App 日志 `00:38:35 尝试自动解锁` / `00:38:43 成功`，而 `ls` 显示 marker 时间同为 `00:38`
  （命令返回时 marker 已在，但 App 早在那之前 refresh 过）。
- 修复：marker 创建提到 `lock_mount` **之后、任何卸载动作之前**。此时两种情况都拦得住：
  refresh 早于本命令看到的是 `rw`（不进解锁分支）；晚于本命令则看到 marker。
- 修正后验证：连测 12 秒，卷保持 `locked`，App 日志**零新增**（连 `readCredential` 都没调用）。

### 42. 自定义报错面板要用 `.nonactivatingPanel` + `level = .normal`，且不能 `runModal()`
`NSAlert + runModal()` 作为菜单栏常驻 App 的报错手段有三个问题：`informativeText` 是 label **不能选中**；
`runModal()` **独占事件循环**（弹窗期间 App 卡死、定时器停摆）；窗口默认**浮在最前抢焦点**挡住用户操作。
- 替代实现：`NSPanel(styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel])`
  - `level = .normal` + `isFloatingPanel = false` → 不置顶；
  - `becomesKeyOnlyIfNeeded = true` → 不抢键盘焦点；
  - `orderFrontRegardless()` → 显示但不 activate App（**关键**：别用 `makeKeyAndOrderFront`）；
  - `hidesOnDeactivate = false` → App 失活时不自动隐藏，否则用户找不到报错。
- 正文用 `NSTextView`（`isSelectable = true` / `isEditable = false`）包 `NSScrollView`，才能拖选 + ⌘C。
- 内存：`isReleasedWhenClosed = false`，并在 `windowWillClose` 回调里移除外部字典引用，避免野指针。

### 43. 以普通用户身份读取 root 属主目录下的标记文件，前提是目录 0755、文件 0644
App 要判断「用户是否手动锁定过」，办法是 `FileManager.fileExists(atPath: "/var/run/ntfsformac/locked.<dev>")`。
这**不需要提权**：`/var/run/ntfsformac` 是 `drwxr-xr-x root:daemon`（others 有 r-x），
标记文件由 root 默认 umask 创建为 `0644`（others 可读）。实测 `fileExists` 返回 `true`。
- 反例警示：若目录权限收紧为 `0700`，App 就会「看不到标记」从而错误地自动解锁，
  且**不会报任何错**——排查时极易误判为「App 代码没生效」。
- 结论：跨权限边界传递状态时，务必确认路径每一级的 others 权限，并优先用「stat 一下」来验证而不是猜。

### 44. macOS 上交互 shell 是 zsh、脚本 shebang 是 bash —— 用 zsh 复现 `read`/`IFS` 行为会得出与运行时相反的结论
本机 `/bin/zsh`（交互）与 `/bin/bash`（3.2，脚本 shebang）对 `read` 的**行尾空字段**处理不同：

| 输入（IFS='\|'，`read -r a b c d state`） | bash 3.2 | zsh |
|---|---|---|
| `a\|b\|c\|d\|ro\|`（尾部空字段） | `ro`（**剥掉尾部分隔符**） | `ro\|`（保留） |
| `a\|b\|c\|d\|rw\|GUID`（尾字段非空） | `rw\|GUID` | `rw\|GUID` |

- 踩坑经过：排查 #40 时我在交互 shell（zsh）里复现，得到 `state="ro|"`，据此断言「NTFS 自动挂载彻底失效」
  并写进了文档与代码注释；后来做端到端实验（守护进程实际在 bash 下运行）才发现 NTFS 路径**一直是好的**。
- 结论：**复现必须与被复现者的 shell 一致**。
  - 守护进程/测试脚本一律 `/bin/bash` 运行 → 复现也用 `/bin/bash -c` 或把测试写进 `#!/bin/bash` 脚本。
  - 反之，用 `zsh -c` 复现 bash 脚本的行为，是**无效证据**。
  - 本项目的测试脚本已显式用 `sudo -n /bin/bash <绝对路径>` 调用，正是为了避免这类歧义。

### 45. 卷**已挂载**时，读 `/dev/diskXsY`（缓冲设备）会 `Resource busy` → 读到 0 字节；必须改用 `/dev/rdiskXsY`（裸设备）
这是本轮「分区找出来了却显示 unreadable / 挂载失败」的**根因**，也是最隐蔽的一坑：

| 设备节点 | 卷已挂载时读取 | 说明 |
|---|---|---|
| `/dev/disk4s1`（缓冲设备，buffered） | `dd: Resource busy` → **0 字节** | 内核块设备层被挂载占用 |
| `/dev/rdisk4s1`（裸设备，raw） | 正常读出 512 字节 | 绕过缓冲区，直接访盘 |

- 复现：`dd if=/dev/disk4s1 bs=512 count=1` → 0 字节；同一时刻 `dd if=/dev/rdisk4s1 bs=512 count=1` → 512 字节。
- 后果：`fs_type_of` 读首扇区得空 → 返回 `unreadable` → 挂载前预检把**真 NTFS 盘**当「未知内容」跳过，
  守护进程不挂（test-automount 由 7/0 变 0/1）。
- 处理：新增 `dev_io()`，**所有内容读取与整分区导出一律走 `dev_io`**（优先 `/dev/r<dev>`，不存在才回退 `/dev/<dev>`）。
- 教训：**只在读取卷内容时**要小心；`hdiutil attach`、`mount` 等操作仍必须用原本的 `/dev/diskXsY`。

### 46. 裸设备 `/dev/rdiskN` **只接受扇区对齐读写**——字节粒度读必须「扇区对齐 dd + 切片」
`/dev/rdiskN` 不接受任意字节偏移/长度的读写：

```
dd if=/dev/rdisk4  bs=1 skip=3 count=8   → 0 字节（静默失败，不报错）
dd if=/dev/disk4   bs=1 skip=3 count=8   → 8 字节（但缓冲设备在卷已挂载时 EBUSY，见 #45）
```

于是 exFAT 卷标（要从根目录某个**非扇区对齐**的字节偏移读）、FAT BPB 字段等字节粒度读取都读不出来。
- 处理：新增 `dev_read_bytes <dev> <字节偏移> <长度>`——先把偏移向下取整到扇区边界，
  用扇区对齐的 `dd bs=512 skip=<first> count=<cnt>` 读一段，再用 `tail -c`/`head -c` 切出目标区间。
- 结论：**字节读 = 扇区对齐 dd + `tail -c`/`head -c` 切片**；不要对裸设备直接用 `bs=1`。
- 测试注意：把 `dev_read_bytes` 从 ntfsctl 抽出到测试脚本 `eval` 时，同时要抽出它依赖的 `dev_io` 与 `as_root_np`
  （`as_root_np() { "$@"; }` 即可），否则测试里会 `command not found` 假失败。
