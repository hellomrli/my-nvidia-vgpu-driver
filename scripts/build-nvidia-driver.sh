#!/usr/bin/env bash
# =============================================================================
# build-nvidia-driver.sh - cloud build of the MERGED NVIDIA vGPU driver for
# Unraid, packaged as a Slackware .txz installable on the server.
#
# Pipeline:
#   1. merge-driver.sh  -> merged source tree (grid base + vgpu components,
#                          VGX_KVM_BUILD + GRID_BUILD)
#   2. build            -> 6 kernel modules against the ich777 Unraid kernel
#   3. package          -> assemble pkg/ (userspace + modules + config) -> .txz
#
# Inputs:
#   GRID_RUN_URL / VGPU_RUN_URL  official NVIDIA .run files (or present in DL_DIR)
#   KERNEL_ARCHIVE_URL           ich777 Unraid kernel tree
# Output:
#   out/nvidia-<ver>-<kernel>-Unraid-<build>.txz (+ .md5)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- config (overridable via environment) ----------
VERSION="${VERSION:-535.309.01}"
# alist vGPU branch directory for this driver version (535.309.01 == 16.14)
ALIST_VGPU_BRANCH="${ALIST_VGPU_BRANCH:-16.14}"
TARGET_KERNEL_VERSION="${TARGET_KERNEL_VERSION:-6.18.44}"
KERNEL_RELEASE="${KERNEL_RELEASE:-${TARGET_KERNEL_VERSION}-Unraid}"
JOBS="${JOBS:-$(nproc --all)}"
PACKAGE_BUILD="${PACKAGE_BUILD:-1}"
KERNEL_ARCHIVE_URL="${KERNEL_ARCHIVE_URL:-https://github.com/ich777/unraid_kernel/releases/download/${KERNEL_RELEASE}/linux-${KERNEL_RELEASE}.tar.xz}"
KERNEL_ARCHIVE_SHA256="${KERNEL_ARCHIVE_SHA256:-}"
# Official NVIDIA .run files are mirrored on the alist vGPU share:
#   https://alist.homelabproject.cc/foxipan/vGPU/<branch>/
# The merged driver needs BOTH the grid (standard Linux) and the vgpu-kvm
# package; they are the base and the vGPU component source respectively.
ALIST_BASE="${ALIST_BASE:-https://alist.homelabproject.cc/d/foxipan/vGPU/${ALIST_VGPU_BRANCH}/NVIDIA-GRID-Linux-KVM-${VERSION}-539.72}"
GRID_RUN_URL="${GRID_RUN_URL:-${ALIST_BASE}/Guest_Drivers/NVIDIA-Linux-x86_64-${VERSION}-grid.run}"
VGPU_RUN_URL="${VGPU_RUN_URL:-${ALIST_BASE}/Host_Drivers/NVIDIA-Linux-x86_64-${VERSION}-vgpu-kvm.run}"
CC="${CC:-gcc}"
HOSTCC="${HOSTCC:-$CC}"
CXX="${CXX:-g++}"
HOSTCXX="${HOSTCXX:-$CXX}"
export CC HOSTCC CXX HOSTCXX

DL_DIR="${DL_DIR:-$ROOT_DIR/downloads}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
KERNEL_DIR="$BUILD_DIR/linux-${TARGET_KERNEL_VERSION}"
MERGED_DIR="$BUILD_DIR/merged-${VERSION}"

mkdir -p "$DL_DIR" "$BUILD_DIR" "$OUT_DIR"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

kmake() {
  make -C "$KERNEL_DIR" CC="$CC" HOSTCC="$HOSTCC" CXX="$CXX" HOSTCXX="$HOSTCXX" "$@"
}

# ---------- 1. merged source tree ----------
# make sure the two official .run files are present (alist mirror by default)
need_cmd curl
GRID_RUN="$DL_DIR/grid-${VERSION}.run"
VGPU_RUN="$DL_DIR/vgpu-kvm-${VERSION}.run"
if [ ! -s "$GRID_RUN" ]; then
  log "Downloading grid driver from alist mirror"
  curl -L --fail --retry 3 --retry-delay 2 -o "$GRID_RUN.tmp" "$GRID_RUN_URL"
  mv "$GRID_RUN.tmp" "$GRID_RUN"
fi
if [ ! -s "$VGPU_RUN" ]; then
  log "Downloading vgpu-kvm driver from alist mirror"
  curl -L --fail --retry 3 --retry-delay 2 -o "$VGPU_RUN.tmp" "$VGPU_RUN_URL"
  mv "$VGPU_RUN.tmp" "$VGPU_RUN"
fi
if [ ! -d "$MERGED_DIR/kernel" ]; then
  log "Building merged driver source tree"
  DL_DIR="$DL_DIR" OUT_DIR="$BUILD_DIR" VERSION="$VERSION" \
    "$ROOT_DIR/scripts/merge-driver.sh"
