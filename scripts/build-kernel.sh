#!/bin/bash
# Build a SukiSU + KPM + SUSFS kernel for Xiaomi 14 (houji) from a pure ACK tree.
#
# Layout assumed (adjust AOSP/ACK/SRC to match your checkout):
#
#   ACK/                     git clone of kernel/common @ 0c3d559bcd85
#   ACK/common/              the actual kernel tree
#   stock-kernel.config      config extracted from the stock boot image
#   out/                     build output
#
# Usage:  ./build-kernel.sh
set -euo pipefail

ACK=${ACK:-/path/to/common}
SRC=$ACK/common
CFG=${CFG:-$PWD/stock-kernel.config}
OUT=${OUT:-$PWD/out}
JOBS=${JOBS:-$(nproc)}

SUSFS_REPO=${SUSFS_REPO:-https://github.com/ShirkNeko/susfs4ksu.git}
SUSFS_BRANCH=${SUSFS_BRANCH:-gki-android14-6.1}
SUSFS_PATCH=50_add_susfs_in_gki-android14-6.1.patch

KSU_REPO=${KSU_REPO:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}
KSU_BRANCH=${KSU_BRANCH:-builtin}   # builtin 分支原生带 SUSFS

# --- 0. 前置检查 -------------------------------------------------------------
# SukiSU 的版本号由 GitHub API 计算；没有 curl 会退化成 13000
if ! command -v curl >/dev/null; then
  echo "!! 缺少 curl：SukiSU 版本号会退化成 13000（apt-get install -y curl）" >&2
fi

# --- 1. 驱动：换成 SukiSU builtin 分支 ---------------------------------------
if [ ! -d "$SRC/drivers/kernelsu" ] || [ ! -f "$SRC/drivers/kernelsu/Kconfig" ]; then
  echo "== clone SukiSU ($KSU_BRANCH) =="
  rm -rf SukiSU-Ultra
  git clone --depth 1 -b "$KSU_BRANCH" "$KSU_REPO" SukiSU-Ultra
  rm -rf "$SRC/drivers/kernelsu"
  cp -R SukiSU-Ultra/kernel "$SRC/drivers/kernelsu"
fi

grep -q 'drivers/kernelsu/Kconfig' "$SRC/drivers/Kconfig" || \
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$SRC/drivers/Kconfig"
grep -q 'kernelsu' "$SRC/drivers/Makefile" || \
  printf 'obj-$(CONFIG_KSU) += kernelsu/\n' >> "$SRC/drivers/Makefile"

echo "== KSU_SUSFS options in driver Kconfig: $(grep -c KSU_SUSFS "$SRC/drivers/kernelsu/Kconfig")"

# --- 2. 内核侧 SUSFS 补丁（只打一次） ----------------------------------------
if [ ! -f "$SRC/fs/susfs.c" ]; then
  echo "== clone susfs4ksu ($SUSFS_BRANCH) =="
  rm -rf susfs4ksu
  git clone --depth 1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu

  cp susfs4ksu/kernel_patches/fs/*            "$SRC/fs/"
  cp susfs4ksu/kernel_patches/include/linux/* "$SRC/include/linux/"
  ( cd "$SRC" && patch -p1 -F3 < "$OLDPWD/susfs4ksu/kernel_patches/$SUSFS_PATCH" )
fi

# --- 3. fs/exec.c 需要的 post-execveat 钩子（builtin 驱动没有） --------------
SUCOMPAT=$SRC/drivers/kernelsu/feature/sucompat.c
if ! grep -q 'ksu_handle_post_execveat_sucompat' "$SUCOMPAT"; then
  echo "== add ksu_handle_post_execveat_sucompat stub =="
  cat >> "$SUCOMPAT" <<'EOF'

#ifdef CONFIG_KSU_SUSFS
int ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv,
                                      void *envp, int *flags, int *retval)
{
    return 0;
}
#endif
EOF
fi

# --- 4. 配置 -----------------------------------------------------------------
mkdir -p "$OUT"
cp "$CFG" "$OUT/.config"

python3 - "$OUT/.config" <<'PY'
import re, sys
p = sys.argv[1]
lines = [l for l in open(p).read().splitlines()
         if not l.startswith(("CONFIG_KSU", "# CONFIG_KSU",
                              "CONFIG_KPM", "# CONFIG_KPM"))]
lines = [l for l in lines if not l.startswith("CONFIG_MODULE_SIG_PROTECT")]
lines += [
    "# CONFIG_MODULE_SIG_PROTECT is not set",   # 成败关键
    "CONFIG_KSU=y",
    "CONFIG_KPM=y",
    "CONFIG_KSU_SUSFS=y",
    "CONFIG_KSU_SUSFS_SUS_MAP=y",
    "CONFIG_KSU_SUSFS_SUS_MOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y",
    "CONFIG_KSU_SUSFS_SUS_KSTAT=y",
    "CONFIG_KSU_SUSFS_TRY_UMOUNT=y",
    "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y",
    "CONFIG_KSU_SUSFS_SPOOF_UNAME=y",
    "CONFIG_KSU_SUSFS_ENABLE_LOG=y",
    "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y",
    "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y",
    "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y",
]
open(p, "w").write("\n".join(lines) + "\n")
PY

# --- 5. 编译 ----------------------------------------------------------------
cd "$SRC"
make O="$OUT" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

echo "== resolved config =="
grep -E '^CONFIG_(KSU|KPM|KSU_SUSFS)=' "$OUT/.config" | head
grep -E '^# CONFIG_MODULE_SIG_PROTECT' "$OUT/.config" || true

make O="$OUT" ARCH=arm64 LLVM=1 LOCALVERSION= -j"$JOBS" Image

echo "== result =="
strings "$OUT/arch/arm64/boot/Image" | grep -m1 'Linux version'
ls -l "$OUT/arch/arm64/boot/Image"
