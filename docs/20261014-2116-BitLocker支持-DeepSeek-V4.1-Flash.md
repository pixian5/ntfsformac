# BitLocker 解锁与读写支持（2026-10-14 21:16）

> 版本：0.0.8 ｜ 模型：DeepSeek-V4.1-Flash ｜ 仓库：https://github.com/pixian5/ntfsformac

## 目标

在原有「NTFS 读写」基础上，增加对 **BitLocker 加密卷**的检测、解锁、读写挂载与重新锁定能力，
且保持既有的**零授权框**体验（全部走免密 sudo）。

## 技术方案

BitLocker 目前唯一可用的开源读写方案是 **dislocker**。本项目选用 **v0.7.3**（Aorimn/dislocker），
因为它使用 `FUSE_USE_VERSION=26`，与 FUSE-T（仅实现 FUSE 2.9 API）兼容；master 分支要求 FUSE 3.14，不兼容。

### 三层解密链

```
/dev/diskXsY  ──dislocker-fuse──▶  <容器>/dislocker-file  ──ntfs-3g──▶  /Volumes/<卷标>
   (加密卷)          (解密并透传写)      (虚拟解密卷文件)          (正常 NTFS 读写)
```

- `dislocker-fuse` 把加密卷解密成一个虚拟文件 `dislocker-file`，写操作会**透传**回加密卷；
- `ntfs-3g` 再把这个虚拟文件当普通块设备挂成 NTFS 读写；
- 容器挂载点为 `/var/run/ntfsformac/bl/<dev>`（`/var` 实为 `/private/var` 符号链接，解析挂载点时需按后缀匹配）。

### 构建链（已脚本化进 install-driver.sh）

- 依赖：`brew install mbedtls@3`（3.6.7，keg-only）+ `libgcrypt`；
- 三处源码补丁（幂等，用 python heredoc 打）：
  1. `include/dislocker/ssl_bindings.h.in`：mbedTLS 3 用 `mbedtls_config.h` + `compat-2.x.h`，2.x 用 `config.h`；
  2. `src/CMakeLists.txt`：`osxfuse` → `fuse-t`；
  3. `src/dislocker-fuse.c`：去掉 `#include <osxfuse/fuse.h>` 分支，统一 `#include <fuse.h>`。
- cmake 关键参数：`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`（cmake 4.x 拒绝低版本 minimum）、
  显式传 `-DFUSE_INCLUDE_DIRS` / `-DFUSE_LIBRARIES` / `-DPOLARSSL_INCLUDE_DIRS` / `-DPOLARSSL_LIBRARIES`；
- 产物暂存 `build/dislocker/`，由 `install-service.sh` 安装 `/usr/local/bin/dislocker-*` 与 `/usr/local/lib/libdislocker*`。

## 改动清单

| 文件 | 改动 |
|---|---|
| `scripts/ntfsctl` | 新增 BitLocker 检测/解锁/挂载/清理；新增 `unlock`/`lock` 子命令；`list` 增加 `fs` 与 `locked` 状态；挂载后**就绪等待** |
| `install-driver.sh` | 新增 dislocker v0.7.3 构建段（含三处补丁与 mbedTLS3 回填） |
| `scripts/install-service.sh` | 新增 dislocker 安装段；sudoers 白名单给测试脚本加 `*` 通配（适配 sudo 1.9 参数完全匹配） |
| `NTFSMounter.swift` | 增加 `fs`/`locked` 状态、`lock.fill` 图标、「解锁 BitLocker…/重新锁定/忘记密码」菜单、Keychain 记住密码与自动解锁；`list` 改走 root 以保证 `dd` 能读首扇区 |
| `test/test-bitlocker.sh` | 新建：自检模式（无需真实盘，17 项）+ 真实加密盘全流程（29 项） |

### 关键接口

```bash
ntfsctl list --porcelain        # device|label|<ntfs|bitlocker>|mountpoint|<rw|ro|none|locked>
ntfsctl unlock disk4s1 --password-file /path/pw   # 解锁并挂载（也支持 --password / --bek / --clearkey）
ntfsctl lock disk4s1            # 卸载并停止解密
ntfsctl eject disk4s1           # 卸载 + 停解密 + 弹出父盘
```

- **不猜密码**：未解锁的加密卷，自动挂载守护进程只标记 `locked` 并跳过，绝不会尝试验证口令；
- 解锁成功后 App 用钥匙串（`security`，service `NTFSFormac`）记住密码，下次插入自动解锁。

## 验证方法与结果

`sudo bash test/test-bitlocker.sh` → 自检 **17 项全绿**（组件、签名检测、不自动挂载、错误密码资源清理）。

真实加密卷端到端 `--device disk4s1 --password-file <pw>` → **29 项全绿**，覆盖：
解锁 → 解密卷挂载为读写 → 写入并读回 → 卸载 → 重新锁定（无残留 dislocker 进程）→ 再次解锁 →
数据仍在 → 安全弹出。

### 真实 BitLocker 卷来源（本机无真实加密盘时的替代）

本机无真实 BitLocker 加密盘，Parallels 虚拟机磁盘是 Compressed 格式（非裸盘），picoCTF 镜像 CDN 已失效。
最终采用 **BitCracker 项目公开测试镜像**：

1. 下载 `https://raw.githubusercontent.com/e-ago/bitcracker/master/Images/imgWin10Compat.vhd`（40MB，Windows 10 兼容模式 AES-CCM）；
2. 解析 fixed VHD 的 MBR，定位偏移 65536 的 BitLocker 分区（签名 `-FVE-FS-`），提取为裸卷；
3. 用 `Dictionary/user_passwords.txt` 逐个试密码，确认有效口令（`dislocker-fuse` 挂载成功即判有效）；
4. 用 Python 把裸卷包进标准 **GPT 磁盘镜像**（分区类型 Microsoft Basic Data），使其在 macOS 呈现为 `diskXs1`，
   从而能走完整的 `ntfsctl list/unlock/mount` 流程。

## 关键坑（详见 known-issues.md 新增条目）

1. **FUSE-T 双层堆叠有 ~0.5s 未就绪窗口**：`unlock`/`mount` 刚返回时，用户身份的首个写入会返回 EACCES
   （Permission denied），实测第 1 次失败、约 0.5 秒后成功。修复：挂载后以属主身份试建探针文件，
   成功才返回（`bl_wait_ready`，最多等 5 秒，超时也放行）。
2. **写入持久化本身是正常的**：写 → 立即 lock（不 sync）→ 重新解锁，数据仍在；层层 flush 也验证通过。
   关闭容器前额外加 `sync` 作为安全网。
3. **sudo 1.9.17 对带参数的 NOPASSWD 规则要求参数完全匹配**：`/bin/bash <脚本>` 白名单不能带参数调用，
   否则重新弹密码框。修复：测试脚本白名单用 `*` 通配，`build-app.sh` 改为零参数调用 `install-service.sh`
   并由脚本内部推导 owner/源路径。

## 已知限制

- 仅支持 **用户密码 / 恢复密码 / BEK 文件 / 明文密钥**解锁方式；TPM-only 卷（无外部口令）无法解锁；
- 依赖 `mbedtls@3`（Homebrew keg-only），构建期需联网安装；
- BitLocker 卷的写入性能受双层 FUSE 影响，比普通 NTFS 略慢；
- 尚未在**物理** BitLocker 盘上压测（当前用真实加密镜像盘验证）。
