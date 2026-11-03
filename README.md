# my-nvidia-vgpu-driver

为 **Unraid** 提供 **NVIDIA vGPU（Merged）驱动包**，将虚拟机 vGPU 与宿主机 Docker/CUDA 所需组件合并，配合 [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager) 管理驱动和虚拟 GPU。

> [!IMPORTANT]
> **这是社区合并驱动，不代表 NVIDIA 对 Unraid 的官方支持。** 请按 GPU 型号选择系列，不要仅因为版本更新就更换驱动。

## 安装管理插件

**[插件安装链接（.plg）](https://github.com/hellomrli/my-unraid-vgpu-manager/raw/master/my-unraid-vgpu-manager.plg)**

打开 Unraid 的 **插件（Plugins）→ 安装插件（Install Plugin）**，粘贴下面的地址。点击代码块右上角的**复制按钮**即可复制完整链接：

```text
https://github.com/hellomrli/my-unraid-vgpu-manager/raw/master/my-unraid-vgpu-manager.plg
```

管理插件需要 **Unraid 7.2.3 或更新版本**。Unraid 会通过 `.plg` 下载对应的插件安装包，后续在插件管理器中更新即可；无需手动下载插件包。**安装插件本身不会安装 NVIDIA 驱动**，驱动由你在插件中选择后安装。

## 快速开始

1. 卸载管理同一 NVIDIA 驱动的其他插件并重启，避免与 Nvidia-Driver、旧 vgpu-driver 等插件冲突。
2. 打开 **设置 → Unraid vGPU 管理器 → 驱动管理**，按显卡选择支持的系列并安装。插件下载与当前 Unraid 内核匹配的驱动包。
3. 在 **NVIDIA 显卡 → 授权与模块** 中配置授权服务，再选择显卡与配置档，创建 vGPU 并绑定到目标虚拟机。
4. 关闭并重新启动虚拟机，使设备在冷启动时挂载；在客户机中安装兼容的 NVIDIA vGPU 驱动，完成所需授权。

完成后，插件会显示 vGPU 设备及其虚拟机绑定；已启用的驱动和设备在重启后从已校验的缓存包恢复。详细设置见[插件中文使用指南](https://github.com/hellomrli/my-unraid-vgpu-manager/blob/master/docs/guide.zh-CN.md)。

## 选择哪个驱动系列？

| 系列 | 已提供的驱动版本 | 选择建议 |
|---|---|---|
| **16.x / R535** | `535.309.01` | P4、P40、P100 等旧型号的兼容路线；本项目的消费卡 unlock 内核补丁也仅适配这一系列。 |
| **19.x / R580** | `580.178.05` | T4、A40、L40/L40S 等该分支支持的型号；新安装且硬件同时受两个系列支持时，插件推荐 19.x。**不能用于替代 P4 等 Pascal 卡的 16.x 驱动。** |

具体型号与支持周期以 [NVIDIA 官方列表](https://docs.nvidia.com/vgpu/gpus-supported-by-vgpu.html)为准。P4/P40/P100 等旧型号的官方维护已结束，继续适配 Unraid 内核不等于获得新的官方安全修复。插件的型号提示不是兼容性认证；部分较新 GPU 还需先启用 NVIDIA SR-IOV，插件不会自动执行 `sriov-manage`。

切换系列前，停止使用 GPU 的虚拟机和容器，并核对宿主与客户机的[驱动兼容性要求](https://docs.nvidia.com/vgpu/)。插件的普通更新保持已安装系列，不会自动从 16.x 升到 19.x；更新后，已停止的工作负载需要手动启动。

## Merged 驱动能做什么？

| 用途 | 包内组件 |
|---|---|
| **虚拟机 vGPU** | `nvidia-vgpu-vfio`、vGPU 守护进程及配置档，用于创建和管理虚拟 GPU 设备。 |
| **宿主机与容器 GPU** | `nvidia`、CUDA/图形用户态库及 NVIDIA 容器工具，用于宿主 GPU 访问和 Docker GPU 工作负载。 |

项目已有的 **Tesla P4 / 535.309.01 / 6.18.44-Unraid** 验证记录包含：宿主 `nvidia-smi` 识别 GPU、Docker CUDA 容器使用 GPU，以及同时创建 vGPU mdev 供虚拟机使用。**这一结果不能推广为所有显卡、驱动系列或负载都能稳定并行。**

不需要添加 `cudahost=1`、`vup_kunlock=1` 等无效模块参数。Docker runtime 由插件合并配置，驱动包不会覆盖你的 `daemon.json`。

## 消费级显卡与 vgpu_unlock

项目集成 [vgpu_unlock](https://github.com/DualCoder/vgpu_unlock) / [vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs)，作为非原生 vGPU 显卡的实验性选项。**原生支持 vGPU 的 P4 等显卡不需要启用 unlock。**

| 显卡范围 | 本项目的使用边界 |
|---|---|
| Maxwell / Pascal / Turing 消费卡，如 GTX 9/10、RTX 20 | 上游面向的主要范围，但不保证每个型号可用；本项目的消费卡路径尚无真机验证。 |
| Ampere 消费卡，如 RTX 30 | 上游仍标记为开发中，不作为稳定支持承诺。 |
| Ada 消费卡，如 RTX 40 | 本项目的 unlock 路径不支持；专业卡的原生 vGPU 支持是另一回事。 |

需要测试时，在插件的 NVIDIA 显卡页启用 **vGPU unlock**，使用带对应内核补丁的 **16.x** 包；19.x 不提供这条解锁路线。硬件解锁不等于获得 NVIDIA 许可证，仍需满足所用软件的授权要求。

## 内核匹配与更新

驱动包必须与**完整 Unraid 内核版本**匹配。Unraid 写入新系统后、重启之前，确认插件已准备新内核对应的已选系列；没有匹配包时，不要用其他内核的包代替。

本仓库只维护[当前 Unraid 正式版及公开测试版](https://docs.unraid.net/unraid-os/download_list/)在对应 [Release notes](https://docs.unraid.net/category/release-notes/) 中列出的内核，以及 [ich777 最新内核](https://github.com/ich777/unraid_kernel/releases/latest)。三个来源合并去重，分别检查 16.x、19.x，只为缺少对应版本完整包的组合补编。ich777 内核用于提前准备新系统；退出这些来源的历史内核不再跟进更新，已有驱动包保留。

实际可用内核及版本以[已发布驱动包](https://github.com/hellomrli/my-nvidia-vgpu-driver/releases)为准。插件的定时检查只提示更新，不自动安装；系统升级预下载也不会替换当前运行的驱动。

## 文档与反馈

- [插件中文说明](https://github.com/hellomrli/my-unraid-vgpu-manager/blob/master/README.zh-CN.md)：安装、配置与日常操作。
- [NVIDIA vGPU 官方文档](https://docs.nvidia.com/vgpu/)：支持矩阵、客户机驱动及许可要求。驱动中的 NVIDIA 专有组件仍受其相应许可约束。
- [问题反馈](https://github.com/hellomrli/my-nvidia-vgpu-driver/issues)：请附 GPU 型号、Unraid/内核版本、驱动系列和相关日志，移除授权令牌等敏感信息。
