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
# vGPU host driver version == VERSION. Some branches ship a grid guest driver
# with a DIFFERENT version than the vgpu-kvm host driver (e.g. 19.6:
# vgpu-kvm 580.178.05, grid 580.178.04); GRID_VERSION covers that.
GRID_VERSION="${GRID_VERSION:-${VERSION}}"
# alist vGPU branch directory for this driver version (535.309.01 == 16.14)
ALIST_VGPU_BRANCH="${ALIST_VGPU_BRANCH:-16.14}"
# Windows driver version embedded in the alist directory name
# (NVIDIA-GRID-Linux-KVM-<VERSION>-<ALIST_WINVER>)
ALIST_WINVER="${ALIST_WINVER:-539.72}"
# Explicit package dir name for 3-number layouts, e.g. 19.6 ships
# NVIDIA-GRID-Linux-KVM-580.178.05-580.178.04-582.78 (host-grid-windows).
# When set it also derives GRID_VERSION if not given.
ALIST_PKG_DIR="${ALIST_PKG_DIR:-}"
if [ -n "$ALIST_PKG_DIR" ] && [ "$GRID_VERSION" = "$VERSION" ]; then
  g="$(printf '%s' "$ALIST_PKG_DIR" | sed -nE 's/^NVIDIA-GRID-Linux-KVM-[0-9.]+-([0-9.]+)-[0-9.]+$/\1/p')"
  [ -n "$g" ] && GRID_VERSION="$g"
fi
TARGET_KERNEL_VERSION="${TARGET_KERNEL_VERSION:-6.18.44}"
KERNEL_RELEASE="${KERNEL_RELEASE:-${TARGET_KERNEL_VERSION}-Unraid}"
JOBS="${JOBS:-$(nproc --all)}"
PACKAGE_BUILD="${PACKAGE_BUILD:-1}"
KERNEL_ARCHIVE_URL="${KERNEL_ARCHIVE_URL:-https://github.com/ich777/unraid_kernel/releases/download/${KERNEL_RELEASE}/linux-${KERNEL_RELEASE}.tar.xz}"
# Per-release SHA256 of the ich777 kernel archive (an archive hash is only
# valid for its own kernel!). Unknown releases fall back to no check (a
# warning is logged) so the daily auto-build for new kernels keeps working.
case "${KERNEL_RELEASE}" in
  6.18.44-Unraid) DEFAULT_KERNEL_SHA256="618df8d001e9f98b95306eb2eac4cb776d0bf4b98061f0f4cedbc10c1468858d" ;;
  6.18.45-Unraid) DEFAULT_KERNEL_SHA256="365dee16bbd9c505d36a0d0a1a2bc63723f8a8d55b2f7c7991d806a4c849df7b" ;;
  6.18.46-Unraid) DEFAULT_KERNEL_SHA256="e8969f6a5d31106ae5ebf821ba128e043dcda78bc5f1f1a6344a8e46c9c9e280" ;;
  6.18.47-Unraid) DEFAULT_KERNEL_SHA256="72822aea43a7d6dab3ae7a8489481a583504896927c1ce7117df8ab1b46d173f" ;;
  *)              DEFAULT_KERNEL_SHA256="" ;;
esac
KERNEL_ARCHIVE_SHA256="${KERNEL_ARCHIVE_SHA256:-${DEFAULT_KERNEL_SHA256}}"
# Pinned SHA256 of the official .run files (supply-chain check). The hash is
# per driver version; unknown versions fall back to no check (logged).
case "${VERSION}" in
  535.309.01)
    DEFAULT_GRID_RUN_SHA256="a5fa966d2de4953b4e7cb8016064bc23a8f9a0cd23f56e10cd122a785426d5ff"
    DEFAULT_VGPU_RUN_SHA256="04a60a8436324e0edea6ebcf428b3c04e31c1146d80a2b2712c5f36aa705e053" ;;
  580.178.05)
    DEFAULT_GRID_RUN_SHA256="6513b2bd6431b502ce686c6f546b1947b7577107a6132cebb80fb08a9540263f"
    DEFAULT_VGPU_RUN_SHA256="c084ebcb98b2d166309da3b59c64ab0db5df0418eb602e4b51c65939276e526d" ;;
  *) DEFAULT_GRID_RUN_SHA256=""; DEFAULT_VGPU_RUN_SHA256="" ;;
