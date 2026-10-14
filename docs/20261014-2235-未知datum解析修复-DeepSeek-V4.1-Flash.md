# 未知 datum 导致 BitLocker 解锁失败（dislocker 源码修复）

> 版本：0.0.10 ｜ 模型：DeepSeek-V4.1-Flash ｜ 日期：2026-10-14 22:35
> 承接 docs/20261014-2116-BitLocker支持-DeepSeek-V4.1-Flash.md、docs/20261014-2145-恢复密码与BEK解锁入口-DeepSeek-V4.1-Flash.md

## 一、问题现象

用户插入一块真实 BitLocker 加密 U 盘（`/dev/disk4s1`，16.4 GB，Ventoy 结构：s1 加密数据 + s2 EFI），
用密码解锁时**无论密码对错**都在元数据解析阶段失败：

```
[ntfsctl] [CRITICAL] Unable to compute regions. Abort.
[ntfsctl] 错误: BitLocker 解锁失败（密码/恢复密钥错误，或卷损坏）
```

关键点：错误发生在 `end_compute_regions()`，即**元数据结构解析阶段**，与密码是否正确无关
（密码错了应该是「找不到 VMK / 解不出密钥」，不会报这个）。

## 二、定位过程（对照实验）

1. **证明与密码无关**：`ntfsctl info`（读元数据，**不需要任何凭据**）在同一块 U 盘上就报同样的错。
   元数据 datum 头（entry_type / value_type / datum_size / status）是**明文**的，只有 payload 加密，
   所以「info 都失败」说明是解析器问题而非凭据问题。

2. **对照可正常工作的样本卷**（BitCracker 的 `imgWin10Compat.vhd`）：
   `ntfsctl info -v` 完整成功，并列出 5 个 datum，其中
   `Datum n°5 = VIRTUALIZATION INFO (value_type 15)`；同一份代码能解锁它 → 解析器本身可用。

3. **抓原始元数据离线核对**：新增 `ntfsctl dump <disk>`（见下）导出卷头与 3 份元数据副本原始字节，
   再用 Python 逐字节解析 U 盘数据集，得到**决定性结论**：

   | n° | entry_type | value_type | 大小 | 说明 |
   |---|---|---|---|---|
   | 1 | 7 (ENCTIME_INFO) | 2 (UNICODE) | 0x30 | 描述串 |
   | 2 | 2 (VMK) | 8 (VMK) | 0x160 | VMK#1（range 0x2000，**用户密码**保护器） |
   | 3 | 2 (VMK) | 8 (VMK) | 0x118 | VMK#2（range 0x0800，**恢复密码**保护器） |
   | 4 | **46（未知）** | **37（未知）** | 0x0c | Windows 新式 datum，payload `01 00 00 00` |
   | 5 | 3 (FVEK) | 5 (AES_CCM) | 0x30 | **全卷加密密钥** |
   | 6 | **15** | 15 (VIRTUALIZATION_INFO) | 0x88 | **dislocker 强制要求的那个 datum** |

   **FVEK 与 VIRTUALIZATION INFO 其实都在盘上！** 之前 dislocker 报「找不到 type 15」是假象。

4. **定位到真正的根因**：`src/metadata/datums.c` 的 `get_next_datum()` 遍历循环：

   ```c
   while(...) {
       if(!get_header_safe(...))      // value_type > NB_DATUMS_VALUE_TYPES(22) 时返回 FALSE
           break;                     // ← 直接中断【整个】遍历，而不是跳过这一个
       ...
   }
   ```

   U 盘的 **n°4 datum value_type = 37 > 22**（本版本已知表只到 22），于是遍历在 n°4 就 `break`，
   位于其后的 **n°5 FVEK** 与 **n°6 VIRTUALIZATION INFO 永远读不到** →
   `end_compute_regions()` 找不到 type 15 → `Unable to compute regions. Abort.`

   日志里的佐证（`ntfsctl info -v`）正是这个：`Header safe: 0xc, 0x2e, 0x25, 0x1`
   （= datum_size 12, entry 46, value 37）之后紧接 `Going out of get_next_datum`。

## 三、修复方案

上游 master 已针对「VIRTUALIZATION datum 迭代不到」加入线性扫描兜底，但 master 要求 FUSE 3.14
（与 FUSE-T 不兼容，见 known-issues #25），**不能整体升级**。本次改为**最小补丁**：让遍历遇到
未知 value_type 时**跳过而不是中断**。

在 `install-driver.sh` 的 dislocker 构建段新增第 4 处幂等 python 补丁（共两处同构修改）：

```python
_HDR_SKIP = (
    '\t\t/* 未知 value_type 的 datum 不能中断遍历：其后可能还有 FVEK /\n'
    '\t\t * VIRTUALIZATION_INFO，跳过它继续找（datum_size>=8 保证单调前进）。 */\n'
    '\t\tmemcpy(&header, @V@, sizeof(datum_header_safe_t));\n'
    '\t\tdis_printf(L_DEBUG, "Header safe: %#x, %#x, %#x, %#x\\n",\n'
    '\t\t\theader.datum_size, header.entry_type, header.value_type, header.error_status);\n'
    '\t\tif(header.datum_size < sizeof(datum_header_safe_t))\n'
    '\t\t\tbreak;\n'
)
# 4a) 查找关键 datum 的遍历（FVEK / VIRTUALIZATION_INFO 依赖它）
patch('src/metadata/datums.c',
      '\t\tif(!get_header_safe(datum, &header))\n\t\t\tbreak;\n',
      _HDR_SKIP.replace('@V@', 'datum'))
# 4b) 诊断打印的遍历（ntfsctl info -v 能列出全部 datum，含未知类型）
patch('src/metadata/print_metadata.c',
      '\t\tif(!get_header_safe(data, &header))\n\t\t\tbreak;\n',
      _HDR_SKIP.replace('@V@', 'data'))
```

