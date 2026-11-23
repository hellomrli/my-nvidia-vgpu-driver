# 构建与发布 NVIDIA 包

本页面向驱动包维护者。实际安装使用[管理插件](https://github.com/hellomrli/my-unraid-vgpu-manager)，构建脚本用于准备内核匹配的 `.txz`。

## 使用自动任务

[check-updates.yml](../.github/workflows/check-updates.yml) 每周三 UTC 01:17（北京时间 09:17）检查官方正式版、公开 beta/RC 和 ich777 最新内核。每个内核分别核对 16.x 与 19.x 的最新有效完整包，缺少时派发 [build-nvidia.yml](../.github/workflows/build-nvidia.yml)。

每周检查可减少对驱动镜像站的请求，但不能保证镜像站不再返回 HTTP 403。需要及时检查新驱动或内核时，在 GitHub Actions 选择更新检查工作流并点击 **Run workflow** 手动运行。

手动构建需使 `driver_version`、`vgpu_branch`、`windows_version` 和可选的 `alist_pkg_dir` 对应同一版本布局。`kernel_release=latest` 表示解析 ich777 最新内核，不是对所有内核构建。

默认构建号自动递增；有完整同版本包时跳过。主动重建使用新的构建号和资产名，不覆盖既有包。并发锁按内核与驱动版本区分。

## 本地构建入口

准备 Linux、GCC/G++、make、bc、bison、flex、libelf、curl、Git、tar、xz、kmod、Python 3 等工具，具体版本见工作流。

以下命令示范固定的 R535 与已发布内核组合，会下载驱动和内核源码并生成 `out/`：

```bash
git clone https://github.com/hellomrli/my-nvidia-vgpu-driver.git
cd my-nvidia-vgpu-driver
VERSION=535.309.01 \
TARGET_KERNEL_VERSION=6.18.60 \
KERNEL_RELEASE=6.18.60-Unraid \
scripts/build-nvidia-driver.sh
```

调整版本时还需调整其源布局与校验和。GRID 客户端包和 vGPU KVM 宿主包在部分 R580 分支具有不同小版本，不能只替换 `VERSION`。

## 提供源文件

[build-nvidia-driver.sh](../scripts/build-nvidia-driver.sh) 接受 `GRID_RUN_URL`、`VGPU_RUN_URL`，也支持下载目录中的对应 `.run`。显式 URL 优先，随后尝试配置中的镜像和 GitHub Release 源资产。

`RUN_MIRROR_REPO`、`RUN_MIRROR_TAG`、`RUN_MIRROR_BASE` 可切换备用源。脚本检查大小、文件签名和 HTML 挑战页；HTTP 200 本身不能证明下载的是安装包。已知版本配置校验和，其他版本需维护者提供并核对。

## 检查产物与工具

包命名为 `nvidia-版本-完整内核-构建号.txz`，与 `.md5` 配对后才视为完整发布。输出还含构建记录，安装时完整内核必须相同。

已有离线工具检查可在仓库根目录运行：

```bash
python3 -m unittest discover -s tests -v
```

真实构建和更新检查需要联网与较大源码归档。返回[文档索引](index.md)。