esac
GRID_RUN_SHA256="${GRID_RUN_SHA256:-${DEFAULT_GRID_RUN_SHA256}}"
VGPU_RUN_SHA256="${VGPU_RUN_SHA256:-${DEFAULT_VGPU_RUN_SHA256}}"
# Official NVIDIA .run files are mirrored on the alist vGPU share:
#   https://alist.homelabproject.cc/foxipan/vGPU/<branch>/
# The merged driver needs BOTH the grid (standard Linux) and the vgpu-kvm
# package; they are the base and the vGPU component source respectively.
if [ -n "$ALIST_PKG_DIR" ]; then
  ALIST_BASE="${ALIST_BASE:-https://alist.homelabproject.cc/d/foxipan/vGPU/${ALIST_VGPU_BRANCH}/${ALIST_PKG_DIR}}"
else
  ALIST_BASE="${ALIST_BASE:-https://alist.homelabproject.cc/d/foxipan/vGPU/${ALIST_VGPU_BRANCH}/NVIDIA-GRID-Linux-KVM-${VERSION}-${ALIST_WINVER}}"
fi
GRID_RUN_URL="${GRID_RUN_URL:-${ALIST_BASE}/Guest_Drivers/NVIDIA-Linux-x86_64-${GRID_VERSION}-grid.run}"
VGPU_RUN_URL="${VGPU_RUN_URL:-${ALIST_BASE}/Host_Drivers/NVIDIA-Linux-x86_64-${VERSION}-vgpu-kvm.run}"
CC="${CC:-gcc}"
HOSTCC="${HOSTCC:-$CC}"
CXX="${CXX:-g++}"
HOSTCXX="${HOSTCXX:-$CXX}"
export CC HOSTCC CXX HOSTCXX
# vgpu_unlock kernel patch hooks the 535.x vGPU config magic; the magic values
# are not adapted to other branches, so "auto" applies it only on 535.x.
# Force with UNLOCK_PATCH=1/0.
UNLOCK_PATCH="${UNLOCK_PATCH:-auto}"
case "$UNLOCK_PATCH" in
  auto) if [ "${VERSION%%.*}" = "535" ]; then UNLOCK_PATCH=1; else UNLOCK_PATCH=0; fi ;;
  1|0) ;;
  *) die "UNLOCK_PATCH must be auto, 1 or 0" ;;
esac

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
GRID_RUN="$DL_DIR/grid-${GRID_VERSION}.run"
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
# verify the .run files against the pinned SHA256 (supply-chain check)
if [ -n "$GRID_RUN_SHA256" ]; then
  echo "$GRID_RUN_SHA256  $GRID_RUN" | sha256sum -c - >/dev/null \
    || die "grid .run SHA256 mismatch - override GRID_RUN_SHA256 when building a different version"
else
  log "WARNING: no pinned SHA256 for grid ${GRID_VERSION} - set GRID_RUN_SHA256 to enforce"
fi
if [ -n "$VGPU_RUN_SHA256" ]; then
  echo "$VGPU_RUN_SHA256  $VGPU_RUN" | sha256sum -c - >/dev/null \
    || die "vgpu-kvm .run SHA256 mismatch - override VGPU_RUN_SHA256 when building a different version"
else
  log "WARNING: no pinned SHA256 for vgpu-kvm ${VERSION} - set VGPU_RUN_SHA256 to enforce"
fi
if [ ! -d "$MERGED_DIR/kernel" ]; then
  log "Building merged driver source tree"
  DL_DIR="$DL_DIR" OUT_DIR="$BUILD_DIR" VERSION="$VERSION" GRID_VERSION="$GRID_VERSION" \
    "$ROOT_DIR/scripts/merge-driver.sh"
fi
[ -d "$MERGED_DIR/kernel" ] || die "Merged tree missing"

