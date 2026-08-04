// server.js — Self-hosted XUI server (VPS / Docker)
// Runs the Cloudflare Worker API on Node: /api/* -> onRequest(),
// static files -> static/, cron -> onRequestScheduled(), no Durable Objects
// (agents fall back to HTTP polling, the dashboard uses its polling fallback).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Client } from 'ssh2';
import { WebSocketServer } from 'ws';
import { openDatabase } from './db.js';
import { onRequest, onRequestScheduled } from './functions/api/[[path]].js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const STATIC_DIR = path.join(__dirname, 'static');
const DB_PATH = process.env.DATABASE_PATH || path.join(__dirname, 'data', 'xui.db');
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '0.0.0.0';

// ---------------------------------------------------------------------------
// Cloudflare Cache API 兼容层（探针接口 /api/probe/public 使用 caches.default）
// Node.js 无 caches 全局对象，这里用内存 Map 提供 match/put/delete。
// ---------------------------------------------------------------------------
if (!globalThis.caches) {
    const cacheStore = new Map();
    const cacheKeyOf = (req) => (typeof req === 'string' ? req : (req && req.url) || String(req));
    globalThis.caches = {
        default: {
            async match(req) {
                const key = cacheKeyOf(req);
                const hit = cacheStore.get(key);
                if (!hit) return undefined;
                // 按 Cache-Control max-age 检查过期（CF Cache API 语义）
                const cc = String(hit.headers && hit.headers['cache-control'] || '');
                const m = cc.match(/max-age=(\d+)/);
                if (m && Date.now() - hit.ts >= Number(m[1]) * 1000) {
                    cacheStore.delete(key);
                    return undefined;
                }
                return new Response(hit.body, { status: 200, headers: hit.headers });
            },
            async put(req, res) {
                try {
                    const body = await res.clone().text();
                    cacheStore.set(cacheKeyOf(req), { body, headers: Object.fromEntries(res.headers.entries()), ts: Date.now() });
                    if (cacheStore.size > 200) { const first = cacheStore.keys().next().value; if (first) cacheStore.delete(first); }
                } catch (e) {}
            },
            async delete(req) { return cacheStore.delete(cacheKeyOf(req)); },
        },
    };
}

// ---------------------------------------------------------------------------
// Database (D1-compatible over SQLite)
// ---------------------------------------------------------------------------
const db = openDatabase(DB_PATH);

// ---------------------------------------------------------------------------
// ASSETS adapter — serves files from static/ (used by /api/agent_update and
// the dashboard frontend). Mimics Workers Assets fetch().
// ---------------------------------------------------------------------------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.sh': 'text/plain; charset=utf-8',
  '.py': 'text/plain; charset=utf-8',
  '.yaml': 'text/plain; charset=utf-8',
  '.yml': 'text/plain; charset=utf-8',
  '.woff2': 'font/woff2',
};
const assetsAdapter = {
  async fetch(request) {
    // Cloudflare ASSETS.fetch 可传 URL 对象或 Request；这里兼容两者
    const url = new URL(typeof request === 'string' ? request : (request instanceof URL ? request.href : request.url));
    let rel = decodeURIComponent(url.pathname).replace(/^\/+/, '');
    if (!rel) rel = 'index.html';
    // Path traversal guard
    const filePath = path.resolve(STATIC_DIR, rel);
    if (filePath !== path.join(STATIC_DIR, 'index.html') && !filePath.startsWith(STATIC_DIR + path.sep)) {
      return new Response('Not found', { status: 404 });
    }
    try {
      const data = fs.readFileSync(filePath);
      const ext = path.extname(filePath).toLowerCase();
      return new Response(data, {
        headers: {
          'Content-Type': MIME[ext] || 'application/octet-stream',
          'Cache-Control': 'no-cache',
          'X-Content-Type-Options': 'nosniff',
        },
      });
    } catch (e) {
      return new Response('Not found', { status: 404 });
    }
  },
};

// ---------------------------------------------------------------------------
// Podman SSH 执行器 — 面板通过已保存的 SSH 凭据远程执行脚本/命令
// (自托管版独有；Cloudflare Worker 版无 ssh2，前端会提示不可用)
// ---------------------------------------------------------------------------
function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