fi
[ -d "$MERGED_DIR/kernel" ] || die "Merged tree missing"

# ---------- 2. kernel tree ----------
need_cmd curl
need_cmd tar
KERNEL_ARCHIVE="$DL_DIR/linux-${KERNEL_RELEASE}.tar.xz"
if [ ! -s "$KERNEL_ARCHIVE" ]; then
  log "Downloading ich777 kernel tree ${KERNEL_RELEASE}"
  curl -L --fail --retry 3 --retry-delay 2 -o "$KERNEL_ARCHIVE.tmp" "$KERNEL_ARCHIVE_URL"
  mv "$KERNEL_ARCHIVE.tmp" "$KERNEL_ARCHIVE"
fi
if [ -n "$KERNEL_ARCHIVE_SHA256" ]; then
  echo "$KERNEL_ARCHIVE_SHA256  $KERNEL_ARCHIVE" | sha256sum -c - >/dev/null || die "Kernel archive checksum mismatch"
fi
if [ ! -s "$KERNEL_DIR/.config" ] || [ ! -s "$KERNEL_DIR/Module.symvers" ]; then
  log "Extracting kernel tree"
  mkdir -p "$KERNEL_DIR"
  tar -xf "$KERNEL_ARCHIVE" -C "$KERNEL_DIR"
fi
[ -s "$KERNEL_DIR/.config" ] || die "Kernel tree missing .config"
[ -s "$KERNEL_DIR/Module.symvers" ] || die "Kernel tree missing Module.symvers"

# ---------- 3. build the 6 modules ----------
log "Building NVIDIA modules against ${KERNEL_RELEASE} (CC=$CC, JOBS=$JOBS)"
need_cmd make
make -C "$MERGED_DIR/kernel" SYSSRC="$KERNEL_DIR" SYSOUT="$KERNEL_DIR" -j"$JOBS" \
  2>&1 | tee "$OUT_DIR/build-nvidia.log"

MODULES="nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem nvidia-vgpu-vfio"
for m in $MODULES; do
  [ -s "$MERGED_DIR/kernel/$m.ko" ] || die "Missing built module: $m.ko"
done
vermagic="$(modinfo -F vermagic "$MERGED_DIR/kernel/nvidia.ko" 2>/dev/null | head -1)"
log "nvidia vermagic: $vermagic"
[ "$(echo "$vermagic" | xargs)" = "$(echo "$KERNEL_RELEASE SMP preempt mod_unload" | xargs)" ] || die "Vermagic mismatch: got '$vermagic'"

# ---------- 4. assemble the package ----------
PKG_NAME="nvidia-${VERSION}-${KERNEL_RELEASE}-${PACKAGE_BUILD}"
STAGE="$BUILD_DIR/stage-$PKG_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

log "Assembling package files"
# --- modules ---
MOD_DEST="$STAGE/lib/modules/${KERNEL_RELEASE}/kernel/drivers/video"
mkdir -p "$MOD_DEST"
for m in $MODULES; do
  cp "$MERGED_DIR/kernel/$m.ko" "$MOD_DEST/"
done

# --- userspace: copy the .run extraction of the merged tree (== grid) ---
# the merged tree contains everything the grid run file had; copy the whole
# tree, then overlay the vgpu daemons/libs, then strip build artifacts.
cp -a "$MERGED_DIR"/. "$STAGE/"
rm -rf "$STAGE/kernel" "$STAGE/kernel-open" "$STAGE/html" "$STAGE/firmware"
rm -f  "$STAGE/README.txt" "$STAGE/LICENSE" "$STAGE/GRID_LICENSE" \
       "$STAGE/MERGED_INFO.txt" "$STAGE/makeself.sh" "$STAGE/makeself-help-script.sh" \
       "$STAGE/nvidia-installer" "$STAGE/nvidia-installer.1.gz" "$STAGE/install*" \
       "$STAGE/.build" 2>/dev/null || true

# move user binaries into usr/bin (Unraid layout)
mkdir -p "$STAGE/usr/bin"
for b in nvidia-smi nvidia-modprobe nvidia-debugdump nvidia-vgpud nvidia-vgpu-mgr \
         nvidia-xid-logd sriov-manage nvidia-cuda-mps-control nvidia-cuda-mps-server; do
  [ -e "$STAGE/$b" ] && mv -f "$STAGE/$b" "$STAGE/usr/bin/"
done

