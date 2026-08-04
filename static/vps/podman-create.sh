#!/bin/bash
# ==========================================================
# XUI-VPS Podman 小鸡创建脚本（非交互版，供面板远程调用）
# 用法:
#   bash podman-create.sh --name client-01 --pass Lijx.820115 \
#        [--cpus 1.0] [--mem 256] [--disk 5] [--bw 10] \
#        [--ssh-port 1000] [--port-range 1001-1100]
# ==========================================================
set -e

NAME=""; ROOT_PASS=""; CPU_LIMIT="1.0"; MEM_LIMIT="256"; DISK_LIMIT="5"; BANDWIDTH_MBPS="10"; SSH_PORT="1000"; PORT_RANGE="1001-1100"

while [ "$#" -gt 0 ]; do
    case $1 in
        --name) [ "$#" -ge 2 ] || { echo "--name 缺少参数"; exit 1; }; NAME="$2"; shift 2 ;;
        --pass) [ "$#" -ge 2 ] || { echo "--pass 缺少参数"; exit 1; }; ROOT_PASS="$2"; shift 2 ;;
        --cpus) [ "$#" -ge 2 ] || { echo "--cpus 缺少参数"; exit 1; }; CPU_LIMIT="$2"; shift 2 ;;
        --mem) [ "$#" -ge 2 ] || { echo "--mem 缺少参数"; exit 1; }; MEM_LIMIT="$2"; shift 2 ;;
        --disk) [ "$#" -ge 2 ] || { echo "--disk 缺少参数"; exit 1; }; DISK_LIMIT="$2"; shift 2 ;;
        --bw) [ "$#" -ge 2 ] || { echo "--bw 缺少参数"; exit 1; }; BANDWIDTH_MBPS="$2"; shift 2 ;;
        --ssh-port) [ "$#" -ge 2 ] || { echo "--ssh-port 缺少参数"; exit 1; }; SSH_PORT="$2"; shift 2 ;;
        --port-range) [ "$#" -ge 2 ] || { echo "--port-range 缺少参数"; exit 1; }; PORT_RANGE="$2"; shift 2 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

if [ -z "$NAME" ] || [ -z "$ROOT_PASS" ]; then
    echo "❌ 错误: 缺少必要参数 --name 或 --pass"
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# 1. 架构检测与匹配镜像绑定
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

# 2. 检查镜像是否存在，不存在则拉取
if ! podman image exists "${IMAGE_URL}"; then
    echo -e "${YELLOW}⚠️ 未在本地检测到镜像，正在自动补充拉取...${NC}"
    podman pull "${IMAGE_URL}"
fi

echo -e "${BLUE}=================================================="${NC}
echo -e "${GREEN}      🚀 Podman 极速开鸡工具 [系统架构: ${ARCH_TYPE}]"${NC}
echo -e "${BLUE}=================================================="${NC}

SWAP_LIMIT=$((MEM_LIMIT * 2))

# 构建带宽控制参数
BANDWIDTH_FLAGS=""
if [ "$BANDWIDTH_MBPS" -gt 0 ]; then
    BANDWIDTH_BPS=$((BANDWIDTH_MBPS * 1000000))
    BANDWIDTH_FLAGS="--annotation org.netavark.port_bandwidth.ingress_rate=${BANDWIDTH_BPS} --annotation org.netavark.port_bandwidth.egress_rate=${BANDWIDTH_BPS}"
    BANDWIDTH_DISPLAY="${BANDWIDTH_MBPS} Mbps (上下行对称)"
else
    BANDWIDTH_DISPLAY="无限制"
fi

# 构建磁盘限额参数
XFS_MOUNT="/var/lib/containers/storage"
FS_CHECK=$(df -T "$XFS_MOUNT" 2>/dev/null | awk 'NR==2 {print $2}')
STORAGE_FLAGS=""
if [[ "$FS_CHECK" == "xfs" ]]; then
    STORAGE_FLAGS="--storage-opt size=${DISK_LIMIT}G"
    DISK_DISPLAY="${DISK_LIMIT} GB (XFS 硬件限制)"
else
    DISK_DISPLAY="${DISK_LIMIT} GB (非 XFS 环境，已跳过限额)"
fi

