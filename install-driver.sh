#!/bin/bash
# install-driver.sh — 安装 NTFS 读写驱动（FUSE-T + macos-fuse-t/ntfs-3g 源码构建）
# 适用于 macOS 26 (Tahoe) / Apple Silicon / FUSE-T（无内核扩展）
# 可重复运行：已装好会跳过对应步骤
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NTFS_3G=/usr/local/bin/ntfs-3g
FUSE_T_LIB=/usr/local/lib/libfuse-t.dylib
FUSE_T_SERVER="/Library/Application Support/fuse-t/bin"
BUILD_DIR=/tmp/ntfs-3g-fuse-t-build

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] 错误: %s\n' "$*" >&2; exit 1; }

SELF="$ROOT/$(basename "$0")"

# ---------- 特权段：免密执行（绝不弹授权框） ----------
# 背景：原先两处用 osascript「with administrator privileges」弹管理员授权框，用户要求免密化。
# 做法：把真正需要 root 的两步（installer 装 pkg、make install）拆成「特权子命令」，
# 非 root 时以 sudoers 白名单身份免密重入本脚本执行：
#     <owner> ALL=(ALL) NOPASSWD: /bin/bash <SRC_DIR>/install-driver.sh*
# 白名单由 scripts/install-service.sh 写入（该脚本本身已免密，所以更新白名单也不弹窗）。
# 为什么不整脚本重入 root：脚本里的 brew 步骤不能以 root 运行（Homebrew 明确拒绝 root），
# 构建产物也应归属用户，真正需要 root 的只有最后的安装动作。
as_root_np() {
  if [ "$(id -u)" = "0" ]; then "$@"; else sudo -n "$@"; fi
}

# 特权子命令分发（由免密重入调用；已是 root 时也可直接调用）
priv_dispatch() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    pkg)
      [ -n "${1:-}" ] || die "特权子命令 pkg 缺少包路径"
      log "安装 FUSE-T pkg: $1"
      /usr/sbin/installer -pkg "$1" -target / || die "FUSE-T pkg 安装失败"
      ;;
    make-install)
      [ -n "${1:-}" ] || die "特权子命令 make-install 缺少构建目录"
      [ -d "$1" ] || die "构建目录不存在: $1"
      log "make install（ntfs-3g）: $1"
      ( cd "$1" && make install ) || die "make install 失败"
      ;;
    *) die "未知特权子命令: ${sub:-（空）}" ;;
  esac
}

# 免密重入入口：必须放在「环境检查」之前 —— 重入时 root 的 PATH 里通常没有 brew，
# 若先跑环境检查会被误判为缺 Homebrew 而失败。
if [ "${1:-}" = "--priv" ]; then
  shift
  priv_dispatch "$@"
  exit 0
fi

# 免密执行特权步骤；免密不可用时明确失败（绝不转入交互认证，避免弹 Touch ID / 密码框）
priv() {
  as_root_np /bin/bash "$SELF" --priv "$@" \
    || die "特权步骤失败；若提示需要密码，请先运行 scripts/install-service.sh 写入 sudoers 白名单"
}

# ---------- 环境检查 ----------
[ "$(uname -m)" = "arm64" ] || die "仅支持 Apple Silicon"
MAJ=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJ" -ge 26 ] || die "需要 macOS 26+"
command -v brew >/dev/null || die "需要 Homebrew"
command -v git >/dev/null || die "需要 git"

# ---------- FUSE-T 就绪检查（已装 1.0.49 则跳过） ----------
if [ ! -f "$FUSE_T_LIB" ] || [ ! -d "$FUSE_T_SERVER" ]; then
  log "未检测到 FUSE-T，尝试 brew 安装..."
  brew install --cask macos-fuse-t/homebrew-cask/fuse-t || true
  if [ ! -f "$FUSE_T_LIB" ] || [ ! -d "$FUSE_T_SERVER" ]; then
    PKG=$(ls -t /opt/homebrew/Caskroom/fuse-t/*/*.pkg 2>/dev/null | head -1)
    [ -n "$PKG" ] || PKG=$(ls -t /usr/local/Caskroom/fuse-t/*/*.pkg 2>/dev/null | head -1)
    [ -n "$PKG" ] || die "FUSE-T 安装失败：库与 pkg 均未找到，请手动下载 https://github.com/macos-fuse-t/fuse-t/releases 安装"
    log "手动安装 FUSE-T pkg: ${PKG}（免密提权，不弹授权框）"
    priv pkg "$PKG"
  fi
fi
log "FUSE-T OK: $(ls "$FUSE_T_SERVER"/go-nfsv4-* 2>/dev/null | tail -1)"