# ---------- 1b. vgpu_unlock kernel patch (consumer GPU unlock) ----------
# The LD_PRELOAD lib (libvgpu_unlock_rs.so) is only the userspace half. The
# kernel half hooks nv-kernel.o: vgpu_unlock_hooks.c is #included into
# os-interface.c and kern.ld relocates nv-kernel.o's .rodata into .data so the
# hook can rewrite the vGPU config magic at runtime. Both files are committed
# to tools/vgpu_unlock/ (hooks.c carries the 535.x magic adaptation).
if [ "$UNLOCK_PATCH" = "1" ]; then
UNLOCK_HOOKS_C="$ROOT_DIR/tools/vgpu_unlock/vgpu_unlock_hooks.c"
UNLOCK_KERN_LD="$ROOT_DIR/tools/vgpu_unlock/kern.ld"
[ -s "$UNLOCK_HOOKS_C" ] || die "Missing $UNLOCK_HOOKS_C (committed to the repo tools/vgpu_unlock/ dir)"
[ -s "$UNLOCK_KERN_LD" ] || die "Missing $UNLOCK_KERN_LD (committed to the repo tools/vgpu_unlock/ dir)"

mkdir -p "$MERGED_DIR/kernel/unlock"
cp -a "$UNLOCK_HOOKS_C" "$MERGED_DIR/kernel/unlock/vgpu_unlock_hooks.c"
cp -a "$UNLOCK_KERN_LD" "$MERGED_DIR/kernel/nvidia/kern.ld"

OS_IFACE="$MERGED_DIR/kernel/nvidia/os-interface.c"
[ -f "$OS_IFACE" ] || die "Missing kernel/nvidia/os-interface.c in merged tree"
if grep -q 'vgpu_unlock_hooks.c' "$OS_IFACE"; then
  log "vgpu_unlock hooks already included in os-interface.c"
elif grep -q 'nv-time.h' "$OS_IFACE"; then
  sed -i 's:^\(#include "nv-time\.h"\):\1\n#include "../unlock/vgpu_unlock_hooks.c":' "$OS_IFACE"
else
  # fallback: insert right after the first #include line
  sed -i '0,/^#include/s//#include "..\/unlock\/vgpu_unlock_hooks.c"\n&/' "$OS_IFACE"
fi
grep -q 'vgpu_unlock_hooks.c' "$OS_IFACE" || die "Failed to include vgpu_unlock_hooks.c in os-interface.c"

KBUILD_MAIN="$MERGED_DIR/kernel/nvidia/nvidia.Kbuild"
[ -f "$KBUILD_MAIN" ] || die "Missing kernel/nvidia/nvidia.Kbuild in merged tree"
if ! grep -q 'kern.ld' "$KBUILD_MAIN"; then
  printf 'ldflags-y += -T $(src)/nvidia/kern.ld\n' >> "$KBUILD_MAIN"
fi
log "vgpu_unlock kernel patch applied"
else
  log "Skipping the vgpu_unlock kernel patch (not adapted to driver ${VERSION}; native vGPU cards do not need it)"
fi

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
# verify all committed tools binaries against the manifest
( cd "$ROOT_DIR/tools" && sha256sum -c --quiet SHA256SUMS ) \
  || die "tools/SHA256SUMS verification failed - update the manifest when replacing a tools binary"
# exclude=etc/docker: the tarballs must never carry a daemon.json - it would
# overwrite the user's Docker config on install (runtime config is done by
# nvidia-ctk / rc.vgpu instead)
tar -xzf "$CTK_TAR" -C "$STAGE" --exclude='./etc/docker'
tar -xzf "$LNC_TAR" -C "$STAGE" --exclude='./etc/docker'

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

# --- vgpu_unlock-rs (userspace LD_PRELOAD hook for consumer GPU unlock) ---
# Prebuilt with cargo 1.97 / glibc 2.43 (matches Unraid); committed to tools/.
# rc.vgpu loads it via LD_PRELOAD when the unlock setting is enabled.
UNLOCK_LIB="$ROOT_DIR/tools/libvgpu_unlock_rs.so"
[ -s "$UNLOCK_LIB" ] || die "Missing $UNLOCK_LIB (committed to the repo tools/ dir)"
mkdir -p "$STAGE/usr/local/lib"
cp -a "$UNLOCK_LIB" "$STAGE/usr/local/lib/libvgpu_unlock_rs.so"
chmod 755 "$STAGE/usr/local/lib/libvgpu_unlock_rs.so"

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

