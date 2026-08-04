#!/bin/bash
# ==========================================================
# XUI-VPS Podman 宿主机一键初始化（非交互版，供面板远程调用）
# 用法:
#   bash podman-install.sh [--pool-size 20]
#   --pool-size : XFS 虚拟磁盘池大小(GB)，默认 20
# ==========================================================
set -e

POOL_SIZE_GB=20
while [ "$#" -gt 0 ]; do
    case $1 in
        --pool-size) [ "$#" -ge 2 ] || { echo "--pool-size 缺少参数"; exit 1; }; POOL_SIZE_GB="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${BLUE}=================================================="${NC}
echo -e "${GREEN}  🚀 Podman 宿主机环境初始化 & 镜像预拉取脚本     "${NC}
echo -e "${BLUE}=================================================="${NC}

# 1. 架构检测与镜像地址绑定
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        ARCH_TYPE="x86_64"
        IMAGE_URL="registry.cn-guangzhou.aliyuncs.com/xiaoli_image/alpine-xui-x86:latest"
        ;;
    aarch64|arm64)
        ARCH_TYPE="arm64"
        IMAGE_URL="registry.cn-guangzhou.aliyuncs.com/xiaoli_image/alpine-xui:latest"
        ;;
    *)
        echo -e "${RED}❌ 不支持的系统架构: $ARCH${NC}"
        exit 1
        ;;
esac
echo -e "${GREEN}[1/4] 🔍 系统架构检测通过: ${ARCH_TYPE} ($ARCH)${NC}"

# 2. 软件依赖安装
echo -e "${YELLOW}[2/4] 📦 正在安装 Podman / iproute2 / xfsprogs ...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

case "$OS" in
    debian|ubuntu)
        apt-get update -y && apt-get install -y podman iptables curl iproute2 xfsprogs file
        ;;
    alpine)
        apk update && apk add podman iptables curl iproute2 xfsprogs file
        ;;
    centos|rhel|rocky|almalinux)
        yum install -y podman iptables curl iproute xfsprogs file
        ;;
    fedora)
        dnf install -y podman iptables curl iproute xfsprogs file
        ;;
    *)
        echo -e "${RED}❌ 未能自动识别包管理器，请确保已手动安装 podman 与 xfsprogs。${NC}"
        ;;
esac

# 3. TUN 设备与网络内核优化
echo -e "${YELLOW}[3/4] ⚙ 正在配置 TUN 虚拟网卡与网络内核优化...${NC}"
modprobe tun 2>/dev/null || true
mkdir -p /dev/net
[ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200
chmod 0666 /dev/net/tun

if [ -d /etc/modules-load.d ]; then
    echo "tun" > /etc/modules-load.d/tun.conf
elif [ -f /etc/modules ]; then
    grep -q "^tun" /etc/modules || echo "tun" >> /etc/modules
fi

cat << 'SYSCONF' > /etc/sysctl.d/99-podman-network.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
SYSCONF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-podman-network.conf >/dev/null 2>&1 || true

mkdir -p /etc/containers
if [ ! -f /etc/containers/registries.conf ]; then
    cat << 'REGCONF' > /etc/containers/registries.conf
unqualified-search-registries = ["docker.io", "quay.io", "registry.cn-guangzhou.aliyuncs.com"]
REGCONF
fi

# 4. XFS 存储池检查与初始化
XFS_IMG="/var/podman-xfs.img"
XFS_MOUNT="/var/lib/containers/storage"

mkdir -p "$XFS_MOUNT"
FS_TYPE=$(df -T "$XFS_MOUNT" 2>/dev/null | awk 'NR==2 {print $2}')

if [[ "$FS_TYPE" != "xfs" ]]; then
    echo -e "\n${BLUE}--------------------------------------------------"${NC}
    echo -e "${YELLOW}⚠️ 准备生成 XFS 虚拟文件系统以支持磁盘硬限额 (--storage-opt size=)。${NC}"
    echo -e "    分配总容量: ${POOL_SIZE_GB} GB"
    echo -e "${BLUE}--------------------------------------------------"${NC}

    echo -e "${YELLOW}⚡ 正在生成 ${POOL_SIZE_GB}GB 的 XFS 镜像文件...${NC}"
    truncate -s "${POOL_SIZE_GB}G" "$XFS_IMG"

    echo -e "${YELLOW}⚙ 正在格式化 XFS 文件系统...${NC}"
    mkfs.xfs -f "$XFS_IMG"

    podman stop -a 2>/dev/null || true
    podman system reset --force 2>/dev/null || true

    echo -e "${YELLOW}🔗 正在挂载 XFS 池 (启用 prjquota 配额)...${NC}"
    mount -o loop,prjquota "$XFS_IMG" "$XFS_MOUNT"

    if ! grep -q "$XFS_IMG" /etc/fstab; then
        echo "$XFS_IMG $XFS_MOUNT xfs loop,prjquota 0 0" >> /etc/fstab
    fi
fi

# 5. 自动根据架构提前拉取镜像
echo -e "\n${YELLOW}[4/4] 📥 正在为架构 [${ARCH_TYPE}] 预先拉取黄金镜像...${NC}"
echo -e "${CYAN}拉取目标: ${IMAGE_URL}${NC}"
podman pull "${IMAGE_URL}"

echo -e "\n${GREEN}=================================================="${NC}
echo -e "${GREEN}  🎉 宿主机环境初始化完成！Podman 与镜像已就绪。  "${NC}
echo -e "${GREEN}=================================================="${NC}
