# polloloco/vgpu-proxmox 项目研究报告

> 调研日期：2026-08-20
> 来源：https://gitlab.com/polloloco/vgpu-proxmox （已 clone 分析，另有其依赖项目 vgpu_unlock-rs 源码）

## 1. 项目是什么

**NVIDIA vGPU on Proxmox** —— 一份教你在 Proxmox VE（当前 8.3）上安装 NVIDIA vGPU Host 驱动的详细指南仓库。
仓库本体不含代码，核心资产是：

| 内容 | 说明 |
|---|---|
| `README.md`（689 行） | 完整的图文教程 |
| 23 个 `.patch` 文件 | 覆盖驱动 14.2 (510.85.03) 到 19.0 (580.65.05) 的**二进制补丁** |
| `downloading_driver.mp4` | 演示如何在 NVIDIA 企业门户下载驱动 |
| `LICENSE.md` | AGPL-3.0-or-later |

**核心目标**：让**未经 vGPU 认证的消费级显卡**（GeForce、非 vGPU Quadro）也能用上 vGPU（GPU 虚拟化，一张卡切给多个虚拟机）。

## 2. 支持的硬件（重要！）

- ✅ Maxwell 2.0：GTX 9xx、Quadro Mxxxx、Tesla Mxx（**GTX 970 除外**）
- ✅ Pascal：GTX 10xx、Quadro Pxxxx、Tesla Pxx
- ✅ Turing：GTX 16xx、RTX 20xx、Txxxx（作者测试平台是 RTX 2080 Ti）
- ❌ **Ampere（RTX 30xx）和 Ada（RTX 40xx）不支持**，除非是 vGPU 认证卡（如 A5000、RTX 6000 Ada）
- ⚠️ 从驱动 17.0 起，NVIDIA 官方砍掉 Pascal 及更老架构；继续用需要打补丁 + 从 16.x 拷贝旧 `vgpuConfig.xml`

## 3. 技术原理（三层）

这套方案是"二进制补丁 + 用户态 LD_PRELOAD 钩子 + 配置覆盖"的组合：

### 第一层：二进制补丁（本仓库的 .patch 文件）
- NVIDIA 的 `.run` 安装器自带 `--apply-patch` 参数，可直接把补丁打到驱动包内的内核模块二进制 `kernel/nvidia/nv-kernel.o_binary` 上，生成 `-custom.run`。
- 补丁是**面向具体驱动版本的二进制 diff**（修改编译后的 x86_64 机器码），所以每个补丁只对应一个版本号，不能通用。
- 补丁做的事：
  1. 绕过"NVIDIA 认证 vGPU 卡"检查，让消费卡暴露 vGPU profile（mdev 类型）；
  2. 17.0 及以后版本额外恢复 Pascal/老卡的支持（补丁头部注明 "This patch also restores vGPU capability on Pascal generation and older GPUs"）。

