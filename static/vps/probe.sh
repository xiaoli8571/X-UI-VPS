#!/bin/sh
# =============================================================
# XUI 探针接入脚本 —— 宿主机只安装探针（平台观察状态），不装代理
# 用法: curl -fsSL -H "Authorization: <token>" "<api>/api/agent_update?ip=<ip>&component=probe-installer" | sh -s -- --api "<api>" --ip "<ip>" --token "<token>"
# =============================================================
set -e

API_URL=""
IP=""
TOKEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --api) API_URL="$2"; shift 2 ;;
        --ip) IP="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -n "$API_URL" ] || { echo "缺少 --api"; exit 1; }
[ -n "$IP" ] || { echo "缺少 --ip"; exit 1; }
[ -n "$TOKEN" ] || { echo "缺少 --token"; exit 1; }

echo "[probe] 安装探针（只上报状态，不装代理）..."

# 需要 python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "[probe] 安装 python3..."
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq python3 curl
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 curl
    else echo "不支持的包管理器，请手动安装 python3"; exit 1; fi
fi

mkdir -p /opt/xui

# ============ 清理旧完整版 agent 环境（sing-box 代理 + 旧服务 + 旧文件） ============
echo "[probe] 清理旧代理环境（sing-box / 旧 agent / 旧配置）..."
# 停止并移除 sing-box 代理（代理现在跑在容器里，宿主机不再需要）
systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
rc-service sing-box stop 2>/dev/null
rm -rf /etc/sing-box
rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box
# 停止旧 agent 服务（后面会用 PROBE_ONLY=1 重新安装）
systemctl stop xui-agent 2>/dev/null; systemctl disable xui-agent 2>/dev/null
rc-service xui-agent stop 2>/dev/null
# 清除更新标记与旧代理组件/证书（config.json 会被覆盖重写）
rm -f /opt/xui/.update-pending
rm -f /opt/xui/*.pem /opt/xui/*.key /opt/xui/warp.json /opt/xui/egress-state.json \
      /opt/xui/traffic-state.json /opt/xui/realtime_client.py /opt/xui/lite_manager.py \
      /opt/xui/proxy_server.py /opt/xui/run-agent.sh 2>/dev/null
systemctl daemon-reload 2>/dev/null || true
echo "[probe] 旧环境已清理"

# 下载探针 agent（agent.py 探针模式 = 只上报状态）
echo "[probe] 下载 agent.py..."
curl -fsSL -H "Authorization: $TOKEN" "$API_URL/api/agent_update?ip=$IP&component=agent" -o /opt/xui/agent.py
chmod +x /opt/xui/agent.py

# 探针模式配置（probe_only=true → 不构建 sing-box）
python3 - "$API_URL" "$IP" "$TOKEN" <<'PY'
import json, sys, os
api, ip, token = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {"api_url": api + "/api/config", "report_url": api + "/api/report", "ip": ip, "token": token, "probe_only": True}
path = "/opt/xui/config.json"
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(cfg, f)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print("[probe] 探针模式配置已写入 /opt/xui/config.json")
PY

# systemd 服务
cat > /etc/systemd/system/xui-agent.service <<EOF
[Unit]
Description=XUI Serverless Agent (probe-only)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/xui
Environment=PROBE_ONLY=1
ExecStart=$(command -v python3) /opt/xui/agent.py
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xui-agent >/dev/null 2>&1 || true
systemctl restart xui-agent

sleep 2
if systemctl is-active xui-agent >/dev/null 2>&1; then
    echo "[probe] ✅ 探针已接入: $IP （面板探针大盘将显示该机器状态）"
    echo "[probe] 查看日志: journalctl -u xui-agent -f"
else
    echo "[probe] 服务启动失败，查看: journalctl -u xui-agent -n 30"
    exit 1
fi
