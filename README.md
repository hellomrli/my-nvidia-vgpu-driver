# my-nvidia-vgpu-driver

为 **Unraid** 编译的 **NVIDIA vGPU（Merged）驱动**，基于 NVIDIA 官方 Linux 驱动包构建，打包为可直接安装到 Unraid 服务器的 Slackware `.txz` 格式。

配合 [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager) 插件使用——插件负责按检测到的 GPU 型号选择驱动系列、下载本包、安装并管理 vGPU 设备（mdev）供虚拟机直通。

## 驱动系列（双系列并行发布）

每个内核版本的 Release tag 下**同时携带两个系列**的驱动包，按硬件选择：

| 系列 | 驱动版本 | 分支状态 | 硬件范围 | 资产命名 |
|------|----------|----------|----------|----------|
| **16.x** | 535.309.01 | vGPU 16.14 LTS（2026-07 EOL，末版） | Maxwell / Pascal / Volta / Turing / Ampere / Ada：**P4、P6、P40、P100**、V100、M60/M10、T4、Quadro RTX 6000/8000、A40、L40/L40S、RTX 6000 Ada 等 | `nvidia-535.309.01-<内核>-Unraid-<构建号>.txz` |
| **19.x** | 580.178.05 | vGPU 19.6 **现行 LTS**（支持到 2028-07） | **Turing T4 起**：Ampere（A40/A10）、Ada（L40/L40S/RTX 6000 Ada）、Blackwell（B 系列）。**不含 Pascal/Maxwell**（17 分支起移除） | `nvidia-580.178.05-<内核>-Unraid-<构建号>.txz` |

> guest 驱动兼容性（NVIDIA 官方矩阵）：19.x/20.x 宿主只接受同分支及 19.x 的 guest 驱动；升级宿主驱动时 VM 内 guest 驱动需同步升级。两系列的取舍可参考插件页面按 GPU 型号给出的建议。

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

即：**宿主机 docker/CUDA 调用 GPU 的同时，vGPU 也能切分给 VM**，两者并行不冲突。

> 注意：Merged 效果来自 `nvidia` + `nvidia-vgpu-vfio` 双模块共存，**不需要**任何 `cudahost=1` / `vup_kunlock=1` 之类的 modprobe 参数（这些参数并不存在，会被内核忽略）。

源码树由 `scripts/merge-driver.sh` 生成：

- **grid** 包（标准 Linux 驱动）作为基础
- **vgpu-kvm** 包贡献 vGPU 内核驱动 + 用户态组件
- `conftest.sh` 同时定义 `VGX_KVM_BUILD=1` 和 `GRID_BUILD=1`，一次编译产出两套模块

**16.x（535.309.01）**：grid 与 vgpu-kvm 的 `nv-kernel.o_binary` 逐字节相同，仅 conftest 标志不同，合并天然安全。

**19.x（580.178.05）**：两包的 RM 二进制**布局不同**（grid 构建为 580.178.04，vgpu 构建为 580.178.05），但导出符号集**完全一致**（61647 个符号，已实测）。合并脚本因此：

- 采用 **vgpu-kvm 的 `nv-kernel.o_binary`**，并把顶层 `kernel/Kbuild` 的 `NV_VERSION_STRING` 重新品牌化为 vgpu 版本——保证 `modinfo -F version nvidia` 与包名一致（插件的更新逻辑依赖这一点）；
- `nvidia-sources.Kbuild` 的 vfio-interface 插入使用多锚点兜底（535：`nv-frontend.c`；580：`os-interface.c`；580 的 `Makefile` 本身已含 `nvidia-vgpu-vfio`）；
- soname 链接按库组区分版本：grid 体系库（libcuda 等）指向 `GRID_VERSION`（580.178.04），vgpu 体系库指向 `VERSION`（580.178.05）。

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

> ⚠️ **unlock 内核补丁仅构建进 16.x 系列**（`UNLOCK_PATCH=auto`：magic 值为 535 专属，其余分支自动跳过，可用 `UNLOCK_PATCH=1/0` 强制）。原生 vGPU 认证卡（Tesla P4 等）不需要 unlock。消费级卡的解锁路径**尚未在真机上验证**。

## 构建产物

```
out/nvidia-<版本>-<内核>-Unraid-<构建号>.txz   (+ .md5)
```

针对目标 Unraid 内核编译的 6 个内核模块，加上完整用户态（库、二进制、vgpuConfig.xml、许可模板、安装脚本）。包内**不包含** `etc/docker/daemon.json`——Docker nvidia runtime 由插件在运行时用 `nvidia-ctk`/jq 合并配置，避免覆盖用户已有的 Docker 配置。

## 云编译（GitHub Actions）

`.github/workflows/build-nvidia.yml` 执行 `scripts/build-nvidia-driver.sh`（合并 → 编译 → 打包）：

- **手动触发**：运行 *Build NVIDIA vGPU driver* 工作流，填写：
  - `driver_version`：`535.309.01`（16.x）或 `580.178.05`（19.x）
  - `vgpu_branch`：`16.14` 或 `19.6`
  - `kernel_release`：目标 Unraid 内核（如 `6.18.44-Unraid`）
  - `package_build`：构建号
  - `alist_pkg_dir`：**19.x 等三段式目录必须填写**（如 `NVIDIA-GRID-Linux-KVM-580.178.05-580.178.04-582.78`，格式为 host-grid-windows，会自动推导 grid 版本）；16.x 的两段式目录留空即可（由 `windows_version` 拼出）
