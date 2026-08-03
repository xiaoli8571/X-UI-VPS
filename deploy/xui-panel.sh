#!/usr/bin/env bash
# =============================================================================
# XUI-VPS 面板管理脚本（一键部署 / 卸载 / 改端口 / HTTPS / 改密码）
# 用法:
#   bash xui-panel.sh install                 # 一键部署（装 Node + systemd 服务）
#   bash xui-panel.sh uninstall               # 一键卸载
#   bash xui-panel.sh port 18787              # 修改面板端口
#   bash xui-panel.sh password '新密码'        # 修改面板管理员密码
#   bash xui-panel.sh https on                # 启用 HTTPS（自动装 Caddy 反代）
#   bash xui-panel.sh https off               # 关闭 HTTPS（移除 Caddy）
#   bash xui-panel.sh status                  # 查看服务状态
#   bash xui-panel.sh log                     # 查看日志
# =============================================================================
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/xui-vps}"
SERVICE_NAME="xui-vps"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_PORT="${PORT:-18787}"
ADMIN_USER="${ADMIN_USERNAME:-admin}"
ADMIN_PASS="${ADMIN_PASSWORD:-admin}"

log()  { echo -e "\033[1;32m[xui]\033[0m $*"; }
warn() { echo -e "\033[1;33m[xui!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[xui✗]\033[0m $*"; exit 1; }

ensure_root() { [ "$(id -u)" = "0" ] || err "请以 root 运行: sudo bash xui-panel.sh $*"; }

