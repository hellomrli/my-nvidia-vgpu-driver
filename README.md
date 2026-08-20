# Unraid NVIDIA vGPU (Merged) Driver 插件

在 Unraid 上管理 NVIDIA vGPU 驱动的插件，基于 [novidio/unraid-novidio-vgpu-driver](https://github.com/novidio/unraid-novidio-vgpu-driver) 框架改编。

## 与 novidio 原版的关键区别

**本插件使用 MERGED DRIVER**（vGPU 宿主驱动 + 标准 NVIDIA 驱动合一），因此：

- ✅ 宿主 docker 容器可以用 GPU（`--gpus all`：CUDA / NVENC 转码 / OpenGL）
- ✅ VM 可以通过 mdev 使用 vGPU（把 GPU 切成多份分给虚拟机）
- 两者可共享同一张卡

> novidio 从 6.12.54 起放弃了 merged driver（只支持 VM vGPU），本插件专门保留了 merged 特性。

## 当前驱动

| 项目 | 值 |
|---|---|
| 驱动 | NVIDIA vGPU 16.14 (535.309.01) LTS |
| 目标 GPU | Tesla P4（原生 vGPU 认证，无需 unlock） |
| 目标内核 | 6.18.44-Unraid |
| 驱动包 | `nvidia-535.309.01-6.18.44-Unraid-1.txz` |

## 安装方式一：GitHub 自动下载（推荐）

驱动包发布在本仓库的 [Releases](https://github.com/hellomrli/my-vgpu-driver/releases)
页面，tag 按内核版本命名（如 `6.18.44-Unraid`）。在 Unraid 上：

```bash
installplg https://github.com/hellomrli/my-vgpu-driver/raw/master/vgpu-driver.plg
```

或从 WebUI：**Plugins → Install Plugin → 粘贴上面的 URL**。

插件安装后会自动从对应内核的 Release 下载驱动包并安装。

## 安装方式二：本地离线

把插件文件放到 Unraid 的 U 盘：

```
/boot/config/plugins/
├── vgpu-driver.plg                          # 插件定义
└── vgpu-driver/
    ├── vgpu-driver-2026.08.20.txz           # 插件本体（页面+脚本）
    └── packages/
        └── 6.18/
            ├── nvidia-535.309.01-6.18.44-Unraid-1.txz
            └── nvidia-535.309.01-6.18.44-Unraid-1.txz.md5
```

然后在 Unraid 终端执行：

```bash
installplg /boot/config/plugins/vgpu-driver.plg
```

> 注意：内核版本必须匹配！先 `uname -r` 确认是 `6.18.44-Unraid`。
> 换内核后需要重新编译驱动包（用 `build/rebuild-driver.sh`，见下）。

## 使用

安装后到 **Settings → NVIDIA vGPU** 页面：

1. **添加 vGPU**：选 GPU → 选 profile（GRID P4-1Q/2Q/4Q/8Q 等，实时读取）→ 自动生成 UUID
2. 把页面生成的 `<hostdev>` XML 片段粘贴到 VM 模板
3. vGPU 设备每次开机自动恢复

**宿主 docker 使用 GPU**：
```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

## vGPU profile 说明（Tesla P4）

| profile | 显存 | 用途 |
|---|---|---|
| GRID P4-1Q | 1GB | 轻量桌面/远程 |
| GRID P4-2Q | 2GB | 一般桌面 |
| GRID P4-4Q | 4GB | 高要求桌面 |
| GRID P4-8Q | 8GB | 最大（独占整卡） |
| GRID P4-1A/2A/4A/8A | A 系列 | 仅 Windows VM |
| GRID P4-1B/2B | NVS | 无头/计算 |

## 换内核重新编译驱动包

Unraid 内核升级后（例如 6.18.44 → 6.18.45），用仓库里的脚本 + 保留的 merged driver 源重新编译：

```bash
# 1. 从 ich777/unraid_kernel Releases 下载新内核源码并解压到无空格路径
# 2. 从 NVIDIA-Linux-x86_64-535.309.01-merged-vgpu-kvm.run 解包 merged driver 源：
#    sh NVIDIA-Linux-x86_64-535.309.01-merged-vgpu-kvm.run --extract-only --target merged
# 3. 编译（需编译机有 make/gcc/内核工具链）：
./build/rebuild-driver.sh --kernel /path/to/kernel-6.18.45-Unraid --merged /path/to/merged
# 4. 把输出模块 + release 包的用户空间文件重新打包成完整 .txz（见 docs/README-使用文档.md）
```

详细流程见 `docs/README-使用文档.md`。

## 常见问题

| 问题 | 解决 |
|---|---|
| `mdev types not available` | 看 syslog 里 nvidia-vgpud 是否报 "GPU not supported by vGPU"；P4 需要 535 系的 vgpuConfig.xml（本包已内置，若用了 550+ 的 XML 请覆盖） |
| docker 不能用 GPU | 重启 docker；确认 `/etc/docker/daemon.json` 有 nvidia runtime |
| VM 内 vGPU 黑屏 | VM 内装 guest 驱动；确认 mdev 已 start |
| 更新驱动失败 | 有 VM 占用 vGPU 时无法热更新，停止 VM 或重启后生效 |
| 内核版本不匹配 | 驱动模块必须匹配 `uname -r` |

## 文件清单

- `vgpu-driver.plg` — 插件定义（XML）
- `packages/vgpu-driver-2026.08.20.txz` — 插件本体（源码在 `source/`，可自行打包）
- `source/` — 插件源文件（页面、脚本）
- `build/rebuild-driver.sh` — 换内核重编译脚本
- `docs/` — 使用文档与研究报告
- 驱动包 `nvidia-535.309.01-6.18.44-Unraid-1.txz` — 发布在 [Releases](https://github.com/hellomrli/my-vgpu-driver/releases)（按内核 tag）

## Credits

- [novidio/unraid-novidio-vgpu-driver](https://github.com/novidio/unraid-novidio-vgpu-driver) 插件框架
- [stl88083365](https://github.com/stl88083365/unraid-nvidia-vgpu-driver) 插件基础
- [VGPU-Community-Drivers/vGPU-Unlock-patcher](https://github.com/VGPU-Community-Drivers/vGPU-Unlock-patcher) merged 驱动方法
- [midi1996/unraid-nvidia-vgpu-driver-builder](https://github.com/midi1996/unraid-nvidia-vgpu-driver-builder) 构建脚本
- [ich777/unraid_kernel](https://github.com/ich777/unraid_kernel) Unraid 内核
