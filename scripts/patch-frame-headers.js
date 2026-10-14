#!/usr/bin/env node
// fnOS 桌面小窗（iframe）嵌入修复补丁
// 上游 hermes-web-ui 对 / 下 X-Frame-Options: DENY + CSP frame-ancestors 'none'，
// 导致 fnOS 桌面 iframe 小窗无法嵌入（窗口报错/空白）。
// 补丁：XFO 改 ALLOWALL（Chromium 忽略非标值，改由 CSP frame-ancestors 管控），
// CSP frame-ancestors 'none' 改为白名单（fnOS 桌面各入口源）。
// 幂等：重复执行无副作用；每次升级 bundled 后可重新执行自愈。
const fs = require('fs');

const TARGET = process.argv[2];
if (!TARGET) { console.error('usage: patch-frame-headers.js <index.js>'); process.exit(2); }
if (!fs.existsSync(TARGET)) { console.error('not found: ' + TARGET); process.exit(1); }

let s = fs.readFileSync(TARGET, 'utf8');

const ORIGINS = [
  "'self'",
  'http://<LAN-IP>:*',
  'https://<LAN-IP>:*',
  'http://localhost:*',
  'https://localhost:*',
  'http://127.0.0.1:*',
  'https://127.0.0.1:*',
  'http://*.example-relay.com:*',
  'https://*.example-relay.com:*',
  'http://*.example-cloud.net:*',
  'https://*.example-cloud.net:*',
].join(' ');

let n = 0;

// 1) X-Frame-Options: DENY -> ALLOWALL
s = s.replace(/"X-Frame-Options","DENY"/g, () => { n++; return '"X-Frame-Options","ALLOWALL"'; });

// 2) CSP frame-ancestors 'none' -> 白名单
s = s.replace(/frame-ancestors 'none'/g, () => { n++; return 'frame-ancestors ' + ORIGINS; });

if (n === 0) {
  console.log('already patched (no DENY/none found), no change');
} else {
  const bak = TARGET + '.bak-prepatch';
  if (!fs.existsSync(bak)) fs.copyFileSync(TARGET, bak);
  fs.writeFileSync(TARGET, s);
  console.log('patched, replacements: ' + n);
}

// 回读验证
const after = fs.readFileSync(TARGET, 'utf8');
console.log('verify XFO DENY remaining: ' + (after.includes('"X-Frame-Options","DENY"') ? 'YES(bad)' : 'no'));
console.log('verify frame-ancestors none remaining: ' + (/frame-ancestors 'none'/.test(after) ? 'YES(bad)' : 'no'));
console.log('verify ALLOWALL present: ' + (after.includes('"X-Frame-Options","ALLOWALL"') ? 'yes' : 'NO(bad)'));
