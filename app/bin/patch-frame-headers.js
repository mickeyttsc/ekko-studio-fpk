#!/usr/bin/env node
// fnOS 桌面小窗（iframe）嵌入修复补丁
//
// 根因：上游 hermes-web-ui 对 / 下发
//   X-Frame-Options: DENY + CSP frame-ancestors 'none'
// fnOS 桌面图标小窗模式（ui/config type=iframe）把 http://<host>:8648/ 嵌进
// 桌面窗口 iframe，浏览器按上述响应头直接拒绝渲染 → 窗口空白/报错。
// 上游没有 env 开关，唯一解法是改 dist/server/index.js。
//
// 补丁内容：
//   XFO DENY -> ALLOWALL（Chromium 忽略该非标值，实际由 CSP frame-ancestors 管控）
//   CSP frame-ancestors 'none' -> 白名单（fnOS 桌面各入口源）
//
// 白名单为什么动态生成：
//   CSP 的 host-source 不支持 IP 通配/CIDR，写死几个 IP 必然漏。而 fnOS 桌面的
//   父页面来源 = 用户访问桌面时用的那个 host：可能是内网 IPv4、IPv6 字面量
//   （家宽 IPv4 是 CGNAT，外网全靠 IPv6）、或反代域名。故每次运行时用
//   os.networkInterfaces() 收录【本机当前地址】，cmd/main 每次启动都重跑本脚本
//   → 地址漂移（SLAAC 前缀变化）自动跟上。
//
// 幂等/可刷新：首次匹配 "frame-ancestors 'none'"；已打过则刷新我们生成的那条
//   （只认 "frame-ancestors 'self' " 形式，绝不碰上游 DSH 代理中间件的
//    "frame-ancestors 'self';" —— 它 'self' 后没有空格）。
const fs = require('fs');
const os = require('os');

const TARGET = process.argv[2];
// --static-only: 只写「与机器无关」的白名单（域名/localhost），不枚举本机地址。
// 构建期用它，避免把 CI runner 的地址烤进产物（曾实测把 <BUILD-IP>/fe80::… 写进包，
// 而运行时旧脚本又不会刷新 → 真实入口 <LAN-IP>/全局 IPv6 反而被 CSP 拦）。
const STATIC_ONLY = process.argv.includes('--static-only');
if (!TARGET) { console.error('usage: patch-frame-headers.js <index.js>'); process.exit(2); }
if (!fs.existsSync(TARGET)) { console.error('not found: ' + TARGET); process.exit(1); }

let s = fs.readFileSync(TARGET, 'utf8');

// ── 组装白名单 ──────────────────────────────────────────────────────────────
const origins = new Set([
  "'self'",
  'http://localhost:*', 'https://localhost:*',
  'http://127.0.0.1:*', 'https://127.0.0.1:*',
  'http://[::1]:*', 'https://[::1]:*',
  // 用户自有域名（fnOS 桌面直连/反代入口）+ FN Connect 中继
  'http://example.com:*', 'https://example.com:*',
  'http://*.example.com:*', 'https://*.example.com:*',
  'http://example-relay.com:*', 'https://example-relay.com:*',
  'http://*.example-relay.com:*', 'https://*.example-relay.com:*',
  'http://*.example-cloud.net:*', 'https://*.example-cloud.net:*',
]);

// 本机当前地址（IPv4 + IPv6 字面量；IPv6 必须带方括号）
// 过滤：virtual 网桥/容器网卡（docker*/br-*/veth*/virbr* 等）与链路本地 fe80:: ——
// 这些不是用户访问桌面时用的来源，写进白名单只是噪音（本机实测会涌入十几个）。
const VIRTUAL_IFACE_RE = /^(docker|br-|veth|virbr|tun|tap|wg|kube|flannel|cali|nerdctl|lo$)/;
function addHost(addr, family) {
  const isV6 = String(family) === 'IPv6' || String(family) === '6';
  if (isV6 && /^fe80:/i.test(addr)) return;   // 链路本地 IPv6 不可能是父页面来源
  const host = isV6 ? '[' + addr + ']' : addr;
  origins.add('http://' + host + ':*');
  origins.add('https://' + host + ':*');
}
if (!STATIC_ONLY) {
  try {
    const ifaces = os.networkInterfaces();
    for (const name of Object.keys(ifaces)) {
      if (VIRTUAL_IFACE_RE.test(name)) continue;
      for (const ni of ifaces[name] || []) {
        if (ni.internal) continue;
        addHost(ni.address, ni.family);
      }
    }
  } catch (e) {
    console.warn('WARN: cannot enumerate interfaces: ' + e.message);
  }
}

const LIST = Array.from(origins).join(' ');
const NEW_DIRECTIVE = 'frame-ancestors ' + LIST;

let n = 0;

// 1) X-Frame-Options: DENY -> ALLOWALL
s = s.replace(/"X-Frame-Options","DENY"/g, () => { n++; return '"X-Frame-Options","ALLOWALL"'; });

// 2) 首次：frame-ancestors 'none' -> 白名单
s = s.replace(/frame-ancestors 'none'/g, () => { n++; return NEW_DIRECTIVE; });

// 3) 刷新：已打过的那条（"frame-ancestors 'self' <origins>"）重算本机地址
s = s.replace(/frame-ancestors 'self' [^";]*/g, () => { n++; return NEW_DIRECTIVE; });

if (n === 0) {
  console.log('already patched, no change');
} else {
  const bak = TARGET + '.bak-prepatch';
  if (!fs.existsSync(bak)) fs.copyFileSync(TARGET, bak);
  fs.writeFileSync(TARGET, s);
  console.log('patched, replacements: ' + n);
}

// 回读验证
const after = fs.readFileSync(TARGET, 'utf8');
const ok = (b) => (b ? 'yes' : 'NO(bad)');
console.log('verify XFO DENY remaining: ' + ok(!after.includes('"X-Frame-Options","DENY"')));
console.log('verify frame-ancestors none remaining: ' + ok(!/frame-ancestors 'none'/.test(after)));
console.log('verify ALLOWALL present: ' + ok(after.includes('"X-Frame-Options","ALLOWALL"')));
const m = after.match(/frame-ancestors 'self' [^";]*/);
console.log('whitelist entries: ' + (m ? m[0].split(/\s+/).length - 1 : 0));
