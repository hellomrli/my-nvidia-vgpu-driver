#!/bin/bash
# =============================================================================
# Unraid Tesla P4 vGPU Merged Driver 安装脚本
# 驱动版本: 535.309.01 (vGPU 16.14 LTS) | 内核: 6.18.44-Unraid
# 驱动包: 从 https://github.com/hellomrli/my-nvidia-vgpu-driver/releases
#         下载与本机内核 (uname -r) 对应的 nvidia-*.txz，放在本脚本同目录
#
# 功能:
#   1. 安装 merged driver（宿主 docker/CUDA/OpenGL + VM vGPU 双用）
#   2. 配置 vGPU 环境（mdevctl、udev 规则）
#   3. 配置 nvidia-gridd license (FastAPI-DLS)
#   4. 配置 docker 容器 GPU 支持
#
# 用法: 在 Unraid 终端执行  sh install-nvidia-vgpu.sh
# =============================================================================

set -e

KERNEL_REL="6.18.44-Unraid"

echo "=================================================="
echo " Unraid NVIDIA vGPU Merged Driver 安装"
echo " 驱动: 535.309.01 (vGPU 16.14 LTS)"
echo " 内核: ${KERNEL_REL}"
echo "=================================================="

# 0. 检查内核匹配
CUR_KERNEL=$(uname -r)
if [ "$CUR_KERNEL" != "$KERNEL_REL" ]; then
    echo "[!] 警告: 当前内核 ${CUR_KERNEL} 与驱动包内核 ${KERNEL_REL} 不匹配！"
    echo "    vGPU 驱动模块必须与运行内核完全一致。"
    echo "    请确认 Unraid 版本（内核 ${KERNEL_REL} 对应 Unraid 7.x 最新版）"
    read -p "    继续安装？(y/N) " ans
    [ "${ans,,}" != "y" ] && exit 1
fi

# 1. 安装驱动包（自动识别当前目录下最新的 nvidia-*.txz）
echo "[1/7] 安装驱动包..."
PKG_NAME="$(ls ./nvidia-*.txz 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "${PKG_NAME}" ]; then
    echo "错误: 当前目录没有 nvidia-*.txz 驱动包。"
    echo "请从 https://github.com/hellomrli/my-nvidia-vgpu-driver/releases/tag/${KERNEL_REL}"
    echo "下载与本机内核 (${KERNEL_REL}) 对应的驱动包，放到本脚本同目录后重试。"
    exit 1
fi
echo "    找到驱动包: ${PKG_NAME}"
if command -v installpkg >/dev/null 2>&1; then
    installpkg ./"${PKG_NAME}"
else
    # 手动解压安装
    echo "    installpkg 不可用，手动解压..."
    tar -xJf "${PKG_NAME}" -C / --owner=root --group=root
fi

# 2. 加载内核模块
echo "[2/7] 加载内核模块..."
modprobe mdev 2>/dev/null || true
modprobe vfio 2>/dev/null || true
modprobe vfio_iommu_type1 2>/dev/null || true
modprobe vfio_mdev 2>/dev/null || true
modprobe nvidia
modprobe nvidia-vgpu-vfio
modprobe nvidia-uvm
modprobe nvidia-modeset 2>/dev/null || true

# 3. 配置模块自动加载
echo "[3/7] 配置开机自动加载..."
cat > /etc/modules-load.d/nvidia-vgpu.conf <<'EOF'
nvidia
nvidia-vgpu-vfio
nvidia-uvm
nvidia-modeset
EOF

# 4. 配置 nvidia-vgpud / nvidia-vgpu-mgr 服务
echo "[4/7] 配置 vGPU 守护进程..."
if [ -d /etc/systemd/system ]; then
    mkdir -p /etc/systemd/system/nvidia-vgpud.service.d
    mkdir -p /etc/systemd/system/nvidia-vgpu-mgr.service.d
    # 如果使用 vgpu_unlock-rs（本包 P4 原生支持，无需 unlock，此步可跳过）
    # echo -e "[Service]\nEnvironment=LD_PRELOAD=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so" > /etc/systemd/system/nvidia-vgpud.service.d/vgpu_unlock.conf
    # echo -e "[Service]\nEnvironment=LD_PRELOAD=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so" > /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable nvidia-vgpud 2>/dev/null || true
    systemctl enable nvidia-vgpu-mgr 2>/dev/null || true
    systemctl start nvidia-vgpud 2>/dev/null || true
    systemctl start nvidia-vgpu-mgr 2>/dev/null || true
