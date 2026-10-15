#!/usr/bin/env node
// gw-bridge.mjs — fnOS 统一网关桥（Ekko Studio）
//
// 链路：桌面/手机小窗 → fnOS 统一网关（路径 /app/hermes-studio）→ 本文件的 unix
// socket → 127.0.0.1:<PORT>（hermes-web-ui）。
//
// 为什么需要它（2026-10-15 实测）：
//   端口型入口（ui/config 写 port）在 fnOS Connect（远程访问）下会走
//   https://<app>.<域名>/ 子域路由，本机实测该路由不可达（浏览器报
//   ERR_CONNECTION_REFUSED）；而「统一网关 + 路径型入口」是 fnOS 自家应用与
//   已验证可远程的第三方应用（wild-work）使用的形态：主域名 + /app/<name> 路径，
//   由系统转发到应用自己的 unix socket。故本应用也接同一形态。
//
// 行为（与 wild-work 的 wwbridge 对齐，用 Node 实现，随包分发）：
//   · 路径以 <prefix>/ 开头 → 剥掉前缀后转发给本地端口（网关转来时带前缀）
//   · 路径恰为 <prefix>（无尾斜杠）→ 301 补斜杠，保证页面基址正确
//   · 不带前缀 → 原样透传（兼容 cgi 链路已剥前缀 / 直连探测）
//   · WebSocket（Socket.IO 必需）→ 原始 upgrade 透传，双向管道
//   · Host/Origin 同源对齐 + 缺失的 Sec-Fetch-* 注入（HTTP 非安全上下文下
//     浏览器不发该头，上游 CSRF 判定会误拦 POST；与 wwbridge 同款处理）
//   · 残留 socket 探测：无人监听则接管，有人监听则退出（防双开）
//
// 用法: gw-bridge.mjs <socketPath> <prefix> <host:port>
//   例: gw-bridge.mjs /var/apps/hermes-studio/target/app.sock /app/hermes-studio 127.0.0.1:8648

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';

const [, , sockPath, prefixArg = '', tcpAddr] = process.argv;
if (!sockPath || !tcpAddr || !tcpAddr.includes(':')) {
  console.error('usage: gw-bridge.mjs <socketPath> <prefix> <host:port>');
  process.exit(2);
}
let prefix = prefixArg.startsWith('/') ? prefixArg : '/' + prefixArg;
prefix = prefix.replace(/\/+$/, '');
const [upHost, upPort] = tcpAddr.split(':');

function log(...a) {
  console.error(`[${new Date().toISOString()}] gw-bridge:`, ...a);
}

// 前缀剥离：返回 {path} 或 {redirect}
function routePath(p) {
  if (!prefix) return { path: p };
  if (p === prefix) return { redirect: p + '/' };
  if (p.startsWith(prefix + '/')) return { path: p.slice(prefix.length) };
  return { path: p };
}

// Host / Origin 同源对齐（wwbridge 同款）：
//  · 入口 Host 无端口而 Origin 有端口、且主机名一致 → 把端口补回转发 Host
//  · 主机名一致 + 浏览器 UA + 原生缺 Sec-Fetch-Site → 注入 same-origin
function normalizeHeaders(headers, rawPath) {
  const h = { ...headers };
  const entryHost = h.host || 'localhost';
  const origin = h.origin || '';
  let aligned = entryHost;
  try {
    if (origin) {
      const u = new URL(origin);
      const oHost = u.hostname;
      const entryNoPort = entryHost.includes(']')
        ? entryHost.slice(0, entryHost.indexOf(']') + 1)
        : entryHost.split(':')[0];
      const sameHost = oHost.toLowerCase() === entryNoPort.replace(/^\[|\]$/g, '').toLowerCase();
      const browser = /Mozilla/i.test(h['user-agent'] || '');
      if (sameHost && browser) {
        const entryHasPort = entryHost.includes(']')
          ? /:\d+$/.test(entryHost.slice(entryHost.indexOf(']')))
          : entryHost.includes(':');
        if (!entryHasPort && u.port) aligned = `${entryHost}:${u.port}`;
        if (!h['sec-fetch-site']) {
          h['sec-fetch-site'] = 'same-origin';
          if (!h['sec-fetch-mode']) h['sec-fetch-mode'] = 'cors';
          if (!h['sec-fetch-dest']) h['sec-fetch-dest'] = 'empty';
        }
      }
    }
  } catch { /* Origin 非 URL：不动 */ }
  h.host = aligned;
  if (!h['x-forwarded-host']) h['x-forwarded-host'] = aligned;
  if (!h['x-forwarded-proto']) h['x-forwarded-proto'] = 'http';
  if (!h['x-forwarded-for']) h['x-forwarded-for'] = h['x-real-ip'] || '127.0.0.1';
  return h;
}

