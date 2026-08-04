#!/bin/bash
# ==========================================================
# XUI-VPS Podman 宿主机卸载脚本（非交互版，供面板远程调用）
# 用法:
#   bash podman-uninstall.sh
# ==========================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}==================================================${NC}"
echo -e "${RED}  🗑  Podman 宿主机环境卸载脚本                     ${NC}"
echo -e "${BLUE}==================================================${NC}"

# 1. 停止并删除所有容器
echo -e "${YELLOW}[1/5] 🛑 停止并删除所有容器...${NC}"
podman stop -a 2>/dev/null || true
podman rm -af 2>/dev/null || true

# 2. 卸载 Podman 软件包（保留数据以便反悔？不——按需彻底清理）
echo -e "${YELLOW}[2/5] 📦 卸载 Podman 及相关依赖...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

case "$OS" in
    debian|ubuntu)
        apt-get remove -y --purge podman 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        ;;
    alpine)
        apk del podman 2>/dev/null || true
        ;;
    centos|rhel|rocky|almalinux)
        yum remove -y podman 2>/dev/null || true
        ;;
    fedora)
        dnf remove -y podman 2>/dev/null || true
        ;;
    *)
        echo -e "${YELLOW}⚠️  未能自动识别包管理器，请手动卸载 podman。${NC}"
        ;;
esac

# 3. 卸载挂载的 XFS 存储池并删除镜像文件
echo -e "${YELLOW}[3/5] 💾 卸载 XFS 存储池并清理...${NC}"
XFS_IMG="/var/podman-xfs.img"
XFS_MOUNT="/var/lib/containers/storage"
umount "$XFS_MOUNT" 2>/dev/null || true
if grep -q "$XFS_IMG" /etc/fstab 2>/dev/null; then
    sed -i "\|$XFS_IMG|d" /etc/fstab
    echo -e "${GREEN}    ✅ 已从 /etc/fstab 移除挂载条目${NC}"
fi
rm -f "$XFS_IMG"
rm -rf "$XFS_MOUNT" /var/lib/containers 2>/dev/null || true
rm -rf /etc/containers 2>/dev/null || true
rm -f /etc/sysctl.d/99-podman-network.conf 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true

# 4. 清理 iptables 相关规则（Podman 生成的链）
echo -e "${YELLOW}[4/5] 🔥 清理 iptables 规则...${NC}"
# 只清理 podman 相关链，不动其他用户规则
for chain in PODMAN PODMAN-INGRESS; do
    iptables -F "$chain" 2>/dev/null || true
    iptables -X "$chain" 2>/dev/null || true
    iptables -t nat -F "$chain" 2>/dev/null || true
    iptables -t nat -X "$chain" 2>/dev/null || true
done
iptables -t nat -F CNI-* 2>/dev/null || true
iptables -t nat -X CNI-* 2>/dev/null || true
iptables -t filter -F CNI-* 2>/dev/null || true
iptables -t filter -X CNI-* 2>/dev/null || true

# 5. 收尾提示
echo -e "${BLUE}--------------------------------------------------${NC}"
echo -e "${GREEN}  🎉 Podman 环境已卸载！${NC}"
echo -e "${YELLOW}  ⚠️  若仍残留容器数据或镜像，请手动检查 /var/lib/containers${NC}"
echo -e "${BLUE}==================================================${NC}"
