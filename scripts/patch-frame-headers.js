#!/usr/bin/env node
// fnOS 桌面小窗（iframe）嵌入修复补丁
//
// 根因：上游 hermes-web-ui 对 / 下发
//   X-Frame-Options: DENY + CSP frame-ancestors 'none'
// fnOS 桌面图标小窗模式（ui/config type=iframe）把 http://<host>:<port>/ 嵌进
// 桌面窗口 iframe，浏览器按上述响应头直接拒绝渲染 → 窗口空白/报错。
// 上游没有 env 开关，唯一解法是改 dist/server/index.js。
//
// 补丁内容：
//   XFO DENY -> ALLOWALL（Chromium 忽略该非标值，实际由 CSP frame-ancestors 管控）
//   CSP frame-ancestors 'none' -> 白名单
//
// ⛔ 白名单的来源设计（重要，涉及隐私与可移植性）：
//   1) 内置静态项只有与机器无关的值：'self' / localhost / 127.0.0.1 / [::1]。
//      —— 绝不内置任何真实内网 IP、域名或主机名：那既泄露打包者隐私，
//         也让别人的机器用不了（每家的入口地址/域名都不同）。
//   2) 本机地址：运行时（非 --static-only）用 os.networkInterfaces() 枚举
//      【当前机器】的地址写入 —— 任何机器装上后都得到自己的地址，零配置。
//   3) 站点/反代域名等额外来源：由使用者在本地文件里补充，不进仓库与产物：
//        文件：$FRAME_ANCESTORS_FILE（cmd/main 默认指向 ${HERMES_HOME}/frame-ancestors.extra）
//              每行一个来源，支持 # 注释；例：https://*.example.com:*
//        或环境变量 FRAME_ANCESTORS_EXTRA（空格分隔）
//      CSP 的 host-source 不支持 IP 通配/CIDR，所以本机地址只能靠枚举，
//      域名则建议用 *.example.com 这类通配形式覆盖子域。
//
// 幂等/可刷新：首次匹配 "frame-ancestors 'none'"；已打过则刷新我们生成的那条
//   （只认 "frame-ancestors 'self' " 形式，绝不碰上游 DSH 代理中间件的
//    "frame-ancestors 'self';" —— 它 'self' 后没有空格）。
const fs = require('fs');
const os = require('os');

// 参数解析：目标路径 = 第一个非 --flag 参数；--static-only 位置无关
const _args = process.argv.slice(2);
const TARGET = _args.find((a) => !a.startsWith('--'));
// --static-only: 只写与机器无关的静态项（不枚举本机地址、不读本地额外来源）。
//                构建期用它，保证产物里零地址零域名。
const STATIC_ONLY = _args.includes('--static-only');
if (!TARGET) { console.error('usage: patch-frame-headers.js [--static-only] <index.js>'); process.exit(2); }
if (!fs.existsSync(TARGET)) { console.error('not found: ' + TARGET); process.exit(1); }

let s = fs.readFileSync(TARGET, 'utf8');

// ── 组装白名单 ──────────────────────────────────────────────────────────────
const origins = new Set([
  "'self'",
  'http://localhost:*', 'https://localhost:*',
  'http://127.0.0.1:*', 'https://127.0.0.1:*',
  'http://[::1]:*', 'https://[::1]:*',
  // fnOS 官方远程访问域（Connect / 手机 App 的桌面地址就是 https://<fnid>.fnos.net）。
  // 它们是【产品常量】——与打包者/使用者无关，故进静态表（既不泄露隐私，也让所有
  // 使用者开箱即用）。⛔ 缺了它们时：远程模式下桌面以 fnos.net 为父页面嵌入本应用，
  // 而本应用自己的 CSP frame-ancestors 不认这个父来源 → 浏览器在框里显示
  // 「<app>.fnos.net 拒绝连接」（2026-10-15 用户实测的远程小窗打不开根因）。
  'https://fnos.net:*', 'https://*.fnos.net:*', 'http://*.fnos.net:*',
  'https://5ddd.com:*', 'https://*.5ddd.com:*', 'http://*.5ddd.com:*',
  'https://trzznas.com:*', 'https://*.trzznas.com:*', 'http://*.trzznas.com:*',
]);

