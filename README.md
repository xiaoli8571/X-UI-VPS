# XUI-VPS — 自托管代理节点管理面板（VPS / Docker）

XUI 代理节点管理面板的**自托管版本**：把 Cloudflare Worker 版（D1 + Durable Objects + Workers Assets）移植到 **Node.js + SQLite**，任何 VPS 都能跑（**x86 / ARM 通吃**），无需 Cloudflare 账号、**无请求额度限制**。

> 配合 VPS 上的 agent 组件（`static/vps/xui.sh` 一键部署的 sing-box 环境）使用，节点"8合1"一键下发、Clash 订阅、住宅代理开关、探针监控全兼容。

---

## ✨ 功能特性

| 功能 | 说明 |
|---|---|
| 🖥 节点管理 | 8合1 协议一键下发（XTLS+Reality / Hysteria2 / TUIC / Trojan / H2+Reality / gRPC+Reality / AnyTLS / Naive）、Clash 订阅、节点开关/流量清零 |
| 📦 服务器管理 | **宿主机 + 容器**（Podman/LXC 共享公网 IP，同 IP 不同名称可添加）；VPS **导入/导出**（JSON/CSV） |
| 🖥 **WebSSH** | 每台机器配置 SSH 凭据，**浏览器一键打开终端**（xterm.js + ssh2） |
| 🤖 Telegram 机器人 | `/nodes` `/proxy` `/stats` `/deploy8` 远程控制 + 失联告警 + **域名到期提醒**（可设多个提醒时间点） |
| 🔗 第三方节点 | 机场订阅整体导入 **或 手动单独添加节点**（VLESS/VMess/Trojan/Hy2/AnyTLS/SS 等 12 种协议），自动融合进统一订阅 |
| 📊 用户授权 | 用户流量/时间限制，订阅导入 Clash/mihomo **显示剩余流量与到期时间**（Subscription-Userinfo） |
| 🔀 界面优化 | 节点矩阵、VPS 卡片**收起/展开**，一页多显示几台服务器 |
| 🔐 安全 | 面板密码、TG Webhook 密钥、住宅代理凭据全部可配 |

---

## 🚀 快速部署（一键安装脚本）

```bash
# 1. 克隆项目
git clone https://github.com/xiaoli8571/X-UI-VPS.git
cd X-UI-VPS

# 2. 一键安装（自动检测/安装 Node 24、安装依赖、创建 systemd 服务）
bash deploy/xui-panel.sh install
```

安装完成输出面板地址与账号，默认端口 **18787**。

> 需要 **Node >= 22.5**（`node:sqlite` 内置）；脚本会自动下载安装 Node 24（amd64/arm64）。

### 一键脚本其他命令

```bash
bash deploy/xui-panel.sh port 18788          # 修改面板端口
bash deploy/xui-panel.sh password '新密码'    # 修改管理员密码
bash deploy/xui-panel.sh https on            # 启用 HTTPS（自动安装 Caddy 反代，需域名）
bash deploy/xui-panel.sh https off           # 关闭 HTTPS
bash deploy/xui-panel.sh status              # 查看服务状态
bash deploy/xui-panel.sh log                 # 查看日志
bash deploy/xui-panel.sh uninstall           # 一键卸载（删除服务与数据）
```

---

## 🐳 Docker 部署（可选）

```bash
# 构建（自动适配 amd64/arm64）
docker build -t xui-vps .

# 运行
docker run -d --name xui-vps --restart unless-stopped \
  -p 18787:8787 -v xui-data:/data \
  -e ADMIN_PASSWORD='你的强密码' \
  xui-vps

# 或 docker compose
docker compose up -d
```

---

## 🔧 手动部署（不用脚本）

```bash
# 1. 安装 Node 24（缺 xz 先 apt install -y xz-utils）
curl -fsSL -o /tmp/node.tar.xz https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-$(uname -m | sed 's/x86_64/x64/').tar.xz
tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1

# 2. 安装依赖（纯 JS，无编译）
npm install --omit=dev --no-audit --no-fund

# 3. 启动（可配合 systemd，unit 模板见 deploy/xui-vps.service）
PORT=18787 nohup node server.js > /var/log/xui-vps.log 2>&1 &
```