# ---------- 构建依赖 ----------
# 注意：macOS 自带 /usr/bin/libtool（Apple 工具），GNU libtool 是 glibtoolize，不能只查 libtool
for p in autoconf automake glibtoolize pkg-config libgcrypt; do
  command -v "$p" >/dev/null 2>&1 || { log "安装 ${p#gl} ..."; brew install "${p#gl}" || die "brew install ${p#gl} 失败"; }
done

# ---------- 构建 ntfs-3g（macos-fuse-t fork，链接 libfuse-t） ----------
if [ ! -x "$NTFS_3G" ] || ! otool -L "$NTFS_3G" 2>/dev/null | grep -q libfuse-t; then
  log "克隆并构建 macos-fuse-t/ntfs-3g ..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g.git "$BUILD_DIR" || die "clone 失败"
  (
    cd "$BUILD_DIR" || die "无法进入 $BUILD_DIR"
    export CPPFLAGS="-I/usr/local/include/fuse"
    export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig"
    if [ -x ./autogen.sh ]; then
      ./autogen.sh || {
        # 已知问题：autoreconf 因 LT_INIT 宏缺失失败（ltmain.sh 未生成）。
        # 先跑 libtoolize，再把可能生成到上级目录的 ltmain.sh 复制回来重跑。
        log "autogen.sh 失败，尝试 glibtoolize + autoreconf -fi ..."
        glibtoolize --force --copy || true
        [ -f ../ltmain.sh ] && cp ../ltmain.sh ./ltmain.sh
        autoreconf -fi || die "autoreconf 失败"
      }
    else
      autoreconf -fi || die "autoreconf 失败"
    fi
    ./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin || die "configure 失败"
    make -j"$(sysctl -n hw.ncpu)" || die "make 失败"
  ) || exit 1
  log "make install（免密提权，不弹授权框）..."
  priv make-install "$BUILD_DIR"
fi

# ---------- 构建 dislocker（BitLocker 解锁/读写，v0.7.3 + FUSE-T 适配） ----------
# dislocker 把 BitLocker 卷解密为一个虚拟文件（<容器目录>/dislocker-file），再交给 ntfs-3g 挂载。
# 必须用 tag v0.7.3：它用 FUSE_USE_VERSION=26，兼容 FUSE-T 的 FUSE 2.9 API；
# master 需要 FUSE 3.14，与 FUSE-T 不兼容。
# 构建产物仅暂存到项目 build/dislocker，由 install-service.sh（root，免密白名单）安装到
# /usr/local/{bin,lib}，这样整条链路不新增任何授权框。
DISLOCKER_BUILD=/tmp/dislocker-build
DISLOCKER_SRC="$DISLOCKER_BUILD/dislocker"
DISLOCKER_STAGE="$ROOT/build/dislocker"

dislocker_staged_ok() {
  [ -x "$DISLOCKER_STAGE/dislocker-fuse" ] && [ -e "$DISLOCKER_STAGE/libdislocker.0.7.dylib" ]
}

if dislocker_staged_ok; then
  log "dislocker 已构建过，跳过（暂存于 $DISLOCKER_STAGE）"
else
  log "构建 dislocker v0.7.3（FUSE-T 适配）..."
  command -v cmake >/dev/null 2>&1 || brew install cmake || die "安装 cmake 失败"
  brew list --formula 2>/dev/null | grep -q '^mbedtls@3$' || brew install mbedtls@3 || die "安装 mbedtls@3 失败"
  MBEDTLS3_PREFIX=$(brew --prefix mbedtls@3)
  # mbedTLS 3 的头文件位于 include/mbedtls/ 下（FindPolarSSL 会把 INC_FOLDER 解析为 mbedtls）
  [ -f "$MBEDTLS3_PREFIX/include/mbedtls/mbedtls_config.h" ] || die "mbedtls@3 头文件缺失: $MBEDTLS3_PREFIX"

  rm -rf "$DISLOCKER_BUILD"
  mkdir -p "$DISLOCKER_BUILD"
  git clone --depth 1 --branch v0.7.3 https://github.com/Aorimn/dislocker.git "$DISLOCKER_SRC" \
    || die "clone dislocker 失败"

  # 四个补丁：mbedTLS 3 兼容 + 链接 libfuse-t + 无条件用 FUSE-T 的 <fuse.h> + 未知 datum 跳过
  python3 - "$DISLOCKER_SRC" <<'PYEOF' || die "dislocker 源码补丁失败"
import io, os, sys
src = sys.argv[1]

def patch(path, old, new):
    p = os.path.join(src, path)
    with io.open(p, encoding='utf-8') as fh:
        t = fh.read()
    # 先判断锚点：锚点还在就替换；锚点已消失且新串已在 => 已打过补丁
    if old in t:
        with io.open(p, 'w', encoding='utf-8') as fh:
            fh.write(t.replace(old, new, 1))
        print('  [ok] %s' % path)
    elif new in t:
        print('  [skip] %s 已修改' % path)
    else:
        raise SystemExit('  [fail] %s 未找到锚点' % path)

