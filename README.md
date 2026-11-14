# my-nvidia-vgpu-driver

为 Unraid 构建 NVIDIA vGPU Merged 驱动包，将虚拟机 vGPU 与宿主 Docker/CUDA 组件打包到同一套内核模块中。

[驱动下载](https://github.com/hellomrli/my-nvidia-vgpu-driver/releases) · [安装指南](docs/install.md) · [兼容性说明](docs/compatibility.md) · [文档索引](docs/index.md)

> [!IMPORTANT]
> 按 GPU 型号选择 16.x/R535 或 19.x/R580，并匹配完整 Unraid 内核。社区合并包不代表 NVIDIA 对 Unraid 的官方支持。

## 在 Unraid 中安装

需要 Unraid 7.2.3 或更新版本。在“插件 → 安装插件”中添加管理插件地址：

```text
https://github.com/hellomrli/my-unraid-vgpu-manager/raw/master/my-unraid-vgpu-manager.plg
```

随后打开“设置 → Unraid vGPU 管理器 → 驱动管理”，按显卡选择驱动系列并安装。安装管理插件本身不会自动安装 NVIDIA 驱动。

驱动就绪后，在“NVIDIA 显卡 → 授权与模块”中配置授权服务，选择配置档、创建 vGPU 并绑定虚拟机。客户机还需安装兼容驱动并完成其授权。完整步骤见[安装指南](docs/install.md)。

## 选择驱动系列

| 系列 | 定位 | 需要核对 |
|---|---|---|
| 16.x / R535 | P4、P40、P100 等旧型号的兼容路线；本项目消费卡 unlock 补丁适配该系列 | GPU 支持周期、客户机驱动与授权 |
| 19.x / R580 | T4、A40、L40/L40S 等该分支支持的型号 | 不能用来替代 Pascal 卡的 R535 路线 |

具体版本随 Releases 更新，型号与生命周期以 [NVIDIA 官方支持列表](https://docs.nvidia.com/vgpu/gpus-supported-by-vgpu.html)为准。插件普通更新保持已安装系列，切换系列需主动选择。

## 包中有什么

- `nvidia-vgpu-vfio`、vGPU 服务和配置档，用于虚拟 GPU 设备。
- `nvidia`、CUDA/图形用户态库及容器工具，用于宿主与 Docker GPU 工作负载。
- 与完整 Unraid 内核匹配的模块和包校验文件。
- 项目集成的实验性 unlock 组件；硬件范围和限制见[兼容性说明](docs/compatibility.md)。

已记录的 Tesla P4 / 535.309.01 / 6.18.44-Unraid 测试包含宿主 `nvidia-smi`、Docker CUDA 和同时创建 mdev。该单一配置的结果不扩展为所有硬件或并行负载的支持承诺。

## 更新与维护

自动任务每天检查当前 Unraid 正式版、公开 beta/RC 和 ich777 最新内核，对两个驱动系列补齐缺少的完整包。历史内核退出目标后不再更新，已发布包保留。

安装、内核升级预下载和回退由 [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager)处理；构建源、版本参数和发布策略见[构建指南](docs/building.md)。

## 授权与反馈

NVIDIA 专有组件仍受其相应许可约束，硬件 unlock 不能替代软件许可证。本仓库目前没有根目录许可证文件；第三方组件沿用其授权。

在 [Issues](https://github.com/hellomrli/my-nvidia-vgpu-driver/issues) 提供 GPU 型号、Unraid/内核、驱动系列和脱敏日志。设备与虚拟机操作问题也可参考[管理插件指南](https://github.com/hellomrli/my-unraid-vgpu-manager/blob/master/docs/guide.zh-CN.md)。
