# 硬件、客户机与 unlock 边界

GPU 型号、宿主驱动系列、客户机驱动和软件授权共同决定 NVIDIA vGPU 的可用性。插件的型号提示只是选择辅助，不能替代官方支持矩阵。

## R535 与 R580

16.x/R535 保留 P4、P40、P100 等旧型号的兼容路线；19.x/R580 用于该分支支持的较新专业卡。P4 等 Pascal 卡不能通过选择较新的 R580 获得等价支持。

旧型号的官方维护结束后，本项目继续适配 Unraid 内核，不意味着 NVIDIA 继续提供该型号的新安全修复。具体型号、生命周期及客户机版本以 [NVIDIA 官方文档](https://docs.nvidia.com/vgpu/gpus-supported-by-vgpu.html)为准。

## Merged 与既有验证

合并包用同一模块集合提供宿主 CUDA/Docker 与 vGPU 组件。Tesla P4、535.309.01、6.18.44-Unraid 的已有验证包括 `nvidia-smi`、CUDA 容器和同时创建 mdev。

这是一组明确配置的验证结果。其他 GPU、驱动系列或并行负载需要各自测试，不能由包中同时存在两类组件推断稳定性。

## 实验性消费卡路径

项目集成 [DualCoder/vgpu_unlock](https://github.com/DualCoder/vgpu_unlock) 和 [mbilker/vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs)。原生支持 vGPU 的 P4 等专业卡无需启用 unlock。

| GPU 范围 | 项目边界 |
|---|---|
| Maxwell、Pascal、Turing 消费卡，如 GTX 9/10、RTX 20 | 上游主要目标范围，本项目消费卡路径尚无真机验证 |
| Ampere 消费卡，如 RTX 30 | 上游仍标记为开发中，不作为稳定支持 |
| Ada 消费卡，如 RTX 40 | 本项目 unlock 路径不支持；专业卡原生 vGPU 是另一条路径 |

本项目消费卡内核补丁只适配 16.x/R535，19.x 不提供同一路线。若在测试环境使用，应通过插件显式启用并核对带对应补丁的包。

硬件限制的处理不提供 NVIDIA 软件许可证，也不改变所用组件的授权条件。

返回[文档索引](index.md)。