# 1) mbedTLS 3 兼容（上游 commit 2cfbba2）
patch('include/dislocker/ssl_bindings.h.in',
      '#include "@POLARSSL_INC_FOLDER@/config.h"\n#include "@POLARSSL_INC_FOLDER@/version.h"\n',
      '#include "@POLARSSL_INC_FOLDER@/version.h"\n'
      '#if MBEDTLS_VERSION_MAJOR >= 3\n'
      '#include "@POLARSSL_INC_FOLDER@/mbedtls_config.h"\n'
      '#include "@POLARSSL_INC_FOLDER@/compat-2.x.h"\n'
      '#else\n'
      '#include "@POLARSSL_INC_FOLDER@/config.h"\n'
      '#endif\n')
# 2) 链接 libfuse-t（原为 osxfuse_i64/macFUSE）
patch('src/CMakeLists.txt', 'set (FUSE_LIB osxfuse_i64)', 'set (FUSE_LIB fuse-t)')
# 3) 无条件包含 <fuse.h>（FUSE-T 头文件在 /usr/local/include/fuse）
patch('src/dislocker-fuse.c',
      '#ifdef __DARWIN\n# include <osxfuse/fuse.h>\n#else\n# include <fuse.h>\n#endif /* __DARWIN */',
      '# include <fuse.h>')

# 4) 未知 value_type 的 datum 不再中断遍历
#    部分新式 Windows 卷的数据集里存在 value_type 超出本版本已知表
#    (> NB_DATUMS_VALUE_TYPES) 的 datum（实测 Windows 写入 entry_type=46 / value_type=37）。
#    get_header_safe() 对未知 value_type 返回 FALSE，原代码据此直接 break，
#    会使位于其后的关键 datum —— FVEK(entry 3) 与 VIRTUALIZATION_INFO(value 15)
#    永远读不到，最终在启动时报 "Unable to compute regions. Abort."（与密码对错无关）。
#    改为：只要 datum_size 结构合法（>=8）就按声明大小跳过并继续遍历。
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
PYEOF

  # 注意：cmake 4.x 拒绝 cmake_minimum_required(<3.5)，用策略下限绕过
  cmake -S "$DISLOCKER_SRC" -B "$DISLOCKER_SRC/build-mac" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DFUSE_INCLUDE_DIRS=/usr/local/include/fuse \
    -DFUSE_LIBRARIES=/usr/local/lib/libfuse-t.dylib \
    -DPOLARSSL_INCLUDE_DIRS="$MBEDTLS3_PREFIX/include" \
    -DPOLARSSL_LIBRARIES="$MBEDTLS3_PREFIX/lib/libmbedcrypto.dylib" \
    -DCMAKE_DISABLE_FIND_PACKAGE_Ruby=TRUE || die "dislocker cmake 配置失败"
  make -C "$DISLOCKER_SRC/build-mac" -j"$(sysctl -n hw.ncpu)" || die "dislocker 编译失败"

  rm -rf "$DISLOCKER_STAGE"; mkdir -p "$DISLOCKER_STAGE"
  cp "$DISLOCKER_SRC/build-mac/src"/dislocker-* "$DISLOCKER_STAGE/"
  cp -R "$DISLOCKER_SRC/build-mac/src"/libdislocker* "$DISLOCKER_STAGE/"
  otool -L "$DISLOCKER_STAGE/dislocker-fuse" | grep -q libfuse-t || die "dislocker-fuse 未链接 libfuse-t"
  log "dislocker 构建完成，暂存于 $DISLOCKER_STAGE"
fi

# ---------- 卸载 gromgit 同名公式（避免 PATH 优先位链到 macFUSE 版） ----------
if brew list --formula 2>/dev/null | grep -q 'ntfs-3g-mac'; then
  log "卸载 gromgit/fuse/ntfs-3g-mac（同名二进制冲突）..."
  brew uninstall ntfs-3g-mac || log "卸载 ntfs-3g-mac 失败，请手动处理"
fi

# ---------- 验证 ----------
log "验证安装结果："
"$NTFS_3G" --version >/dev/null 2>&1 || die "ntfs-3g 未安装成功"
otool -L "$NTFS_3G" | grep -q libfuse-t || die "ntfs-3g 未链接 libfuse-t（可能错误链到 macFUSE）"
/usr/local/bin/mkntfs --version >/dev/null 2>&1 || die "mkntfs 缺失"
log "驱动安装验证通过 ✔  $($NTFS_3G --version 2>&1 | head -1)"

cat <<'EOF'
提示：请手动授权一次「完全磁盘访问」，否则挂载会报 Operation not permitted：
  系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加：
    1. /usr/local/bin/ntfs-3g
    2. /bin/bash
  （若已在列表中则无需重复添加）
EOF
