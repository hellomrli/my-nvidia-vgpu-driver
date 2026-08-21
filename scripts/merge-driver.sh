#!/usr/bin/env bash
# =============================================================================
# merge-driver.sh - build a MERGED NVIDIA vGPU driver source tree for Unraid.
#
# The MERGED driver combines:
#   * the GRID/standard Linux driver  (nvidia.ko, nvidia-uvm/modeset/drm,
#     libcuda, OpenGL/OpenCL/Vulkan userspace -> host docker/CUDA)
#   * the vGPU components             (nvidia-vgpu-vfio.ko, nvidia-vgpud,
#     nvidia-vgpu-mgr, vgpuConfig.xml, libnvidia-vgpu.so, libnvidia-vgxcfg.so
#     -> VM vGPU passthrough)
#
# In 535.309.01 the nv-kernel.o_binary is byte-identical between the two
# packages; only the conftest flags differ. The merged tree defines BOTH
# VGX_KVM_BUILD and GRID_BUILD so a single module set serves both uses.
#
# Usage:
#   ./merge-driver.sh [--version 535.309.01] [--out <dir>] [--no-download]
#
# Inputs (expects the official .run files in $DL_DIR, or GRID_RUN_URL /
# VGPU_RUN_URL set to downloadable locations):
#   <dl>/grid-<ver>.run      NVIDIA Linux driver (standard/grid)
#   <dl>/vgpu-kvm-<ver>.run  NVIDIA vGPU (KVM) driver
# Output:
#   <out>/merged-<ver>/      the merged source tree (kernel/ ready to build)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-535.309.01}"
DL_DIR="${DL_DIR:-$ROOT_DIR/downloads}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out-merged}"

GRID_RUN_URL="${GRID_RUN_URL:-}"
VGPU_RUN_URL="${VGPU_RUN_URL:-}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

mkdir -p "$DL_DIR" "$OUT_DIR"
GRID_RUN="$DL_DIR/grid-$VERSION.run"
VGPU_RUN="$DL_DIR/vgpu-kvm-$VERSION.run"
MERGED_DIR="$OUT_DIR/merged-$VERSION"

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# ---------- 1. obtain the two official .run files ----------
if [ ! -s "$GRID_RUN" ]; then
  [ -n "$GRID_RUN_URL" ] || die "Missing $GRID_RUN - set GRID_RUN_URL or place the file in $DL_DIR"
  log "Downloading grid driver $VERSION"
  curl -L --fail --retry 3 -o "$GRID_RUN" "$GRID_RUN_URL"
fi
if [ ! -s "$VGPU_RUN" ]; then
  [ -n "$VGPU_RUN_URL" ] || die "Missing $VGPU_RUN - set VGPU_RUN_URL or place the file in $DL_DIR"
  log "Downloading vgpu-kvm driver $VERSION"
  curl -L --fail --retry 3 -o "$VGPU_RUN" "$VGPU_RUN_URL"
fi

# ---------- 2. extract both ----------
log "Extracting packages"
rm -rf "$OUT_DIR/tmp"
mkdir -p "$OUT_DIR/tmp"
extract_run() {
  local run="$1" name="$2"
  rm -rf "$OUT_DIR/tmp/$name"
  (cd "$OUT_DIR/tmp" && sh "$run" --extract-only --target "$name" >/dev/null 2>&1) || \
  (cd "$OUT_DIR/tmp" && sh "$run" --target "$name" >/dev/null 2>&1) || true
  [ -f "$OUT_DIR/tmp/$name/kernel/Makefile" ] || die "Failed to extract $run"
}
extract_run "$GRID_RUN" grid
extract_run "$VGPU_RUN" vgpu-kvm
GRID_X="$OUT_DIR/tmp/grid"
VGPU_X="$OUT_DIR/tmp/vgpu-kvm"

# ---------- 3. merge: grid is the base, add vgpu components ----------
log "Merging (grid base + vgpu components)"
rm -rf "$MERGED_DIR"
cp -a "$GRID_X" "$MERGED_DIR"
chmod -R u+w "$MERGED_DIR" 2>/dev/null || true

# kernel: add the vgpu-vfio driver sources + interface files from vgpu-kvm
cp -a "$VGPU_X/kernel/nvidia-vgpu-vfio" "$MERGED_DIR/kernel/"
cp -a "$VGPU_X/kernel/nvidia/nv-vgpu-vfio-interface.c" "$MERGED_DIR/kernel/nvidia/"
cp -a "$VGPU_X/kernel/common/inc/nv-vgpu-vfio-interface.h" "$MERGED_DIR/kernel/common/inc/"

# userspace vGPU binaries + daemons + config from vgpu-kvm
for f in nvidia-vgpud nvidia-vgpu-mgr nvidia-vgxcfg libnvidia-vgpu.so.$VERSION \
         libnvidia-vgxcfg.so.$VERSION nvidia-xid-logd sriov-manage vgpuConfig.xml; do
  [ -e "$VGPU_X/$f" ] && cp -a "$VGPU_X/$f" "$MERGED_DIR/"
done
[ -d "$VGPU_X/systemd" ] && cp -a "$VGPU_X/systemd" "$MERGED_DIR/"
[ -d "$VGPU_X/init-scripts" ] && cp -a "$VGPU_X/init-scripts" "$MERGED_DIR/"

# ---------- 4. enable BOTH vGPU and GRID builds in conftest ----------
log "Enabling VGX_KVM_BUILD + GRID_BUILD in conftest"
CONFTEST="$MERGED_DIR/kernel/conftest.sh"
[ -f "$CONFTEST" ] || die "Missing kernel/conftest.sh in merged tree"

if grep -q '^VGX_KVM_BUILD=' "$CONFTEST"; then
  sed -i 's/^VGX_KVM_BUILD=.*/VGX_KVM_BUILD=1/' "$CONFTEST"
else
  sed -i '1i VGX_KVM_BUILD=1' "$CONFTEST"
fi
if grep -q '^GRID_BUILD=' "$CONFTEST"; then
  sed -i 's/^GRID_BUILD=.*/GRID_BUILD=1/' "$CONFTEST"
else
  sed -i '1i GRID_BUILD=1' "$CONFTEST"
fi

# include the vgpu-vfio module in the kernel module set
MAKEFILE="$MERGED_DIR/kernel/Makefile"
if ! grep -q 'nvidia-vgpu-vfio' "$MAKEFILE"; then
  sed -i 's/NV_KERNEL_MODULES ?= $(wildcard nvidia nvidia-uvm/NV_KERNEL_MODULES ?= $(wildcard nvidia nvidia-uvm nvidia-vgpu-vfio/' "$MAKEFILE"
fi

# compile the vgpu-vfio interface into nvidia.ko (as the vgpu-kvm build does)
KBUILD="$MERGED_DIR/kernel/nvidia/nvidia-sources.Kbuild"
if [ -f "$KBUILD" ] && ! grep -q 'nv-vgpu-vfio-interface.c' "$KBUILD"; then
  sed -i '/NVIDIA_SOURCES += nvidia\/nv-frontend.c/i NVIDIA_SOURCES += nvidia/nv-vgpu-vfio-interface.c' "$KBUILD"
fi

log "Merged tree ready: $MERGED_DIR"
du -sh "$MERGED_DIR"
