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
    log "手动安装 FUSE-T pkg: ${PKG}（请在弹出的授权框中确认）"
    osascript -e "do shell script \"installer -pkg '$PKG' -target /\" with administrator privileges" || die "FUSE-T pkg 安装失败"
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
  log "make install（请在弹出的授权框中确认管理员密码）..."
  osascript -e "do shell script \"cd '$BUILD_DIR' && make install 2>&1\" with administrator privileges" || die "make install 失败"
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

  # 三个补丁：mbedTLS 3 兼容 + 链接 libfuse-t + 无条件用 FUSE-T 的 <fuse.h>
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