write_unit() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XUI VPS Panel (self-hosted)
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=PORT=${CUR_PORT:-$DEFAULT_PORT}
Environment=NODE_ENV=production
Environment=ADMIN_USERNAME=$ADMIN_USER
Environment=ADMIN_PASSWORD=$ADMIN_PASS
ExecStart=/usr/local/bin/node server.js
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_node() {
    if command -v node >/dev/null 2>&1 && [ "$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -ge 22 ]; then
        log "Node 已安装: $(node --version)"
        return
    fi
    log "安装 Node 24 (amd64/arm64)..."
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "不支持的架构: $(uname -m)" ;;
    esac
    if ! command -v xz >/dev/null 2>&1; then
        log "安装 xz-utils..."
        apt-get update -qq && apt-get install -y -qq xz-utils
    fi
    cd /tmp
    curl -fsSL -o node.tar.xz "https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-${arch}.tar.xz"
    tar -xJf node.tar.xz -C /usr/local --strip-components=1
    log "Node 安装完成: $(node --version)"
}

cmd_install() {
    ensure_root
    log "==> 开始部署 XUI-VPS 面板"
    # 1) 确保本脚本所在目录有代码（脚本应放在项目 deploy/ 下或与 server.js 同目录）
    if [ ! -f "$APP_DIR/server.js" ]; then
        mkdir -p "$APP_DIR"
        SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        log "复制代码 $SRC_DIR -> $APP_DIR"
        cp -r "$SRC_DIR"/{server.js,db.js,package.json,package-lock.json,functions,static,realtime,src,README.md} "$APP_DIR/" 2>/dev/null || cp -r "$SRC_DIR"/. "$APP_DIR/"
    fi
    install_node
    log "安装依赖..."
    cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund
    log "创建 systemd 服务..."
    CUR_PORT="${PORT:-$DEFAULT_PORT}" write_unit
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl is-active "$SERVICE_NAME" >/dev/null || err "服务启动失败，查看日志: bash xui-panel.sh log"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    log "✅ 部署成功！"
    log "   面板地址: http://${ip:-<VPS_IP>}:$DEFAULT_PORT"
    log "   默认账号: $ADMIN_USER / $ADMIN_PASS（请立即修改密码！）"
    log "   修改密码: bash xui-panel.sh password '新密码'"
    warn "生产环境建议: bash xui-panel.sh https on （启用 HTTPS）"
}

cmd_uninstall() {
    ensure_root
    read -r -p "确定要卸载 XUI-VPS 吗？将停止服务并删除 $APP_DIR（数据库一并删除）[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "已取消"; exit 0; }
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -rf "$APP_DIR"
    systemctl daemon-reload
    log "✅ 已卸载（如安装了 Caddy 请手动移除: systemctl stop caddy && apt remove -y caddy）"
}

cmd_port() {
    ensure_root
    [ $# -ge 1 ] || err "用法: bash xui-panel.sh port <端口>"
    local new_port="$1"
    [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ] || err "端口无效: $new_port"
    # 从现有 unit 读取当前端口
    local cur=""
    if [ -f "$SERVICE_FILE" ]; then
        cur="$(grep -oP 'Environment=PORT=\K[0-9]+' "$SERVICE_FILE" | head -1)"
    fi
    CUR_PORT="$new_port" write_unit
    systemctl restart "$SERVICE_NAME"
    log "✅ 面板端口已改为 $new_port（服务已重启）"
    if [ "$(command -v caddy >/dev/null 2>&1 && echo yes)" = "yes" ] && [ -f /etc/caddy/Caddyfile ]; then
        grep -q "reverse_proxy" /etc/caddy/Caddyfile && systemctl restart caddy && log "Caddy 反代已同步重启"
    fi
}

cmd_password() {
    ensure_root
    [ $# -ge 1 ] || err "用法: bash xui-panel.sh password '新密码'"
    local new_pass="$1"
    [ "${#new_pass}" -ge 8 ] || err "密码至少 8 位"
    local cur=""
    if [ -f "$SERVICE_FILE" ]; then
        cur="$(grep -oP 'Environment=PORT=\K[0-9]+' "$SERVICE_FILE" | head -1)"
    fi
    ADMIN_PASS="$new_pass" CUR_PORT="${cur:-$DEFAULT_PORT}" write_unit
    systemctl restart "$SERVICE_NAME"
    log "✅ 面板管理员密码已修改并重启（用户: $ADMIN_USER）"
    warn "请牢记新密码！"
}

cmd_https() {
    ensure_root
    [ $# -ge 1 ] || err "用法: bash xui-panel.sh https on|off"
    local mode="$1"
    local cur=""
    if [ -f "$SERVICE_FILE" ]; then
        cur="$(grep -oP 'Environment=PORT=\K[0-9]+' "$SERVICE_FILE" | head -1)"
    fi
    CUR_PORT="${cur:-$DEFAULT_PORT}"
    if [ "$mode" = "on" ]; then
        if ! command -v caddy >/dev/null 2>&1; then
            log "安装 Caddy..."
            apt-get update -qq && apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
            apt-get update -qq && apt-get install -y -qq caddy
        fi
        read -r -p "请输入面板域名（如 panel.example.com，需已解析到本机）: " domain
        [ -n "$domain" ] || err "域名不能为空"
        mkdir -p /etc/caddy
        cat > /etc/caddy/Caddyfile <<EOF
$domain {
    reverse_proxy 127.0.0.1:$CUR_PORT
}
EOF
        systemctl restart caddy
        sleep 2
        systemctl is-active caddy >/dev/null || warn "Caddy 启动失败，查看: journalctl -u caddy -n 30"
        log "✅ HTTPS 已启用: https://$domain （自动申请证书，请确保域名解析到本机）"
    elif [ "$mode" = "off" ]; then
        systemctl stop caddy 2>/dev/null || true
        rm -f /etc/caddy/Caddyfile
        log "✅ HTTPS 已关闭（Caddy 已停止）"
    else
        err "用法: bash xui-panel.sh https on|off"
    fi
}

cmd_status() { systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -20; }
cmd_log()    { journalctl -u "$SERVICE_NAME" -n 100 --no-pager; }

case "${1:-}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    port)      shift; cmd_port "$@" ;;
    password)  shift; cmd_password "$@" ;;
    https)     shift; cmd_https "$@" ;;
    status)    cmd_status ;;
    log)       cmd_log ;;
    *) echo "用法: bash xui-panel.sh {install|uninstall|port|password|https|status|log}"; exit 1 ;;
esac