# libraries into usr/lib64
mkdir -p "$STAGE/usr/lib64"
for l in "$STAGE"/libnvidia-*.so* "$STAGE"/libcuda.so* "$STAGE"/libGL*.so* \
         "$STAGE"/libEGL*.so* "$STAGE"/libGLES*.so* "$STAGE"/libOpen*.so* \
         "$STAGE"/libnvcuvid.so* "$STAGE"/libnvoptix.so* "$STAGE"/libvdpau*.so* \
         "$STAGE"/libglvnd*; do
  [ -e "$l" ] && mv -f "$l" "$STAGE/usr/lib64/" 2>/dev/null || true
done
find "$STAGE" -maxdepth 1 -name "*.so*" -exec mv -f {} "$STAGE/usr/lib64/" \; 2>/dev/null || true

# vgpu shared libs also under usr/lib/nvidia (mgr/vgpu look here)
mkdir -p "$STAGE/usr/lib/nvidia"
cp -a "$MERGED_DIR/libnvidia-vgpu.so.$VERSION" "$STAGE/usr/lib/nvidia/" 2>/dev/null || true
cp -a "$MERGED_DIR/libnvidia-vgxcfg.so.$VERSION" "$STAGE/usr/lib/nvidia/" 2>/dev/null || true

# --- config files (managed by the plugin) ---
mkdir -p "$STAGE/etc/nvidia" "$STAGE/etc/vgpu_unlock" "$STAGE/etc/glvnd/egl_vendor.d" \
         "$STAGE/etc/vulkan/icd.d" "$STAGE/usr/share/nvidia/vgpu" \
         "$STAGE/usr/share/glvnd/egl_vendor.d" "$STAGE/usr/share/vulkan/icd.d" \
         "$STAGE/usr/share/OpenCL/vendors"

# vgpuConfig.xml (the authoritative one for nvidia-vgpud)
if [ -f "$MERGED_DIR/vgpuConfig.xml" ]; then
  cp -a "$MERGED_DIR/vgpuConfig.xml" "$STAGE/usr/share/nvidia/vgpu/vgpuConfig.xml"
  cp -a "$MERGED_DIR/vgpuConfig.xml" "$STAGE/etc/vgpuConfig.xml"
else
  log "WARNING: vgpuConfig.xml not found in merged tree"
fi
# license + unlock templates
cp -a "$MERGED_DIR/GRID_LICENSE" "$STAGE/etc/nvidia/gridd.conf.template" 2>/dev/null || \
  printf '# unraid-vgpu generated at runtime\n' > "$STAGE/etc/nvidia/gridd.conf.template"
: > "$STAGE/etc/vgpu_unlock/profile_override.toml.new"
cp -a "$MERGED_DIR/10_nvidia.json" "$STAGE/etc/glvnd/egl_vendor.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/10_nvidia_wayland.json" "$STAGE/etc/glvnd/egl_vendor.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/15_nvidia_gbm.json" "$STAGE/etc/glvnd/egl_vendor.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/nvidia_icd.json" "$STAGE/etc/vulkan/icd.d/" 2>/dev/null || true

# --- install scripts ---
mkdir -p "$STAGE/install"
cat > "$STAGE/install/doinst.sh" <<'EOF'
#!/bin/sh
config() {
  NEW="$1"; OLD="$(dirname $NEW)/$(basename $NEW .new)"
  if [ ! -r "$OLD" ]; then
    mv "$NEW" "$OLD"
  elif [ "$(cat $OLD | md5sum)" = "$(cat $NEW | md5sum)" ]; then
    rm "$NEW"
  fi
}
config etc/nvidia/gridd.conf.new 2>/dev/null
config etc/vgpu_unlock/profile_override.toml.new 2>/dev/null
if [ -x /sbin/depmod ]; then
  /sbin/depmod -a 2>/dev/null
fi
EOF
chmod +x "$STAGE/install/doinst.sh"

cat > "$STAGE/install/slack-desc" <<EOF
nvidia: NVIDIA vGPU (Merged) driver for Unraid
nvidia:
nvidia: MERGED driver: vGPU (VM passthrough) + standard NVIDIA driver
nvidia: (host docker/CUDA/OpenGL) in one package.
nvidia:
nvidia: version: $VERSION
nvidia: kernel:  $KERNEL_RELEASE
nvidia:
EOF

# ---------- 5. package .txz ----------
log "Packaging ${PKG_NAME}.txz"
tar -cJf "$OUT_DIR/${PKG_NAME}.txz" --owner=root --group=root -C "$STAGE" .
md5sum "$OUT_DIR/${PKG_NAME}.txz" > "$OUT_DIR/${PKG_NAME}.txz.md5"

{
  echo "driver:  $VERSION"
  echo "kernel:  $KERNEL_RELEASE"
  echo "vermagic: $vermagic"
} > "$OUT_DIR/nvidia-installed-modules.txt"

log "DONE: $OUT_DIR/${PKG_NAME}.txz ($(du -h "$OUT_DIR/${PKG_NAME}.txz" | cut -f1))"
