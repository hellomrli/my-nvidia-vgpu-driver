# Unraid Tesla P4 vGPU Merged Driver 使用文档

## 概述

本包为 **Unraid 7.x（内核 6.18.44-Unraid）** 编译的 **NVIDIA vGPU 16.14 (535.309.01) MERGED DRIVER**，
专为 **Tesla P4** 优化，支持：

- ✅ **宿主机使用 GPU**：docker 容器（CUDA/OpenCL/转码）、宿主 CUDA 计算
- ✅ **虚拟机 vGPU**：通过 mdev 把 P4 切成多个虚拟 GPU 分给 VM
- ✅ **原生 vGPU 支持**：P4 (PCI ID `10de:1BB3`) 是 NVIDIA 官方认证的 vGPU 卡，
  vgpuConfig.xml 自带完整 profile（GRID P4-1Q/2Q/4Q/8Q 等），**无需 unlock 补丁**

## 文件说明

| 文件 | 说明 |
|---|---|
| `nvidia-535.309.01-6.18.44-Unraid-1.txz` | Unraid 驱动包（Slackware 格式，novidio 兼容命名） |
| `plugin/` | **Unraid vGPU 插件**（.plg + 插件包 + 驱动包，WebUI 管理 vGPU） |
| `NVIDIA-Linux-x86_64-535.309.01-merged-vgpu-kvm.run` | **Merged driver 源包**（换内核重新编译时用，无需重新合并） |
| `../merged-driver/merged-535.309.01/` | Merged driver 解包源目录 |

## 安装方式（推荐）

**推荐直接用插件安装**（WebUI 管理 vGPU 设备、开机自动恢复、热更新）：

```bash
# 1. 把 release/plugin/ 目录拷贝到 Unraid U 盘 /boot/config/plugins/ 下
#    结构：
#   /boot/config/plugins/
#   ├── vgpu-driver.plg
#   └── vgpu-driver/
#       ├── vgpu-driver-2026.08.20.txz
#       └── packages/6.18/nvidia-535.309.01-6.18.44-Unraid-1.txz(.md5)

# 2. 安装插件
installplg /boot/config/plugins/vgpu-driver.plg

# 3. 到 Settings → NVIDIA vGPU 页面添加 vGPU、管理设备
```

详见 `plugin/README.md`。插件由 novidio 框架改编，**保留了 merged driver 特性**（宿主 docker 也能用 GPU）。

## 包内容

```
lib/modules/6.18.44-Unraid/kernel/drivers/video/
├── nvidia.ko            # 主驱动（宿主 CUDA/OpenGL + vGPU 接口）
├── nvidia-uvm.ko        # CUDA 统一内存（docker CUDA 需要）
├── nvidia-modeset.ko    # 显示模式设置
├── nvidia-drm.ko        # DRM (KMS)
├── nvidia-peermem.ko    # GPUDirect RDMA
└── nvidia-vgpu-vfio.ko  # vGPU mdev 核心模块（VM 用）
usr/bin/
├── nvidia-smi nvidia-modprobe nvidia-xconfig nvidia-settings
├── nvidia-vgpud nvidia-vgpu-mgr nvidia-xid-logd   # vGPU 守护进程
├── nvidia-gridd                                   # license 守护进程
├── nvidia-container-cli nvidia-container-runtime nvidia-container-toolkit
usr/lib64/              # 48 个 NVIDIA 运行库（libcuda/EGL/GL/OpenCL/Vulkan 等）
usr/share/nvidia/vgpuConfig.xml   # vGPU profile 配置（P4: 0x1BB3）
etc/nvidia/gridd.conf.template    # license 配置模板
```

## 一、安装

### 前提

1. Unraid 7.x（内核 `6.18.44-Unraid`，检查：`uname -r`）
2. 主板的 BIOS 已开启 **VT-d**（Intel）或 **IOMMU**（AMD）
3. Tesla P4 已插好，BIOS 里设置正确（一般无需改）

### 安装步骤

把 `release/` 目录下的三个文件拷贝到 Unraid（可用 U 盘 /boot 或任何共享目录）：

```bash
# 1. 拷贝文件到 Unraid 后，在终端执行：
cd /path/to/release
sh install-nvidia-vgpu.sh
```

脚本会自动：
1. 安装驱动包（installpkg）
2. 加载 nvidia + nvidia-vgpu-vfio + nvidia-uvm 等模块
3. 配置开机自动加载
4. 配置 nvidia-vgpud / nvidia-vgpu-mgr 服务
5. 生成 nvidia-gridd license 配置（**请先编辑脚本里的 LICENSE_SERVER 变量**）
6. 配置 docker nvidia runtime
7. 验证

### 验证安装

```bash
nvidia-smi                     # 应显示 Tesla P4
lsmod | grep nvidia            # 6 个模块都应加载
mdevctl types                  # 应列出 GRID P4 的 vGPU profile
nvidia-smi vgpu                # vGPU 状态
```

`mdevctl types` 输出示例：
```
0000:01:00.0
  nvidia-42
    Available instances: 8
    Device API: vfio-pci
    Name: GRID P4-1Q
    Description: num_heads=4, frl_config=60, framebuffer=1024M, ...
```