### 第二层：vgpu_unlock-rs（运行时解锁 + 配置注入）
- 依赖 [mbilker/vgpu_unlock-rs](https://github.com/mbilker/vgpu_unlock-rs)（Rust 实现，替代 DualCoder 原版的内核模块钩子方案）。
- 原理：通过 systemd drop-in 给 `nvidia-vgpud` 和 `nvidia-vgpu-mgr` 两个守护进程注入：

  ```ini
  [Service]
  Environment=LD_PRELOAD=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so
  ```

- 库内导出一个自定义 `ioctl()`，用 `dlsym(RTLD_NEXT, "ioctl")` 链到真实系统调用，专门拦截 `NV_ESC_RM_CONTROL`（NVIDIA RM 控制命令），**篡改驱动返回给用户态的 vGPU 配置结构体**（VgpuConfig：vram、分辨率、编码器数量、CUDA 开关等字段）。
- 效果：
  - 消费卡被识别为 vGPU 卡（`mdevctl types` 能列出 profile）；
  - 允许在运行时按 VM 覆盖 profile 参数。

### 第三层：profile_override.toml（按 profile / 按 VM 调参）
配置文件 `/etc/vgpu_unlock/profile_override.toml`，TOML 格式，两个块：

```toml
[profile.nvidia-259]   # 对某 profile 的所有实例生效（nvidia-259 = GRID RTX6000-4Q）
num_displays = 1
display_width = 1920
display_height = 1080
max_pixels = 2073600
cuda_enabled = 1
frl_enabled = 1        # 帧率限制器，1=锁 60fps
framebuffer = 0x74000000        # + framebuffer_reservation = VRAM 总字节数
framebuffer_reservation = 0xC000000   # 例：0x74000000+0xC000000 = 2GB

[vm.100]               # 只对 Proxmox VM ID 100 生效
frl_enabled = 0
```

- 关键点：一个 profile（如 4Q）的显存大小可以在不同 VM 上覆盖成不同值，实现"一张 4Q 卡同时切出 2GB、1GB 等不同规格 VM"。
- profile 后缀含义：Q 是 Windows 通用；**A 只在 Windows 有效**；OpenGL 性能差时改用 NVS profile 或 A/B profile。

## 4. 驱动版本对应关系

| GRID 分支 | 驱动版本 | 仓库补丁 | 备注 |
|---|---|---|---|
| 19.0 | 580.65.05 | ✅ | 最新 |
| 18.x | 570.124.03 ~ 570.172.07 | ✅ | |
| 17.x | 550.54.10 ~ 550.163.02 | ✅ | 官方支持到 2025-02 |
| 16.x | 535.54.06 ~ 535.230.02 | ✅ | **LTS，官方支持到 2026-07；Pascal 用户用这个** |
| 15.x / 14.x | 525.x / 510.x | ✅ | EOL，不推荐 |

驱动本体需从 [NVIDIA Licensing Portal](https://nvid.nvidia.com/dashboard/) 下载（免费注册评估账号，用自定义域名邮箱更易过审），文件名为 `NVIDIA-Linux-x86_64-<版本>-vgpu-kvm.run`。

## 5. 安装流程要点（Proxmox 8.3）

1. 换 `pve-no-subscription` 源；`apt install git build-essential dkms pve-headers mdevctl`
2. clone 本仓库 + `vgpu_unlock-rs`，装 Rust，`cargo build --release`
3. 建 `/etc/vgpu_unlock/profile_override.toml` + 两个 systemd drop-in（LD_PRELOAD）
4. BIOS 开 VT-d/IOMMU，内核参数加 `intel_iommu=on`（AMD 无需加参数），`update-grub` 或 `proxmox-boot-tool refresh`
5. `/etc/modules` 加 `vfio vfio_iommu_type1 vfio_pci vfio_virqfd`；`blacklist nouveau`
6. 打补丁：`./NVIDIA-Linux-x86_64-550.144.02-vgpu-kvm.run --apply-patch ~/vgpu-proxmox/550.144.02.patch` → 生成 `-custom.run`
7. 安装：`./NVIDIA-Linux-x86_64-550.144.02-vgpu-kvm-custom.run --dkms -m=kernel`，重启
8. 验证：`nvidia-smi`、`mdevctl types`（能列出 profile 即解锁成功）、`nvidia-smi vgpu`
9. Proxmox 网页端：VM → Hardware → Add → PCI Device，选 GPU，选 MDev Type

## 6. 授权（License）绕过

- vGPU 正式使用需要 NVIDIA 授权。旧方案（把 vGPU 伪装成 Quadro 骗 license）作者已移除并**不推荐**。
- 推荐方案：**自建 FastAPI-DLS 许可证服务器** https://git.collinwebdesigns.de/oscar.krause/fastapi-dls
- 无 license 时 vGPU 功能受限/试用期过期后失效，这是 vGPU 方案绕不开的一环。

## 7. 常见坑

- 之前做过 GPU passthrough 的步骤必须全部还原（`lspci -knnd 10de:` 里看到 `vfio-pci` 就说明没还原干净）。
- 只有一张 GPU 且无核显时，装完驱动本地显示器会黑屏，必须用 SSH。
- 显示器接口上插 dummy plug 会引发问题。
- 升级驱动前先 `nvidia-uninstall`，并 `git pull` 重编译 vgpu_unlock-rs。
- `mdevctl types` 无输出 = 解锁没生效，优先查 LD_PRELOAD 是否注入成功。

## 8. 对 Unraid 移植的参考价值（与你的工作目录相关）

这套方法**不依赖 Proxmox 特有功能**，核心三要素是：patched vGPU 驱动 + vgpu_unlock-rs + mdevctl。社区已有 Unraid 适配：

- [stl88083365/unraid-nvidia-vgpu-driver](https://github.com/stl88083365/unraid-nvidia-vgpu-driver)：Unraid vGPU 驱动插件（user scripts 方式）
- Unraid 论坛：[Nouveau driver update and support for vgpu](https://forums.unraid.net/topic/176087-nouveau-driver-update-and-support-for-vgpu/)

移植到 Unraid 的难点：

| 环节 | Proxmox | Unraid 现状 |
|---|---|---|
| 内核模块 | pve-headers + dkms 现成 | Unraid 内核需支持 mdev/vfio-mdev（PVE 默认编译，Unraid 需确认，通常要装 Nvidia 驱动插件后才有 dkms 环境） |
| vgpu_unlock-rs | systemd drop-in 注入 | Unraid 用 rc 脚本/`/boot/config` 方式注入 LD_PRELOAD 到 `nvidia-vgpud`/`nvidia-vgpu-mgr` 服务 |
| mdev 管理 | mdevctl（apt 安装） | 需自行编译/安装 mdevctl |
| VM 挂载 mdev | Proxmox UI 原生支持 | Unraid VM 模板需手动填 mdev 设备 XML |

## 9. 结论

- 这个项目是**当前社区在 Proxmox 上做 NVIDIA vGPU 的事实标准教程**，补丁覆盖 14.2→19.0 全部常用驱动分支，维护活跃（580.65.05 为最新）。
- 核心机制：**按驱动版本打二进制补丁（改内核模块）+ vgpu_unlock-rs 用户态 hook（改配置返回）+ profile 覆盖（改规格）**，三者缺一不可。
- 硬性前提：**Turing 及更老架构的卡**（RTX 20xx 及以下），RTX 30/40 系消费卡无解。
- 对 Unraid 用户：方案整体可移植，社区已有插件，但 Unraid 内核的 mdev 支持是需要先行验证的关键点。

## 参考链接

- 仓库：https://gitlab.com/polloloco/vgpu-proxmox
- vgpu_unlock-rs：https://github.com/mbilker/vgpu_unlock-rs
- 原版 vgpu_unlock（内核钩子）：https://github.com/DualCoder/vgpu_unlock
- FastAPI-DLS 许可证服务器：https://git.collinwebdesigns.de/oscar.krause/fastapi-dls
- Unraid vGPU 插件：https://github.com/stl88083365/unraid-nvidia-vgpu-driver
- NVIDIA vGPU 支持卡列表：https://docs.nvidia.com/grid/gpus-supported-by-vgpu.html