else
    echo "    (无 systemd，请手动启动 nvidia-vgpud / nvidia-vgpu-mgr)"
fi

# 5. 配置 nvidia-gridd (license, 可跳过)
echo "[5/7] 配置 nvidia-gridd license..."
read -p "    FastAPI-DLS license 服务器地址 (回车跳过, 例如 192.168.1.100): " LICENSE_SERVER || true
if [ -n "${LICENSE_SERVER}" ]; then
    read -p "    端口 [443]: " LICENSE_PORT || true
    LICENSE_PORT="${LICENSE_PORT:-443}"
    read -p "    FeatureType 0=vPC 1=vWS 2=vDWS/Q系列 [2]: " FEATURE_TYPE || true
    FEATURE_TYPE="${FEATURE_TYPE:-2}"
    case "${FEATURE_TYPE}" in 0|1|2) ;; *) FEATURE_TYPE="2" ;; esac
    if [ -f /etc/nvidia/gridd.conf.template ] && [ ! -f /etc/nvidia/gridd.conf ]; then
        cat > /etc/nvidia/gridd.conf <<EOF
ServerAddress=${LICENSE_SERVER}
ServerPort=${LICENSE_PORT}
FeatureType=${FEATURE_TYPE}
EnableUI=FALSE
EOF
        echo "    已生成 /etc/nvidia/gridd.conf (ServerAddress=${LICENSE_SERVER}:${LICENSE_PORT}, FeatureType=${FEATURE_TYPE})"
    else
        echo "    gridd.conf 已存在或模板缺失, 跳过 (如需修改请编辑 /etc/nvidia/gridd.conf)"
    fi
else
    echo "    未填 license 服务器, 跳过 (vGPU 需要 license 才能完整使用, 可稍后配置 /etc/nvidia/gridd.conf)"
fi

# 6. 配置 docker GPU 支持
echo "[6/7] 配置 docker..."
if [ -f /usr/bin/nvidia-ctk ]; then
    /usr/bin/nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
fi
# 确保 /etc/docker/daemon.json 包含 nvidia runtime
# 绝不整文件覆盖已有配置（可能含 registry-mirrors 等）；文件不存在时才写最小配置
if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
elif ! grep -q '"nvidia"' /etc/docker/daemon.json 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
        tmp=$(mktemp)
        jq '.runtimes = ((.runtimes // {}) + {nvidia: {path: "nvidia-container-runtime", runtimeArgs: []}})' /etc/docker/daemon.json > "$tmp" 2>/dev/null \
            && mv "$tmp" /etc/docker/daemon.json \
            && echo "    已把 nvidia runtime 合并进 /etc/docker/daemon.json" \
            || { rm -f "$tmp"; echo "    [!] 合并 /etc/docker/daemon.json 失败, 请手动添加 nvidia runtime"; }
    else
        echo "    [!] /etc/docker/daemon.json 已存在且无 nvidia runtime, 且无 jq, 请手动合并"
    fi
fi
echo "    提示: docker 服务正在运行时, 需重启 docker 服务后 nvidia runtime 才生效"

# 7. 验证
echo "[7/7] 验证..."
sleep 2
echo "--- nvidia-smi ---"
nvidia-smi 2>/dev/null || echo "nvidia-smi 未找到，检查 /usr/bin/nvidia-smi"
echo "--- 模块状态 ---"
lsmod | grep -E "nvidia" || echo "(模块未加载)"
echo "--- mdev 类型 (vGPU profile) ---"
if command -v mdevctl >/dev/null 2>&1; then
    mdevctl types 2>/dev/null | grep -A5 "nvidia" | head -20 || echo "(mdevctl types 无输出，请检查 nvidia-vgpud/nvidia-vgpu-mgr 服务)"
else
    echo "(mdevctl 未安装 - vGPU 管理需要，请安装)"
fi

echo ""
echo "=================================================="
echo " 安装完成！"
echo " 下一步:"
echo "  1. 确认 nvidia-smi 显示 Tesla P4"
echo "  2. 确认 mdevctl types 列出 GRID P4 的 vGPU profile"
echo "  3. 如需 VM 使用 vGPU: 在 VM 配置中添加 Mediated Device"
echo "  4. docker 容器加 --gpus all 即可使用 GPU"
echo "=================================================="
