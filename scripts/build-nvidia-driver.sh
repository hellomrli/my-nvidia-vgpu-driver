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
# --- kernel modules ---
MOD_DEST="$STAGE/lib/modules/${KERNEL_RELEASE}/kernel/drivers/video"
mkdir -p "$MOD_DEST"
for m in $MODULES; do
  cp "$MERGED_DIR/kernel/$m.ko" "$MOD_DEST/"
done

# --- container toolkit (open-source; committed to the repo tools/ dir) ---
# The official .run files come from the alist mirror above; the container
# toolkit lives in this repository so Releases stay clean (driver only).
CTK_TAR="$ROOT_DIR/tools/nvidia-container-toolkit.tar.gz"
LNC_TAR="$ROOT_DIR/tools/libnvidia-container.tar.gz"
[ -s "$CTK_TAR" ] || die "Missing $CTK_TAR (committed to the repo tools/ dir)"
[ -s "$LNC_TAR" ] || die "Missing $LNC_TAR (committed to the repo tools/ dir)"
tar -xzf "$CTK_TAR" -C "$STAGE"
tar -xzf "$LNC_TAR" -C "$STAGE"

# --- mdevctl (mediated device management; prebuilt, committed to tools/) ---
# Unraid has no mdevctl package, so ship it with the driver. It needs three
# dirs to self-check: /etc/mdevctl.d and both scripts.d subdirs.
MDEVCTL_BIN="$ROOT_DIR/tools/mdevctl"
[ -s "$MDEVCTL_BIN" ] || die "Missing $MDEVCTL_BIN (committed to the repo tools/ dir)"
mkdir -p "$STAGE/usr/bin"
cp -a "$MDEVCTL_BIN" "$STAGE/usr/bin/mdevctl"
chmod 755 "$STAGE/usr/bin/mdevctl"
mkdir -p "$STAGE/etc/mdevctl.d" \
         "$STAGE/usr/lib/mdevctl/scripts.d/callouts" \
         "$STAGE/usr/lib/mdevctl/scripts.d/notifiers"

# --- NVIDIA userspace from the merged tree (== grid base + vgpu overlay) ---
# binaries -> usr/bin
mkdir -p "$STAGE/usr/bin"
for b in nvidia-smi nvidia-modprobe nvidia-debugdump nvidia-gridd nvidia-persistenced \
         nvidia-settings nvidia-xconfig nvidia-cuda-mps-control nvidia-cuda-mps-server \
         nvidia-vgpud nvidia-vgpu-mgr nvidia-xid-logd sriov-manage; do
  [ -e "$MERGED_DIR/$b" ] && cp -a "$MERGED_DIR/$b" "$STAGE/usr/bin/"
done

# shared libraries -> usr/lib64 (versioned real files, no symlinks yet)
mkdir -p "$STAGE/usr/lib64"
cp -a "$MERGED_DIR"/lib*.so* "$STAGE/usr/lib64/" 2>/dev/null || true

# vgpu shared libs also under usr/lib/nvidia (mgr/vgpud look here)
mkdir -p "$STAGE/usr/lib/nvidia"
cp -a "$MERGED_DIR"/libnvidia-vgpu.so.${VERSION} "$STAGE/usr/lib/nvidia/" 2>/dev/null || true
cp -a "$MERGED_DIR"/libnvidia-vgxcfg.so.${VERSION} "$STAGE/usr/lib/nvidia/" 2>/dev/null || true

# X11 driver module
mkdir -p "$STAGE/usr/lib64/xorg/modules/drivers" "$STAGE/usr/lib64/xorg/modules/extensions"
[ -e "$MERGED_DIR/nvidia_drv.so" ] && cp -a "$MERGED_DIR/nvidia_drv.so" "$STAGE/usr/lib64/xorg/modules/drivers/"

# GSP firmware (grid tree keeps them at firmware/*.bin)
if ls "$MERGED_DIR"/firmware/gsp_*.bin >/dev/null 2>&1; then
  mkdir -p "$STAGE/lib/firmware/nvidia"
  cp -a "$MERGED_DIR"/firmware/gsp_*.bin "$STAGE/lib/firmware/nvidia/"
fi