## 二、宿主机 docker 使用 GPU

### 1. 确认 nvidia runtime

```bash
docker info | grep -i runtime   # 应看到 nvidia
```

### 2. 运行容器

```bash
# CUDA 容器
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi

# 转码示例（Jellyfin/Emby/Plex）
docker run --gpus all -d jellyfin/jellyfin
```

> 如果容器首次启动失败，重启容器即可（已知 Unraid vGPU 驱动小问题）。

## 三、VM 使用 vGPU

### 1. 创建 vGPU 实例（mdev）

```bash
# 列出可用类型
mdevctl types

# 创建一个 GRID P4-1Q 实例（1GB 显存）
UUID=$(uuidgen)
mdevctl define --parent 0000:01:00.0 --type nvidia-42 --uuid $UUID
mdevctl start --parent 0000:01:00.0 --uuid $UUID
```

> `0000:01:00.0` 是 P4 的 PCI 地址（`lspci | grep -i nvidia` 查看）
> `nvidia-42` 是 GRID P4-1Q 的类型 ID（以 `mdevctl types` 实际输出为准）

### 2. Unraid VM 配置

在 VM 配置的 XML 中添加：

```xml
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='YOUR-UUID-HERE'/>
  </source>
</hostdev>
```

### 3. VM 内驱动

- **Windows VM**：安装 GRID 驱动（guest 驱动），`Guest_Drivers/` 下的
  `539.72_grid_win10_win11_server2019_server2022_dch_64bit_international.exe`
- **Linux VM**：安装 `NVIDIA-Linux-x86_64-535.309.01-grid.run`（guest 驱动）

### 4. vGPU profile 调优（可选）

编辑 `/usr/share/nvidia/vgpu/vgpuConfig.xml` 可调整显存大小等（需重启）。

## 四、License 配置（FastAPI-DLS）

vGPU 运行需要 license。假设 FastAPI-DLS 服务器在 `192.168.1.100:443`：

```bash
cat > /etc/nvidia/gridd.conf <<EOF
ServerAddress=192.168.1.100
ServerPort=443
FeatureType=0
EOF
systemctl restart nvidia-gridd
```

验证：
```bash
nvidia-smi -q | grep -A5 License
# 或 journalctl -u nvidia-gridd
```

## 五、换内核重新编译（重要）

Merged driver 源已单独保留，换 Unraid 内核时**无需重新合并**，只需重新编译：

```bash
# 1. 下载新内核源码（以 6.18.45 为例，从 ich777/unraid_kernel releases）
# 2. 解压到无空格路径，如 /home/lain/build/kernel-6.18.45-Unraid
# 3. 用 merged .run 解包并编译：

# 解包 merged driver
sh NVIDIA-Linux-x86_64-535.309.01-merged-vgpu-kvm.run --extract-only --target merged
cd merged/kernel

# 编译（SYSSRC/SYSOUT 指向新内核树）
make SYSSRC=/home/lain/build/kernel-6.18.45-Unraid \
     SYSOUT=/home/lain/build/kernel-6.18.45-Unraid -j$(nproc)

# 4. 收集 .ko 文件，按本包结构重新打包即可
```

> 或者直接用 `merged-driver/merged-535.309.01/` 源目录编译，效果相同。

## 六、常见问题

| 问题 | 解决 |
|---|---|
| `mdevctl types` 无输出 | 检查 `nvidia-vgpud`/`nvidia-vgpu-mgr` 服务是否运行；`lsmod` 是否有 nvidia-vgpu-vfio |
| 内核版本不匹配 | 驱动模块必须匹配 `uname -r`，确认 Unraid 版本 |
| docker 无法使用 GPU | 重启 docker；确认 `/etc/docker/daemon.json` 有 nvidia runtime |
| VM 内 vGPU 无显示 | 确认 mdev 已 start；VM 内装对应 guest 驱动 |
| license 错误 | 检查 gridd.conf 服务器地址；`nvidia-smi -q | grep License` |
| OpenGL 性能差 | vgpuConfig.xml 中把 profile class 改成 NVS 或用 B profile |

## 七、技术背景

- **Merged Driver**：NVIDIA 16.x LTS 驱动中，`vgpu-kvm`（vGPU 专用）与 `grid`（标准+license）
  使用**同一个 RM 二进制**（`nv-kernel.o_binary` 的 sha256 完全一致），区别仅在编译标志
  （`VGX_KVM_BUILD=1` vs `GRID_BUILD=1`）。本包将两者合并：同时保留
  `NV_VGPU_KVM_BUILD`（vGPU 功能）和 `NV_GRID_BUILD`（宿主功能），
  因此宿主 docker 与 VM vGPU 可共存于同一驱动。
- **无需 unlock**：P4 (`0x1BB3`) 是官方 vGPU 认证卡，`vgpuConfig.xml` 自带完整 profile。
- 参考：https://gitlab.com/polloloco/vgpu-proxmox 的 Proxmox 教程（原理相同，包结构不同）