// 额外来源（使用者本地的域名等）：校验形态，拒绝引号/分号/空白以免破坏 CSP
const ORIGIN_RE = /^(?:'self'|https?:\/\/[A-Za-z0-9._\-\[\]:*]+(?:\/[^\s"';]*)?)$/;
function addOrigin(o) {
  const v = String(o).trim();
  if (!v || v.startsWith('#')) return;
  if (!ORIGIN_RE.test(v)) {
    console.warn('WARN: 跳过非法 frame-ancestors 来源: ' + JSON.stringify(v));
    return;
  }
  origins.add(v);
}
if (!STATIC_ONLY) {
  // 1) 本机当前地址（IPv4 + IPv6 字面量；IPv6 带方括号）
  //    过滤 virtual 网桥/容器网卡与链路本地 fe80::（不是父页面来源，只是噪音）
  const VIRTUAL_IFACE_RE = /^(docker|br-|veth|virbr|tun|tap|wg|kube|flannel|cali|nerdctl|lo$)/;
  const addHost = (addr, family) => {
    const isV6 = String(family) === 'IPv6' || String(family) === '6';
    if (isV6 && /^fe80:/i.test(addr)) return;
    const host = isV6 ? '[' + addr + ']' : addr;
    origins.add('http://' + host + ':*');
    origins.add('https://' + host + ':*');
  };
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
  // 2) 环境变量补充
  for (const tok of String(process.env.FRAME_ANCESTORS_EXTRA || '').split(/\s+/)) addOrigin(tok);
  // 3) 本地文件补充（每行一个来源，# 注释）
  const extraFile = process.env.FRAME_ANCESTORS_FILE;
  if (extraFile && fs.existsSync(extraFile)) {
    try {
      for (const line of fs.readFileSync(extraFile, 'utf8').split(/\r?\n/)) addOrigin(line);
    } catch (e) {
      console.warn('WARN: 读取 ' + extraFile + ' 失败: ' + e.message);
    }
  }
}

// ── 生成下发值 ──────────────────────────────────────────────────────────────
// 默认【不限制父页面】(`frame-ancestors *`)：
//   本 fpk 是公开分发的，安装者的域名/入口形态不可枚举（自有域名、反代、IPv6、
//   fnOS Connect 子域、局域网 IP……）。白名单式限制必然对某类用户失效 ——
//   实测形态：fnOS 服务器自己的 CSP 把「未列入白名单的父页面」拦成
//   ERR_BLOCKED_BY_RESPONSE / 「拒绝连接」，表现为桌面小窗打不开而普通网页访问正常。
//   上游本身也不做该限制（XFO: DENY 是上游遗留），同类应用（CLIProxyAPI 等）
//   干脆不下发 XFO/CSP。故默认对齐为「不限」。
// 需要收紧的部署（如暴露公网且在意点击劫持）：设 FRAME_ANCESTORS_STRICT=1，
//   则改用下面的白名单（本机地址运行时枚举 + 环境变量/本地文件补充）。
const STRICT = process.env.FRAME_ANCESTORS_STRICT === '1';
const LIST = Array.from(origins).join(' ');
const NEW_DIRECTIVE = STRICT ? ('frame-ancestors ' + LIST) : 'frame-ancestors *';

let n = 0;

// 1) X-Frame-Options: DENY -> ALLOWALL
s = s.replace(/"X-Frame-Options","DENY"/g, () => { n++; return '"X-Frame-Options","ALLOWALL"'; });

// 2) 首次：frame-ancestors 'none' -> 白名单
s = s.replace(/frame-ancestors 'none'/g, () => { n++; return NEW_DIRECTIVE; });

// 3) 刷新：已打过的那条（白名单形态 "frame-ancestors 'self' ..." 或 "frame-ancestors *"）
//    重算（含 mode 切换：默认<->严格）
s = s.replace(/frame-ancestors 'self' [^";]*|frame-ancestors \*/g, () => { n++; return NEW_DIRECTIVE; });

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
const wildcard = /frame-ancestors \*/.test(after);
console.log('mode: ' + (wildcard ? 'permissive (frame-ancestors *)' : ('strict (whitelist, ' + (m ? m[0].split(/\s+/).length - 1 : 0) + ' entries)')));