- 两个官方 NVIDIA `.run` 文件（grid + vgpu-kvm）按以下顺序自动获取，**任一来源可用即通过**：
  1. `GRID_RUN_URL` / `VGPU_RUN_URL`（显式覆盖，仓库变量可配）
  2. 公开 alist 镜像 `https://alist.homelabproject.cc/foxipan/vGPU/`
  3. GitHub Release 镜像 `https://github.com/<RUN_MIRROR_REPO>/releases/download/<RUN_MIRROR_TAG>/grid-*.run`（默认 `sources` tag，用 `scripts/publish-run-mirror.sh` 发布）

  每个来源下载后都会校验：不是 HTML 反爬页、体积不为几百 KB、签名是自解压脚本/ELF，最后比对固化的 SHA256；全部失败时报出**每个来源各自失败的原因**（2026-09 起 alist 的 `/d/`、`/p/`、`/dav/` 全部被 CrowdSec 挑战页接管，HTTP 200 返回 ~300 KiB HTML，因此 `curl --fail` 不会报错——现在会直接指出"HTML page, not the .run installer"）
- `nvidia-container-toolkit` + `libnvidia-container` 从仓库本体的 `tools/` 目录读取（开源组件，随仓库提交，打包时按 `tools/SHA256SUMS` 校验）

构建产物附加到 **tag 等于内核版本** 的 Release（如 `6.18.44-Unraid`、`6.18.47-Unraid`）。**Release 只包含编译好的驱动包，不包含任何官方源码或 .run 文件。**

## 供应链校验

- 官方 `.run` 文件的 SHA256 按驱动版本固化在 `build-nvidia-driver.sh` 内（535.309.01 与 580.178.04/580.178.05 已固化；未知版本告警放行，可用 `GRID_RUN_SHA256`/`VGPU_RUN_SHA256` 覆盖）
- ich777 内核源码包的 SHA256 按内核版本固化（6.18.43–6.18.47），未知内核告警放行（`KERNEL_ARCHIVE_SHA256` 可覆盖）

## 镜像不可用时的处置（下载失败排查）

构建日志出现 `could not be obtained from any source` 时，看它列出的每个来源及拒绝原因：

- `HTML page, not the .run installer (anti-bot/CrowdSec challenge on the host)`
  → 该镜像挡住了自动化下载。把 `.run` 放到任一可达位置即可，三种方式：
  1. **本地/缓存**：直接放进 `downloads/`（`DL_DIR`），已存在且校验通过的文件会被复用，不再下载；
  2. **GitHub Release 镜像**（推荐，CI 无需额外凭据）：
     ```bash
     scripts/publish-run-mirror.sh downloads/grid-535.309.01.run downloads/vgpu-kvm-535.309.01.run
     ```
     默认发布到本仓库 `sources` tag 的 Release（资产名必须是 `grid-<grid版本>.run` / `vgpu-kvm-<version>.run`）；用别的仓库或私有地址时设置仓库变量 `RUN_MIRROR_REPO` / `RUN_MIRROR_TAG` / `RUN_MIRROR_BASE`。该 Release 只放构建输入，驱动包仍在各自内核 tag 下，`--latest=false` 不会影响"最新 Release"。
  3. **自有 URL**：把 `GRID_RUN_URL` / `VGPU_RUN_URL`（仓库变量或环境变量）指向自己的对象存储/NAS 直链。

> 官方 `.run` 是 NVIDIA 专有二进制，公开再分发受 GRID/vGPU 许可限制；若不希望公开托管，优先用方式 1 或方式 3。

## 本地构建

```bash
# 16.x：
VERSION=535.309.01 KERNEL_RELEASE=6.18.44-Unraid ./scripts/build-nvidia-driver.sh

# 19.x（注意 GRID_VERSION 与三段式目录）：
VERSION=580.178.05 GRID_VERSION=580.178.04 \
ALIST_VGPU_BRANCH=19.6 \
ALIST_PKG_DIR=NVIDIA-GRID-Linux-KVM-580.178.05-580.178.04-582.78 \
KERNEL_RELEASE=6.18.44-Unraid ./scripts/build-nvidia-driver.sh
```

需要 Linux 环境（gcc/make/curl/tar/xz/kmod）。**本地路径不能包含空格**——NVIDIA 的 makeself 自解压脚本不兼容含空格路径（GitHub Actions 上无此问题）。也可先 `merge-driver.sh` 单独合并，再 `build/rebuild-driver.sh` 针对新内核重编译。

## Release

| 内核 tag | 16.x 资产 | 19.x 资产 |
|---|---|---|
| 6.18.43-Unraid | `nvidia-535.309.01-…-2.txz` | `nvidia-580.178.05-…-1.txz` |
| 6.18.44-Unraid | `nvidia-535.309.01-…-3.txz` | `nvidia-580.178.05-…-1.txz` |
| 6.18.45-Unraid | `nvidia-535.309.01-…-2.txz` | `nvidia-580.178.05-…-1.txz` |
| 6.18.46-Unraid | `nvidia-535.309.01-…-2.txz` | `nvidia-580.178.05-…-1.txz` |
| 6.18.47-Unraid | `nvidia-535.309.01-…-2.txz` | `nvidia-580.178.05-…-1.txz` |

> Release 中仅包含编译完成的驱动包（`.txz` + `.md5`），不含任何官方驱动源码或 .run 文件。云编译所需的官方 .run 从 alist 镜像获取；若该镜像不可用（见上文"镜像不可用时的处置"），则从可选的 GitHub Release 镜像或 `GRID_RUN_URL`/`VGPU_RUN_URL` 获取，开源容器工具随仓库提交。