# soname symlinks (layout validated against the released package)
liblink() { ln -sfn "$2" "$STAGE/usr/lib64/$1"; }
liblink libcuda.so                    libcuda.so.${VERSION}
liblink libcuda.so.1                  libcuda.so.${VERSION}
liblink libEGL.so                     libEGL.so.${VERSION}
liblink libEGL.so.1                   libEGL.so.${VERSION}
liblink libGL.so                      libGL.so.1.7.0
liblink libGL.so.1                    libGL.so.1.7.0
liblink libnvcuvid.so                 libnvcuvid.so.${VERSION}
liblink libnvcuvid.so.1               libnvcuvid.so.${VERSION}
liblink libnvidia-cfg.so              libnvidia-cfg.so.${VERSION}
liblink libnvidia-cfg.so.1            libnvidia-cfg.so.${VERSION}
liblink libnvidia-eglcore.so.1        libnvidia-eglcore.so.${VERSION}
liblink libnvidia-encode.so           libnvidia-encode.so.${VERSION}
liblink libnvidia-encode.so.1         libnvidia-encode.so.${VERSION}
liblink libnvidia-fbc.so              libnvidia-fbc.so.${VERSION}
liblink libnvidia-fbc.so.1            libnvidia-fbc.so.${VERSION}
liblink libnvidia-glcore.so.1         libnvidia-glcore.so.${VERSION}
liblink libnvidia-glsi.so.1           libnvidia-glsi.so.${VERSION}
liblink libnvidia-ml.so               libnvidia-ml.so.${VERSION}
liblink libnvidia-ml.so.1             libnvidia-ml.so.${VERSION}
liblink libnvidia-nvvm.so.1           libnvidia-nvvm.so.${VERSION}
liblink libnvidia-opencl.so           libnvidia-opencl.so.${VERSION}
liblink libnvidia-opencl.so.1         libnvidia-opencl.so.${VERSION}
liblink libnvidia-ptxjitcompiler.so   libnvidia-ptxjitcompiler.so.${VERSION}
liblink libnvidia-ptxjitcompiler.so.1 libnvidia-ptxjitcompiler.so.${VERSION}
liblink libnvidia-rtcore.so.1         libnvidia-rtcore.so.${VERSION}
liblink libnvidia-tls.so.1            libnvidia-tls.so.${VERSION}
liblink libnvidia-vgpu.so             libnvidia-vgpu.so.${VERSION}
liblink libnvidia-vgxcfg.so           libnvidia-vgxcfg.so.${VERSION}
liblink libnvidia-vulkan-producer.so.1 libnvidia-vulkan-producer.so.${VERSION}
liblink libOpenCL.so.1                libOpenCL.so.1.0.0
ln -sfn libnvidia-vgpu.so.${VERSION}  "$STAGE/usr/lib/nvidia/libnvidia-vgpu.so"
ln -sfn libnvidia-vgxcfg.so.${VERSION} "$STAGE/usr/lib/nvidia/libnvidia-vgxcfg.so"

# --- config files ---
mkdir -p "$STAGE/etc/nvidia" "$STAGE/etc/vgpu_unlock" "$STAGE/etc/glvnd/egl_vendor.d" \
         "$STAGE/etc/vulkan/icd.d" "$STAGE/usr/share/nvidia/vgpu" \
         "$STAGE/usr/share/glvnd/egl_vendor.d" "$STAGE/usr/share/vulkan/icd.d" \
         "$STAGE/usr/share/OpenCL/vendors"

# vgpuConfig.xml (the authoritative one for nvidia-vgpud)
if [ -f "$MERGED_DIR/vgpuConfig.xml" ]; then
  cp -a "$MERGED_DIR/vgpuConfig.xml" "$STAGE/usr/share/nvidia/vgpu/vgpuConfig.xml"
  cp -a "$MERGED_DIR/vgpuConfig.xml" "$STAGE/etc/vgpuConfig.xml"
  cp -a "$MERGED_DIR/vgpuConfig.xml" "$STAGE/usr/share/nvidia/vgpuConfig.xml"
else
  log "WARNING: vgpuConfig.xml not found in merged tree"
fi
# license template (+ .new copy kept via doinst.sh config())
if [ -f "$MERGED_DIR/gridd.conf.template" ]; then
  cp -a "$MERGED_DIR/gridd.conf.template" "$STAGE/etc/nvidia/gridd.conf.template"
  cp -a "$MERGED_DIR/gridd.conf.template" "$STAGE/etc/nvidia/gridd.conf.new"
else
  printf '# unraid-vgpu generated at runtime\n' > "$STAGE/etc/nvidia/gridd.conf.template"
  cp -a "$STAGE/etc/nvidia/gridd.conf.template" "$STAGE/etc/nvidia/gridd.conf.new"
fi
: > "$STAGE/etc/vgpu_unlock/profile_override.toml.new"
cp -a "$MERGED_DIR/10_nvidia.json"   "$STAGE/etc/glvnd/egl_vendor.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/10_nvidia.json"   "$STAGE/usr/share/glvnd/egl_vendor.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/nvidia_icd.json"  "$STAGE/etc/vulkan/icd.d/" 2>/dev/null || true
cp -a "$MERGED_DIR/nvidia_icd.json"  "$STAGE/usr/share/vulkan/icd.d/" 2>/dev/null || true
printf 'libnvidia-opencl.so.1\n' > "$STAGE/etc/nvidia.icd"
printf 'libnvidia-opencl.so.1\n' > "$STAGE/usr/share/OpenCL/vendors/nvidia.icd"

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