设计要点：用 `datum_header_safe_t` 结构体整体读出 4 个头字段并打日志（取代原 `get_header_safe()`
的逐字段校验），再用 `datum_size >= sizeof(datum_header_safe_t)`（8 字节）作为唯一的合法性门槛，
**保证偏移单调前进、不会死循环**；同时把「未知 value_type」从「致命」降级为「可跳过」。

## 四、配套新增的诊断能力（本轮一并加入 ntfsctl）

| 命令 | 作用 |
|---|---|
| `ntfsctl info [-v] <disk\|label\|all>` | 无需凭据读 BitLocker 元数据；`-v` 输出 dislocker 调试日志（含 datum 列表） |
| `ntfsctl dump <disk> [输出目录]` | **新增**：导出卷头 + 3 份 64KiB 元数据副本原始字节 + metadata.log，供离线逐字节核对 |
| `ntfsctl unlock ... --verbose` | **新增**：把 dislocker 调试日志打开（默认只打印 CRITICAL，失败时看不到「找到了哪个 VMK / 盐值 / 解密方式」） |

`dump` 的实现要点：偏移取 `dislocker-metadata -v` 打印的最后一次出现的
`First/Second/Third metadata header offset`（volume header 与 information 块各打印一次，后者才是权威值），
再按 512 字节扇区对齐 `dd` 出 128 个扇区（= 0x10000 = 64KiB，元数据副本固定大小）。

## 五、修复验证

1. **解析恢复**：`sudo ntfsctl info -v disk4s1` 不再报 `找不到 VIRTUALIZATION datum type 15`，
   并成功列出 `Datum n°4 / n°5(FVEK) / n°6(VIRTUALIZATION INFO)`。
2. **错误性质改变**（关键证据）：解锁不再报结构错误，而是进入密钥解密阶段后失败：
   ```
   [ERROR] MAC check failed for AES-CCM key ...   →  ERROR_USE_KEY
   [ERROR] Unable to get the VMK (error 0x800c0006). Abort.
   ```
   即：**元数据已能完整解析，失败原因变成了「提供凭据解不出密钥」** —— 这才是真正的密码问题。
3. **回归样本卷**：把 BitCracker 加密镜像盘（`disk24s1`）锁定后用其真实密码
   `test/test-bitlocker.sh --device disk24s1 --password-file ...` **端到端 29 项全绿**
   （list → unlock → 读写 → 写入读回 → 卸载 → 重新锁定 → lock 后 list 为 locked → 安全弹出）。

## 六、盘结构差异与后续排查要点（本轮附带发现，供下轮参考）

| 项 | 样本卷（可解锁） | 用户 U 盘 |
|---|---|---|
| 卷头 signature | `-FVE-FS-` | `-FVE-FS-` |
| encryption 算法 | AES-128 **NODIFFUSER** | AES-**XTS**-128（dislocker `encommon.c` 已支持 `AES_XTS_128`） |
| user-password 保护器所在 VMK range | 0x2000 | 0x2000（VMK#1） |
| VMK#1 内层 stretch key 算法 | 0x1001 | 0x1001（同） |
| recovery 保护器 VMK range | 0x0800 | 0x0800（VMK#2） |
| 未知 datum | 无 | 有（entry 46 / value 37） |

结论：**密码派生路径（salt 长度、stretch 算法 0x1001、AES-CCM nonce、VMK解密序列）与样本卷完全一致**，
说明「用户密码 9999999 解不出」就是**凭据本身不匹配**，不是算法/结构差异。

> 注：`MAC check failed` 与 `ERROR_USE_KEY` 说明 dislocker 确实用该密码派生出了密钥并尝试了 AES-CCM 校验，
> 校验失败即密钥错。可用 `ntfsctl unlock ... --verbose` 复现该日志。

## 七、遗留与建议

- U 盘若用用户密码解不开，请依次尝试：**48 位恢复密码**（`--recovery`）、**Windows 导出的 .BEK**
  （`--bek`，可在另一台 Windows 管理界面「管理 BitLocker → 备份恢复密钥」导出），
  或到 <https://aka.ms/myrecoverykey> 用 Microsoft 账号查回该盘的恢复密钥。
- 该卷还观察到 `Sector per cluster: 0x00`（样本为 0x08），属 Windows 10 1903+ 的 exFAT/BitLocker To Go 特征；
  dislocker 源码头文件对该字段缺失已有兜底（读块设备最小扇区），不影响本次解锁。
- 建议下轮：把「未知 datum 跳过」+「info/dump/--verbose 诊断三件套」纳入 known-issues 与安装脚本注释。