# soname symlinks (layout validated against the released package).
# Grid-derived libraries carry GRID_VERSION, vgpu-specific ones VERSION
# (they differ on branches like 19.x: 580.178.04 vs 580.178.05).
# liblink skips (with a warning) when the target file does not exist so a
# hard-coded soname cannot produce dangling links with a different driver ver.
liblink() {
  if [ -e "$STAGE/usr/lib64/$2" ]; then
    ln -sfn "$2" "$STAGE/usr/lib64/$1"
  else
    log "WARNING: soname link $1 -> $2 skipped (target missing in merged tree)"
  fi
}
liblink libcuda.so                    libcuda.so.${GRID_VERSION}
liblink libcuda.so.1                  libcuda.so.${GRID_VERSION}
liblink libEGL.so                     libEGL.so.${GRID_VERSION}
liblink libEGL.so.1                   libEGL.so.${GRID_VERSION}
LIBGL_REAL="$(cd "$STAGE/usr/lib64" 2>/dev/null && ls libGL.so.1.* 2>/dev/null | sort -V | tail -1)"
if [ -n "$LIBGL_REAL" ]; then
  liblink libGL.so                    "$LIBGL_REAL"
  liblink libGL.so.1                  "$LIBGL_REAL"
else
  log "WARNING: libGL.so.1.* not found in merged tree - skipping libGL soname links"
fi
liblink libnvcuvid.so                 libnvcuvid.so.${GRID_VERSION}
liblink libnvcuvid.so.1               libnvcuvid.so.${GRID_VERSION}
liblink libnvidia-cfg.so              libnvidia-cfg.so.${GRID_VERSION}
liblink libnvidia-cfg.so.1            libnvidia-cfg.so.${GRID_VERSION}
liblink libnvidia-eglcore.so.1        libnvidia-eglcore.so.${GRID_VERSION}
liblink libnvidia-encode.so           libnvidia-encode.so.${GRID_VERSION}
liblink libnvidia-encode.so.1         libnvidia-encode.so.${GRID_VERSION}
liblink libnvidia-fbc.so              libnvidia-fbc.so.${GRID_VERSION}
liblink libnvidia-fbc.so.1            libnvidia-fbc.so.${GRID_VERSION}
liblink libnvidia-glcore.so.1         libnvidia-glcore.so.${GRID_VERSION}
liblink libnvidia-glsi.so.1           libnvidia-glsi.so.${GRID_VERSION}
liblink libnvidia-ml.so               libnvidia-ml.so.${GRID_VERSION}
liblink libnvidia-ml.so.1             libnvidia-ml.so.${GRID_VERSION}
liblink libnvidia-nvvm.so.1           libnvidia-nvvm.so.${GRID_VERSION}
liblink libnvidia-opencl.so           libnvidia-opencl.so.${GRID_VERSION}
liblink libnvidia-opencl.so.1         libnvidia-opencl.so.${GRID_VERSION}
liblink libnvidia-ptxjitcompiler.so   libnvidia-ptxjitcompiler.so.${GRID_VERSION}
liblink libnvidia-ptxjitcompiler.so.1 libnvidia-ptxjitcompiler.so.${GRID_VERSION}
liblink libnvidia-rtcore.so.1         libnvidia-rtcore.so.${GRID_VERSION}
liblink libnvidia-tls.so.1            libnvidia-tls.so.${GRID_VERSION}
liblink libnvidia-vgpu.so             libnvidia-vgpu.so.${VERSION}
liblink libnvidia-vgxcfg.so           libnvidia-vgxcfg.so.${VERSION}
liblink libnvidia-vulkan-producer.so.1 libnvidia-vulkan-producer.so.${GRID_VERSION}
liblink libOpenCL.so.1                libOpenCL.so.1.0.0
[ -e "$STAGE/usr/lib/nvidia/libnvidia-vgpu.so.${VERSION}" ] && \
  ln -sfn libnvidia-vgpu.so.${VERSION} "$STAGE/usr/lib/nvidia/libnvidia-vgpu.so"
[ -e "$STAGE/usr/lib/nvidia/libnvidia-vgxcfg.so.${VERSION}" ] && \
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
# basename-only .md5 (an absolute path here breaks `md5sum -c` outside CI)
( cd "$OUT_DIR" && md5sum "${PKG_NAME}.txz" > "${PKG_NAME}.txz.md5" )

{
  echo "driver:  $VERSION"
  echo "kernel:  $KERNEL_RELEASE"
  echo "vermagic: $vermagic"
} > "$OUT_DIR/nvidia-installed-modules.txt"

log "DONE: $OUT_DIR/${PKG_NAME}.txz ($(du -h "$OUT_DIR/${PKG_NAME}.txz" | cut -f1))"
