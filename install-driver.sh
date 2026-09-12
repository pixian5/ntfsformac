#!/bin/bash
# install-driver.sh — 安装 NTFS 读写驱动（FUSE-T + macos-fuse-t/ntfs-3g 源码构建）
# 适用于 macOS 26 (Tahoe) / Apple Silicon / FUSE-T（无内核扩展）
# 可重复运行：已装好会跳过对应步骤
set -uo pipefail

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