async function podmanExec(ip, scriptContent, args, timeoutMs) {
  const row = await db.prepare('SELECT ssh_user, ssh_pass, ssh_port FROM servers WHERE ip = ?').bind(ip).first();
  if (!row || !row.ssh_pass) throw new Error('未配置 SSH 凭据，请先在服务器卡片填写');
  const sshPort = Number(row.ssh_port) || 22;
  const argStr = (args || []).map(shellQuote).join(' ');
  // 自举：部分精简系统没有 bash/curl/wget —— 先用 sh（保证存在）安装缺失工具，
  // 再 exec bash 执行喂入的脚本（stdin 缓冲的脚本内容在 exec 后继续被 bash 读取）。
  const bootstrap = `command -v bash >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq bash curl wget >/dev/null 2>&1; elif command -v apk >/dev/null 2>&1; then apk add --no-cache bash curl wget >/dev/null 2>&1; elif command -v yum >/dev/null 2>&1; then yum install -y -q bash curl wget >/dev/null 2>&1; fi; }; command -v curl >/dev/null 2>&1 || { if command -v apt-get >/dev/null 2>&1; then apt-get install -y -qq curl >/dev/null 2>&1; elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl >/dev/null 2>&1; fi; }; exec bash -s -- ${argStr}`;
  const cmd = `sh -c ${shellQuote(bootstrap)}`;
  return await new Promise((resolve, reject) => {
    const conn = new Client();
    let output = '';
    let settled = false;
    let timer;
    const finish = (ok, exitCode, extra) => {
      if (settled) return; settled = true;
      clearTimeout(timer);
      try { conn.end(); } catch (_) {}
      resolve({ ok, output: output + (extra || ''), exitCode });
    };
    conn.on('ready', () => {
      conn.exec(cmd, (err, stream) => {
        if (err) { finish(false, -1, '\n[exec error] ' + (err.message || '')); return; }
        stream.on('close', (code) => finish(true, code))
              .on('data', (d) => { output += d.toString(); })
              .stderr.on('data', (d) => { output += d.toString(); });
        // 通过 stdin 把脚本内容喂给 bash -s
        if (scriptContent) { stream.write(scriptContent); }
        stream.end();
      });
    });
    conn.on('error', (e) => { if (!settled) { clearTimeout(timer); reject(new Error('SSH: ' + (e.message || '连接失败'))); } });
    timer = setTimeout(() => finish(false, -1, '\n[timeout after ' + Math.round((timeoutMs || 600000) / 1000) + 's]'), timeoutMs || 600000);
    conn.connect({ host: ip, port: sshPort, username: row.ssh_user || 'root', password: row.ssh_pass, readyTimeout: 15000 });
  });
}

// ---------------------------------------------------------------------------
// Environment (what the Worker would get from Cloudflare bindings)
// ---------------------------------------------------------------------------
const env = {
  DB: db,
  ASSETS: assetsAdapter,
  ADMIN_USERNAME: process.env.ADMIN_USERNAME || 'admin',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || 'admin',
  PROXY_USER: process.env.PROXY_USER || '',
  PROXY_PASS: process.env.PROXY_PASS || '',
  TG_BOT_TOKEN: process.env.TG_BOT_TOKEN || '',
  TG_CHAT_ID: process.env.TG_CHAT_ID || '',
  TG_WEBHOOK_SECRET: process.env.TG_WEBHOOK_SECRET || '',
  CRON_SECRET: process.env.CRON_SECRET || '',
  PAGES_ORIGIN: process.env.PAGES_ORIGIN || '',
  // Leave empty: notifyRealtimeVps() becomes a no-op and agents use HTTP polling.
  REALTIME_URL: process.env.REALTIME_URL || '',
  // Podman SSH 执行器（自托管版注入；Cloudflare Worker 版为 undefined）
  podmanExec,
  ...(process.env.PROXY_CTRL_URL
    ? {
        PROXY_CTRL_URL: process.env.PROXY_CTRL_URL,
        PROXY_CTRL_USER: process.env.PROXY_CTRL_USER || '',
        PROXY_CTRL_PASS: process.env.PROXY_CTRL_PASS || '',
        PROXY_CTRL_TOKEN: process.env.PROXY_CTRL_TOKEN || '',
      }
    : {}),
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function apiParams(pathname) {
  const segments = pathname.slice('/api/'.length).split('/').filter(Boolean);
  return { path: segments };
}

function nodeRequestToWebRequest(req) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (v !== undefined) headers[k] = v;
  }
  let body;
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    body = new Promise((resolve, reject) => {
      const chunks = [];
      req.on('data', c => chunks.push(c));
      req.on('end', () => resolve(Buffer.concat(chunks)));
      req.on('error', reject);
    });
  }
  return { url, headers, body };
}

