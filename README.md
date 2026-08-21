# my-nvidia-vgpu-driver

为 **Unraid** 编译的 **NVIDIA vGPU（Merged）驱动**，基于 NVIDIA 官方 Linux 驱动包构建，打包为可直接安装到 Unraid 服务器的 Slackware `.txz` 格式。

配合 [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager) 插件使用——插件负责下载本包、安装并管理 vGPU 设备（mdev）供虚拟机直通。

## 什么是 Merged 驱动？

一个包同时提供**两种能力**：

| 用途 | 组件 |
|------|------|
| **vGPU 虚拟机直通** | `nvidia-vgpu-vfio.ko`、`nvidia-vgpud`、`nvidia-vgpu-mgr`、`vgpuConfig.xml`、`libnvidia-vgpu.so`、`libnvidia-vgxcfg.so` |
| **宿主机 GPU（docker/CUDA/OpenGL）** | `nvidia.ko`、`nvidia-uvm/modeset/drm/peermem`、`libcuda`、OpenGL/OpenCL/Vulkan 用户态库 |

**实测验证**（Tesla P4，535.309.01，Unraid 6.18.44）：GPU 绑定 `nvidia` 标准驱动，同时 `nvidia-vgpu-vfio` 暴露 mdev 类型，因此**同一张卡上**：

- 宿主机 `nvidia-smi -L` 可见 → `GPU 0: Tesla P4`
- Docker 容器 `--gpus all`（`nvidia/cuda:12.2.0-base-ubuntu22.04`）可见 → `Tesla P4, CUDA 12.2`
- vGPU mdev 可同时创建（如 `nvidia-65` 4GB 档）分配给 VM

即：**宿主机 docker/CUDA 调用 P4 的同时，vGPU 也能切分给 VM**，两者并行不冲突。

> 注意：Merged 效果来自 `nvidia` + `nvidia-vgpu-vfio` 双模块共存，**不需要**任何 `cudahost=1` / `vup_kunlock=1` 之类的 modprobe 参数（这些参数并不存在，会被内核忽略）。

源码树由 `scripts/merge-driver.sh` 生成：

- **grid** 包（标准 Linux 驱动）作为基础
- **vgpu-kvm** 包贡献 vGPU 内核驱动 + 用户态组件
- `conftest.sh` 同时定义 `VGX_KVM_BUILD=1` 和 `GRID_BUILD=1`，一次编译产出两套模块

对于 535.309.01 版本，grid 和 vgpu-kvm 的 `nv-kernel.o_binary` 逐字节相同，仅 conftest 标志不同，因此合并是安全的。

## vgpu_unlock（消费级 GPU 解锁）

驱动包内置了开源项目 [vgpu_unlock](https://github.com/DualCoder/vgpu_unlock) / [vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs) 的完整两层组件，用于让**消费级游戏卡**（不在 NVIDIA vGPU 认证名单里的 GTX/RTX 卡）也能切分 vGPU：

| 层 | 组件 | 说明 |
|----|------|------|
| **内核层** | `vgpu_unlock_hooks.c` + `kern.ld` | 编译进 `nvidia.ko`：hook `memcpy`/`nv_ioremap*`，把 `nv-kernel.o` 的 `.rodata` 重定位到 `.data` 以便改写 vGPU 配置签名（已适配 535.x 的 magic 值） |
| **用户空间层** | `libvgpu_unlock_rs.so`（预编译，`/usr/local/lib/`） | 插件通过 `LD_PRELOAD` 注入 `nvidia-vgpud`/`nvidia-vgpu-mgr`，hook ioctl 把消费卡的 PCI 设备 ID 伪装成 vGPU 认证卡 |

**支持范围**（与 vgpu_unlock 上游一致）：

- ✅ Maxwell / Pascal / Turing 消费卡（GTX 9/10 系列、RTX 20 系列），伪装成对应的 Tesla/Quadro 认证卡
- ⚠️ Ampere（RTX 30 系列）上游标记为 work-in-progress
- ❌ Ada Lovelace（RTX 40 系列）不支持

**启用方式**：在插件的 NVIDIA GPU 页打开 **vGPU unlock** 开关即可（`/etc/vgpu_unlock/config.toml` 的 `unlock = true`，配合 `LD_PRELOAD` 启动守护进程）。

> ⚠️ 说明：本项目实测目标是 **Tesla P4（原生支持，无需 unlock）**。消费级卡的解锁路径**尚未在真机上验证**（需要一块 GTX/RTX 消费卡实测）。内核补丁的 magic 值针对 535.x 分支适配，但不同小版本之间可能需要微调。

## 构建产物

```
out/nvidia-<版本>-<内核>-Unraid-<构建号>.txz   (+ .md5)
```

针对目标 Unraid 内核编译的 6 个内核模块，加上完整用户态（库、二进制、vgpuConfig.xml、许可模板、安装脚本）。

## 云编译（GitHub Actions）

`.github/workflows/build-nvidia.yml` 执行 `scripts/build-nvidia-driver.sh`（合并 → 编译 → 打包）：

- **手动触发**：运行 *Build NVIDIA vGPU driver* 工作流，填写驱动版本、Unraid 内核版本和构建号
- 两个官方 NVIDIA `.run` 文件（grid + vgpu-kvm）自动从公开 alist 镜像下载
  （`https://alist.homelabproject.cc/foxipan/vGPU/`），也可用 `GRID_RUN_URL` / `VGPU_RUN_URL` 覆盖
- `nvidia-container-toolkit` + `libnvidia-container` 从仓库本体的 `tools/` 目录读取（开源组件，随仓库提交）

构建产物附加到 **tag 等于内核版本** 的 Release（如 `6.18.44-Unraid`、`6.18.43-Unraid`）。**Release 只包含编译好的驱动包，不包含任何官方源码或 .run 文件。**

## 本地构建

```bash
# 1. 合并（自动从 alist 下载 grid-<ver>.run + vgpu-kvm-<ver>.run）
./scripts/merge-driver.sh --version 535.309.01

# 2. 编译 + 打包（需要 Linux 环境，装有 gcc/make/curl/tar/xz）
KERNEL_RELEASE=6.18.44-Unraid VERSION=535.309.01 \
./scripts/build-nvidia-driver.sh
```

## 针对新内核重新编译

`build/rebuild-driver.sh` 可在不重新合并的情况下，针对新内核源码树重编译已合并的源：

```bash
./build/rebuild-driver.sh --kernel /path/to/kernel-6.18.45-Unraid \
                          --merged /path/to/merged-535.309.01 --package
```

## Release

当前构建：**535.309.01**（vGPU 16.14，支持 Tesla P4 等 Pascal 卡）for **6.18.44-Unraid / 6.18.43-Unraid**（tag 与内核版本一致）。

> Release 中仅包含编译完成的驱动包（`.txz` + `.md5`），不含任何官方驱动源码或 .run 文件。云编译所需的官方 .run 从 alist 镜像获取，开源容器工具随仓库提交。