---

## ⚙️ 环境变量（`.env` 或 systemd/docker 注入）

| 变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | 8787 | 监听端口 |
| `HOST` | 0.0.0.0 | 监听地址 |
| `DATABASE_PATH` | ./data/xui.db | SQLite 数据库路径 |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | admin / admin | **公网部署务必修改！** |
| `PROXY_USER` / `PROXY_PASS` | 空 | 住宅代理凭据（配置后自动启用） |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` / `TG_WEBHOOK_SECRET` | 空 | Telegram 机器人（面板设置里也可配置） |
| `PAGES_ORIGIN` | 空 | 面板域名（TG webhook 注册用） |
| `CRON_SECRET` | 空 | 外部触发离线检查的密钥 |

---

## 📖 使用指南

### 面板登录
浏览器打开 `http://<VPS_IP>:18787`，默认 `admin / admin`（**登录后立即修改密码**）。

### 接入代理节点（VPS 上安装 agent）
1. 「服务器与节点」→ 添加服务器（名称 + IP）
2. 复制卡片底部的 **Full Deploy Command**，在目标 VPS 上执行
3. 等 agent 上报在线后，点「🚀 极速全量节点下发 (8合1)」生成 8 个协议节点

### WebSSH
1. 服务器卡片点「🔑 SSH」→ 填写该机的 SSH 账号密码端口 → 保存
2. 点「🖥 WebSSH」→ 浏览器直接打开终端

### 宿主机 + 容器
Podman/LXC 容器与宿主机共享公网 IP 时，**用不同名称分别添加**即可（同 IP 不同名允许，完全相同才拒绝）。

### 订阅
- 管理员与用户均有专属订阅链接（面板内复制）
- Clash/mihomo 订阅会显示 **剩余流量 / 到期时间**（用户级）
- 手动添加的第三方节点自动融合进统一订阅

### 域名到期提醒
「⚙️ 系统设置」→「域名到期提醒」→ 添加域名、到期日期、提前提醒天数（可多个，如 `7,3,1`）→ 到期前 TG 机器人自动提醒。

---

## ⚠️ 常见问题

- **外部访问打不开**：VPS 有多个"防火墙"——云厂商安全组 + 本机 ufw/iptables/nftables。放行端口示例：
  ```bash
  iptables -I INPUT 1 -p tcp --dport 18787 -j ACCEPT && netfilter-persistent save
  ```
- **agent 连不上**：Full Deploy Command 里的地址用 `http://<VPS_IP>:18787`，确保 VPS 能访问该地址
- **没有实时刷新**：VPS 版无 Cloudflare Durable Objects 实时推送，面板自动用 60s 轮询兜底（探针/状态正常显示）
- **HTTP 还是 HTTPS**：面板默认 HTTP；生产建议 `bash xui-panel.sh https on`（配 Caddy 自动证书）或前置 Nginx/Caddy 反代

---

## 🔒 安全清单（部署后必做）

1. `bash deploy/xui-panel.sh password '强密码'`（或设 `ADMIN_PASSWORD` 环境变量）
2. 建议反代 HTTPS + 防火墙只放行面板端口
3. 住宅代理凭据 `PROXY_USER/PROXY_PASS` 设为强 Secret
4. 配置 TG 机器人时设置 `TG_WEBHOOK_SECRET`

## 项目结构

```
├── server.js              # Node 服务入口（HTTP + 静态 + WebSSH WebSocket）
├── db.js                  # D1 兼容层（node:sqlite）
├── functions/api/[[path]].js  # 面板全部 API（与 Cloudflare 版同源）
├── static/                # 前端面板 + VPS agent 组件（xui.sh 等）
├── deploy/
│   ├── xui-panel.sh       # 一键安装/卸载/改端口/改密码/HTTPS 脚本
│   └── xui-vps.service    # systemd 模板
├── Dockerfile             # 多架构镜像（amd64/arm64）
└── docker-compose.yml
```