async function sendWebResponse(res, response) {
  res.statusCode = response.status;
  for (const [k, v] of response.headers.entries()) {
    if (k.toLowerCase() === 'content-length') continue; // let Node compute
    res.setHeader(k, v);
  }
  if (response.body) {
    Readable.fromWeb(response.body).pipe(res);
  } else {
    res.end();
  }
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  try {
    const { url, headers, body } = nodeRequestToWebRequest(req);
    const request = new Request(url, {
      method: req.method,
      headers,
      body: req.method !== 'GET' && req.method !== 'HEAD' ? await body : undefined,
    });

    if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
      const response = await onRequest({
        request,
        env,
        params: apiParams(url.pathname),
        waitUntil: () => {},
      });
      return await sendWebResponse(res, response);
    }

    if (url.pathname === '/health') {
      const response = new Response(JSON.stringify({ ok: true, service: 'xui-vps', version: 1 }), {
        headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
      });
      return await sendWebResponse(res, response);
    }

    // Everything else: static assets
    const response = await assetsAdapter.fetch(request);
    return await sendWebResponse(res, response);
  } catch (e) {
    console.error('[xui-vps] request error:', e);
    if (!res.headersSent) {
      res.statusCode = 500;
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.end('Internal Server Error: ' + (e.message || e));
    } else {
      res.end();
    }
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[xui-vps] listening on http://${HOST}:${PORT}`);
  console.log(`[xui-vps] database: ${DB_PATH}`);
  console.log(`[xui-vps] static:   ${STATIC_DIR}`);
});

// ---------------------------------------------------------------------------
// WebSocket — WebSSH 隧道 (前端 xterm.js <-> ssh2)
// URL: /ssh/ws?ip=<VPS_IP>&token=<登录token>
// ---------------------------------------------------------------------------
const sha256 = (s) => createHash('sha256').update(String(s)).digest('hex');
const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname !== '/ssh/ws') { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, (ws) => handleSshWebSocket(ws, url));
});

async function handleSshWebSocket(ws, url) {
  const ip = url.searchParams.get('ip') || '';
  const token = url.searchParams.get('token') || '';
  try {
    // 校验登录会话
    const session = await db.prepare('SELECT username, expires_at FROM auth_sessions WHERE token_hash = ?').bind(sha256(token)).first();
    if (!session || Number(session.expires_at) < Date.now()) { ws.close(4001, 'Unauthorized'); return; }
    const row = await db.prepare('SELECT ssh_user, ssh_pass, ssh_port FROM servers WHERE ip = ?').bind(ip).first();
    if (!row || !row.ssh_pass) { ws.close(4002, '未配置 SSH 凭据，请先在服务器卡片填写'); return; }
    const sshPort = Number(row.ssh_port) || 22;
    const conn = new Client();
    conn.on('ready', () => {
      conn.shell({ term: 'xterm-256color', cols: 120, rows: 32 }, (err, stream) => {
        if (err) { ws.close(4003, 'Shell error: ' + err.message); return; }
        stream.on('data', (d) => { try { ws.send(d.toString('utf8')); } catch (_) {} });
        stream.on('close', () => { try { ws.close(); } catch (_) {} });
        stream.on('error', () => { try { ws.close(); } catch (_) {} });
        ws.on('message', (m) => { stream.write(String(m)); });
        ws.on('close', () => { stream.end(); conn.end(); });
        ws.on('error', () => { stream.end(); conn.end(); });
      });
    });
    conn.on('error', (e) => { try { ws.close(4004, 'SSH: ' + (e.message || '连接失败')); } catch (_) {} });
    conn.connect({ host: ip, port: sshPort, username: row.ssh_user || 'root', password: row.ssh_pass, readyTimeout: 15000 });
  } catch (e) {
    try { ws.close(4000, 'Server error'); } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Cron — offline check every 15 minutes (mimics Worker Cron */15 * * * *)
// ---------------------------------------------------------------------------
const CRON_MS = 15 * 60 * 1000;
setInterval(() => {
  onRequestScheduled({ scheduledTime: Date.now(), cron: '*/15 * * * *', env, waitUntil: () => {} })
    .catch(e => console.error('[xui-vps] cron offline check failed:', e));
}, CRON_MS).unref?.();

// Graceful shutdown
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[xui-vps] ${sig} received, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}
