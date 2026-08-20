#!/bin/bash
# =============================================================================
# rebuild-driver.sh - 用 MERGED DRIVER 源为指定 Unraid 内核重新编译驱动
#
# 用途: Unraid 内核升级后（例如 6.18.44 → 6.18.45），无需重新合并驱动，
#       只需用本脚本 + 保留的 merged driver 源重新编译即可。
#
# 前置条件:
#   1. merged driver 源目录（本仓库上级或 --merged 参数指定）
#      即从 NVIDIA-Linux-x86_64-535.309.01-merged-vgpu-kvm.run 解包的目录
#   2. 目标 Unraid 内核源码（从 ich777/unraid_kernel Releases 下载，
#      或 /usr/src/linux 指向的内核树），需已 modules_prepare
#   3. 编译机需要: make, gcc, 内核头文件工具
#
# 用法:
#   ./rebuild-driver.sh --kernel /path/to/kernel-6.18.45-Unraid \
#                       --merged /path/to/merged-535.309.01 \
#                       [--out /path/to/output]
#
# 输出:
#   <out>/lib/modules/<kernel>/kernel/drivers/video/*.ko  (6 个模块)
#   <out>/nvidia-<版本>-<内核>-Unraid-1.txz (可选 --package)
# =============================================================================
set -e

KERNEL_DIR=""
MERGED_DIR=""
OUT_DIR="$(pwd)/output"
MAKE_PKG=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "选项:"
  echo "  --kernel <dir>    Unraid 内核源码目录（必需）"
  echo "  --merged <dir>    merged driver 源目录（默认: ./merged-535.309.01）"
  echo "  --out <dir>       输出目录（默认: ./output）"
  echo "  --package         同时打包成 .txz"
  echo "  -h, --help        显示帮助"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL_DIR="$2"; shift 2 ;;
    --merged) MERGED_DIR="$2"; shift 2 ;;
    --out)    OUT_DIR="$2"; shift 2 ;;
    --package) MAKE_PKG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

[ -n "$KERNEL_DIR" ] || { echo "错误: 缺少 --kernel 参数"; usage; exit 1; }
[ -d "$KERNEL_DIR" ] || { echo "错误: 内核目录不存在: $KERNEL_DIR"; exit 1; }
[ -d "$MERGED_DIR" ] || { echo "错误: merged 源目录不存在: $MERGED_DIR（可用 --merged 指定）"; exit 1; }

# 内核版本从 Makefile 读取
KERNEL_REL="$(grep -E '^VERSION|^PATCHLEVEL|^SUBLEVEL' "$KERNEL_DIR/Makefile" | awk '{print $3}' | paste -sd. -)"
LOCALVER="$(grep '^CONFIG_LOCALVERSION=' "$KERNEL_DIR/.config" 2>/dev/null | cut -d'"' -f2)"
FULL_REL="${KERNEL_REL}${LOCALVER}"
echo "=============================================="
echo " 目标内核: $FULL_REL"
echo " 内核目录: $KERNEL_DIR"
echo " merged源: $MERGED_DIR"
echo " 输出目录: $OUT_DIR"
echo "=============================================="

# 检查路径不能有空格（NVIDIA Makefile 限制）
case "$KERNEL_DIR" in *" "*) echo "错误: 内核路径不能包含空格"; exit 1;; esac
case "$MERGED_DIR" in *" "*) echo "错误: merged 路径不能包含空格"; exit 1;; esac

# 内核树需要 modules_prepare（生成 Module.symvers 等）
if [ ! -f "$KERNEL_DIR/Module.symvers" ]; then
  echo ">>> 执行 modules_prepare..."
  make -C "$KERNEL_DIR" modules_prepare
fi

# 编译
echo ">>> 编译 NVIDIA 模块 (j$(nproc))..."
make -C "$MERGED_DIR/kernel" SYSSRC="$KERNEL_DIR" SYSOUT="$KERNEL_DIR" -j"$(nproc)"

# 收集模块
mkdir -p "$OUT_DIR/lib/modules/$FULL_REL/kernel/drivers/video"
MODULES="nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem nvidia-vgpu-vfio"
for m in $MODULES; do
  if [ -f "$MERGED_DIR/kernel/$m.ko" ]; then
    cp -v "$MERGED_DIR/kernel/$m.ko" "$OUT_DIR/lib/modules/$FULL_REL/kernel/drivers/video/"
  else
    echo "警告: 模块 $m.ko 未生成"
  fi
done

echo
echo ">>> 验证 vermagic:"
for m in nvidia nvidia-vgpu-vfio; do
  modinfo "$OUT_DIR/lib/modules/$FULL_REL/kernel/drivers/video/$m.ko" | grep -E "vermagic|version"
done

# 可选: 打包 .txz（只打包模块，用户空间文件用 release 里的完整包）
if [ "$MAKE_PKG" = "1" ]; then
  PKG_NAME="nvidia-mods-$FULL_REL-1.txz"
  echo ">>> 打包模块: $PKG_NAME"
  tar -cJf "$OUT_DIR/$PKG_NAME" --owner=root --group=root -C "$OUT_DIR" lib
  md5sum "$OUT_DIR/$PKG_NAME" | tee "$OUT_DIR/$PKG_NAME.md5"
  echo ">>> 模块包: $OUT_DIR/$PKG_NAME"
fi

echo
echo "完成! 模块在: $OUT_DIR/lib/modules/$FULL_REL/kernel/drivers/video/"
echo "提示: 在 Unraid 上执行 depmod -a 后 modprobe nvidia 即可加载"
