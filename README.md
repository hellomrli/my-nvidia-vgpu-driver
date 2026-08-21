# my-vgpu-driver

NVIDIA vGPU (**Merged**) driver for **Unraid**, built from the official NVIDIA
Linux driver packages and packaged as a Slackware `.txz` that installs
directly on an Unraid server.

Used together with the [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager)
plugin, which downloads this package, installs it and manages vGPU devices
(mdev) for VM passthrough.

## The MERGED driver

A single package that provides **both**:

| purpose                     | components                                                                 |
|-----------------------------|----------------------------------------------------------------------------|
| **vGPU for VMs**            | `nvidia-vgpu-vfio.ko`, `nvidia-vgpud`, `nvidia-vgpu-mgr`, `vgpuConfig.xml`, `libnvidia-vgpu.so`, `libnvidia-vgxcfg.so` |
| **Host GPU (docker/CUDA/GL)** | `nvidia.ko`, `nvidia-uvm/modeset/drm/peermem`, `libcuda`, OpenGL/OpenCL/Vulkan userspace |

The source tree is created by `scripts/merge-driver.sh`:

- **grid** package (standard Linux driver) is the base
- **vgpu-kvm** package contributes the vGPU kernel driver + userspace
- both `VGX_KVM_BUILD=1` and `GRID_BUILD=1` are defined in `conftest.sh`, so a
  single build produces both module sets

For 535.309.01 the `nv-kernel.o_binary` is byte-identical between the grid
and vgpu-kvm packages; only the conftest flags differ.

## What this produces

```
out/nvidia-<version>-<kernel>-Unraid-<build>.txz   (+ .md5)
```

Six kernel modules for the target Unraid kernel plus the full userspace
(libraries, binaries, vgpuConfig.xml, license template, install scripts).

## Cloud build (GitHub Actions)

`.github/workflows/build-nvidia.yml` runs `scripts/build-nvidia-driver.sh`
(merge -> build -> package):

- **manual**: run the *Build NVIDIA vGPU driver* workflow, choose the driver
  version, Unraid kernel release and package build number
- requires `GRID_RUN_URL` / `VGPU_RUN_URL` (official NVIDIA .run files) or
  the files already present in `downloads/`

The package is attached to a Release whose tag equals the kernel release
(e.g. `6.18.44-Unraid`).

## Local build

```bash
# 1. merge (needs grid-<ver>.run + vgpu-kvm-<ver>.run in downloads/)
./scripts/merge-driver.sh --version 535.309.01

# 2. build + package (needs a Linux box with gcc/make/curl/tar/xz)
KERNEL_RELEASE=6.18.44-Unraid VERSION=535.309.01 \
GRID_RUN_URL=... VGPU_RUN_URL=... \
./scripts/build-nvidia-driver.sh
```

## Rebuilding for a new Unraid kernel

`build/rebuild-driver.sh` recompiles the merged source against a new kernel
source tree without re-merging:

```bash
./build/rebuild-driver.sh --kernel /path/to/kernel-6.18.45-Unraid \
                          --merged /path/to/merged-535.309.01 --package
```

## Releases

Current build: **535.309.01** for **6.18.44-Unraid** (tag `6.18.44-Unraid`).