const agent = new http.Agent({ keepAlive: true, maxSockets: 64 });

function proxyHttp(req, res) {
  const r = routePath(req.url.split('?')[0]);
  if (r.redirect) {
    const q = req.url.includes('?') ? req.url.slice(req.url.indexOf('?')) : '';
    res.writeHead(301, { Location: r.redirect + q });
    res.end();
    return;
  }
  const target = (req.url.startsWith(prefix + '/') ? r.path : req.url) || '/';
  const headers = normalizeHeaders(req.headers, target);
  const up = http.request(
    { host: upHost, port: Number(upPort), method: req.method, path: target, headers, agent },
    (upRes) => {
      res.writeHead(upRes.statusCode || 502, upRes.headers);
      upRes.pipe(res);
    },
  );
  up.on('error', (err) => {
    log(`upstream ${tcpAddr}: ${err.message}`);
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('Ekko Studio is not reachable');
  });
  req.pipe(up);
}

function proxyUpgrade(req, socket, head) {
  const r = routePath(req.url.split('?')[0]);
  const target = (req.url.startsWith(prefix + '/') ? r.path : req.url) || '/';
  const headers = normalizeHeaders(req.headers, target);
  headers.connection = 'Upgrade';
  headers.upgrade = req.headers.upgrade || 'websocket';

  const up = net.connect(Number(upPort), upHost, () => {
    const lines = [`${req.method} ${target} HTTP/1.1`];
    for (const [k, v] of Object.entries(headers)) {
      if (Array.isArray(v)) for (const vv of v) lines.push(`${k}: ${vv}`);
      else if (v !== undefined) lines.push(`${k}: ${v}`);
    }
    up.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) up.write(head);
    socket.pipe(up).pipe(socket);
  });
  up.on('error', (err) => {
    log(`upgrade ${target}: ${err.message}`);
    try { socket.destroy(); } catch { /* ignore */ }
  });
  socket.on('error', () => { try { up.destroy(); } catch { /* ignore */ } });
}

const server = http.createServer(proxyHttp);
server.on('upgrade', proxyUpgrade);
server.on('clientError', (err, socket) => {
  try { socket.destroy(); } catch { /* ignore */ }
});

function listen() {
  const srv = server.listen(sockPath, () => {
    try { fs.chmodSync(sockPath, 0o666); } catch { /* 权限不足非致命：fnOS 进程多在 root */ }
    log(`listening ${sockPath} (prefix=${prefix || '-'}) -> ${tcpAddr}`);
  });
  srv.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && fs.existsSync(sockPath)) {
      // 残留 socket：探测是否真的有人监听
      const probe = net.connect(sockPath);
      probe.on('connect', () => {
        probe.destroy();
        log(`socket ${sockPath} already served by another instance — exiting`);
        process.exit(3);
      });
      probe.on('error', () => {
        try { fs.unlinkSync(sockPath); } catch { /* ignore */ }
        log(`stale socket removed, retrying`);
        listen();
      });
      return;
    }
    log(`listen ${sockPath} failed: ${err.message}`);
    process.exit(1);
  });
}
listen();

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    try { fs.unlinkSync(sockPath); } catch { /* ignore */ }
    process.exit(0);
  });
}