echo -e "\n${BLUE}--------------------------------------------------"${NC}
echo -e "${YELLOW}📋 即将创建的小鸡配置如下：${NC}"
echo -e "  * 容器名称 : ${GREEN}${NAME}${NC}"
echo -e "  * CPU 配额 : ${GREEN}${CPU_LIMIT} 核${NC}"
echo -e "  * 内存大小 : ${GREEN}${MEM_LIMIT} MB${NC} (Swap: ${SWAP_LIMIT} MB)"
echo -e "  * 磁盘容量 : ${GREEN}${DISK_DISPLAY}${NC}"
echo -e "  * 网络限速 : ${GREEN}${BANDWIDTH_DISPLAY}${NC}"
echo -e "  * SSH 端口 : ${GREEN}${SSH_PORT}${NC} -> 容器 22/tcp"
echo -e "  * 业务端口 : ${GREEN}${PORT_RANGE}${NC} -> 容器 ${PORT_RANGE} (TCP + UDP 双协议)"
echo -e "${BLUE}--------------------------------------------------"${NC}

echo -e "\n${YELLOW}⚡ 正在基于本地镜像拉起容器...${NC}"

# 发现同名容器自动清理
if podman ps -a --format "{{.Names}}" | grep -q "^${NAME}$"; then
    echo -e "${YELLOW}  ⚠ 清理同名容器 ${NAME}...${NC}"
    podman rm -f "${NAME}" >/dev/null 2>&1 || true
fi

# 秒级启动容器（指定同时映射 TCP 和 UDP）
podman run -d \
  --name "${NAME}" \
  --cpus="${CPU_LIMIT}" \
  --memory="${MEM_LIMIT}m" \
  --memory-swap="${SWAP_LIMIT}m" \
  ${STORAGE_FLAGS} \
  ${BANDWIDTH_FLAGS} \
  --systemd=always \
  --cap-add=SYS_ADMIN \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -p "${SSH_PORT}:22/tcp" \
  -p "${PORT_RANGE}:${PORT_RANGE}/tcp" \
  -p "${PORT_RANGE}:${PORT_RANGE}/udp" \
  --restart always \
  "${IMAGE_URL}" /sbin/init

# ============================================================
# 宿主机防火墙放行（容器端口映射需要 INPUT + FORWARD 双链放行）
# ============================================================
echo -e "\n${YELLOW}🔥 放行宿主机防火墙端口（INPUT + FORWARD，TCP + UDP）...${NC}"
PORT_START=$(echo "${PORT_RANGE}" | cut -d- -f1)
PORT_END=$(echo "${PORT_RANGE}" | cut -d- -f2)
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -p tcp --dport "${PORT_START}:${PORT_END}" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p udp --dport "${PORT_START}:${PORT_END}" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p tcp --dport "${PORT_START}:${PORT_END}" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p udp --dport "${PORT_START}:${PORT_END}" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p tcp --dport "${PORT_START}:${PORT_END}" -m state --state NEW -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p udp --dport "${PORT_START}:${PORT_END}" -m state --state NEW -j ACCEPT 2>/dev/null || true
    iptables -I INPUT 1 -p tcp --dport "${SSH_PORT}" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
        echo -e "${GREEN}  ✅ 防火墙规则已持久化（netfilter-persistent）${NC}"
    else
        echo -e "${YELLOW}  ⚠ 未找到 netfilter-persistent，规则重启后可能失效；${NC}"
    fi
    echo -e "${GREEN}  ✅ 宿主机防火墙已放行 ${PORT_RANGE}（TCP+UDP，INPUT+FORWARD）${NC}"
else
    echo -e "${YELLOW}  ⚠ 未找到 iptables，跳过防火墙配置（请确认云安全组已放行端口）${NC}"
fi

# 写入 SSH 密码
podman exec "${NAME}" sh -c "echo 'root:${ROOT_PASS}' | chpasswd"

echo -e "\n${GREEN}=================================================="${NC}
echo -e "${GREEN}  🎉 小鸡 ${NAME} 秒级创建成功！"${NC}
echo -e "${GREEN}=================================================="${NC}
echo -e "${CYAN}🔑 SSH 连接 : ssh root@宿主机IP -p ${SSH_PORT}${NC}"
echo -e "${CYAN}🔑 登录密码 : ${ROOT_PASS}${NC}"
echo -e "${CYAN}🌐 业务端口 : ${PORT_RANGE} (TCP/UDP 同时开放)${NC}"
echo -e "${BLUE}=================================================="${NC}
