# 安装与更新 NVIDIA 驱动

使用 [my-unraid-vgpu-manager](https://github.com/hellomrli/my-unraid-vgpu-manager) 安装与当前完整内核匹配的 NVIDIA 包。需要 Unraid 7.2.3 或更新版本。

## 完成首次安装

1. 卸载管理同一驱动的其他插件，例如 Nvidia-Driver 或旧 vgpu-driver，并重启。
2. 在管理插件的“驱动管理”选择显卡支持的 16.x 或 19.x 系列，下载并安装匹配包。
3. 在 NVIDIA 页面配置授权服务，选择显卡与配置档，创建 vGPU 并绑定虚拟机。
4. 关闭并重新启动虚拟机，使设备在冷启动时挂载。
5. 在客户机安装兼容的 NVIDIA vGPU 驱动并完成授权，再验证工作负载。

插件显示 vGPU 设备及虚拟机绑定；重启后从校验过的缓存恢复已启用驱动和设备。某些较新 GPU 还需先启用 NVIDIA SR-IOV，插件不会自动执行 `sriov-manage`。

## 更新当前系列

普通更新保持所选系列，不会自动从 R535 切到 R580。插件的定时检查只提示，不自动安装；实际安装需手动操作。

更新前停止使用 GPU 的虚拟机与容器。更新后按需要手动启动它们，并验证设备、客户机版本和授权。系列切换前还需核对[NVIDIA 兼容性要求](https://docs.nvidia.com/vgpu/)与[本项目硬件说明](compatibility.md)。

## 升级 Unraid 内核

写入新 Unraid 系统后、重启之前，在插件中确认已为新完整内核准备相同系列的匹配包。预下载不会替换当前正在运行的驱动；没有对应包时应等待构建，不用另一内核的包代替。

发布文件以 `nvidia-版本-完整内核-构建号.txz` 命名，并带 `.md5`。同一内核标签下可能有多个系列与版本，以插件选择和 Releases 资产为准。

## 宿主 Docker/CUDA

Merged 包同时包含宿主 GPU 组件。Docker runtime 配置由插件合并，驱动包不会覆盖现有 `daemon.json`。不要添加项目中无效的 `cudahost=1`、`vup_kunlock=1` 等模块参数。

如果宿主与虚拟机并行使用异常，收集各自日志和负载信息，不将 P4 的既有验证记录视为其他型号的并行保证。

返回[文档索引](index.md)。
