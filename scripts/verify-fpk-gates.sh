#!/usr/bin/env bash
# FPK 产物硬门禁 —— CI 与本机共用同一份逻辑（避免两处漂移）。
#
# 用法:
#   verify-fpk-gates.sh <file.fpk>
#
# 只查「结构」不查「必需内容」，照样会放行残缺包。逐条对应一类真实残缺：
#   外层必要条目        → 包根本装不上
#   外层 config/bootstrap → 回调期要读，只放内层会读不到而降级成 unknown
#   cmd/* 可执行位      → 644 让卸载/升级静默跳过 stop，残留进程占端口
#   checksum 自洽       → 应用中心校验失败
#   内层无 app/ 前缀    → 装完四个关键路径全错位，安装必失败
#   内层 config/privilege → fnOS 无法确定运行用户
#   禁携带 skills/      → 会覆盖用户技能库
#   内层含 bundled node → 缺它回退 npm install，fnOS 缺 gcc 编不出 node-pty
#   内层含 node-pty     → 同上，原生模块缺失
#   内层含内核源码      → 缺它装机要么超时要么卡在连不上 GitHub
#   内层含 agent node   → 缺它首启联网跑 npm install，NAS 慢网卡很久
#   无构建机绝对路径    → 污染会导致 install_callback 找不到 node_modules
#   无宽泛 pkill        → 会误杀同机 Docker 容器 / 其它 Hermes 应用
#   DSH 凭据 600 保护   → 缺它升级一次「DSH 模式」下拉框就无限转圈
#   界面显示版本        → 装完 fpk 版本栏必须显示本包锚点（stamp/探测链无人验证=静默错版本）
#
# ⛔ 不要把清单塞进变量再 `echo "$LIST" | grep ...`：
#    内层 3 万多行（400KB+），`grep -q` 命中即早退 → echo 收 SIGPIPE(141)。
#    在 pipefail 下 `if echo "$L" | grep -q X` 会被判成「未命中」——
#    安全检查静默失效（假阴性，已实测复现）。一律写文件再 grep。
set -euo pipefail

FPK="${1:?用法: $0 <file.fpk>}"
[ -f "$FPK" ] || { echo "::error:: 找不到 $FPK"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "校验 $FPK ..."
tar tzf "$FPK" > "$TMP/outer.list"
tar tvzf "$FPK" > "$TMP/outer.tv"
echo "外层条目数: $(wc -l < "$TMP/outer.list")"

for need in '^manifest$' '^manifest\.checksum$' '^cmd/' '^config/' '^wizard/' '^app\.tgz$'; do
    if ! grep -qE "$need" "$TMP/outer.list"; then
        echo "::error:: FPK 缺少必要内容: $need"
        exit 1
    fi
done
echo "✅ 外层结构完整"

# 外层必须含 config/bootstrap/*.env —— install_callback 与 upgrade_callback 都在
# 【回调期】读 ${APP_DIR}/config/bootstrap/*.env，那时内层尚未解包。
if ! grep -qE '^config/bootstrap/.*\.env$' "$TMP/outer.list"; then
    echo "::error:: 外层缺 config/bootstrap/*.env（回调期要读，缺了只能降级成 unknown）"
    exit 1
fi
echo "✅ 外层含 config/bootstrap/*.env"

# cmd/* 必须可执行
BAD_PERM="$(grep -E ' cmd/[a-z_]+$' "$TMP/outer.tv" | awk '$1 !~ /^-rwx/ {print $NF}' || true)"
if [ -n "$BAD_PERM" ]; then
    echo "::error:: 以下 cmd/ 脚本缺可执行位（fnOS 会静默跳过 stop）："
    echo "$BAD_PERM"
    exit 1
fi
echo "✅ cmd/* 均可执行"

# 解外层，再对磁盘上的 app.tgz 做 tar tzf（不要用管道版本，容易拿到空输入而误判）
tar xzf "$FPK" -C "$TMP"
[ -s "$TMP/app.tgz" ] || { echo "::error:: 解出的 app.tgz 缺失或为空"; exit 1; }

# cmd/main 必须注入 CORS_ORIGINS：
# 上游按「Origin.host 必须 === Host」校验 Socket.IO 升级（server 的 $Ne/c5n），
# 默认 same host only。任何改写 Host 或换端口的入口都会不相等而被拒：
#   · Lucky 等反代剥掉端口   · fnOS FN Connect 中继用随机端口
# 命中即 [Socket.IO] rejected upgrade origin → 页面能开但对话不流式。
# 远程中继端口每次随机，固定清单覆盖不了，故取 *（与上游 enableClientMode() 同款）。
# 注意：web-ui 不加载 .env（无 dotenv/loadEnvFile），cmd/main 的 export 是唯一注入点。
# ⛔ 不要写 `grep -vE ... file | grep -q X`：在 set -o pipefail 下，右端 grep -q
#    命中即早退 → 左端 grep 收 SIGPIPE(141) → 整个管道返回 141 →
#    `if ! pipeline` 判成「未命中」而**误报失败**（实测 50 次里失败 2 次，flaky）。
#    反向检查（`if pipeline; then 报错`）更危险：141 让 if 为假 → **坏包静默放行**。
#    一律先落文件再 grep（本文件开头已写明这条，这里是它的具体落点）。
grep -vE '^[[:space:]]*#' "$TMP/cmd/main" > "$TMP/main.code" 2>/dev/null || true
if ! grep -q 'CORS_ORIGINS' "$TMP/main.code"; then
    echo "::error:: cmd/main 未注入 CORS_ORIGINS —— 反代/FN Connect 中继下 Socket.IO 会被拒（页面能开、对话不流式）"
    exit 1
fi
echo "✅ cmd/main 已注入 CORS_ORIGINS（反代与远程中继下 WebSocket 可用）"
tar tzf "$TMP/app.tgz" > "$TMP/inner.list"
echo "内层条目数: $(wc -l < "$TMP/inner.list")"

# manifest.checksum 必须等于包内 app.tgz 的实际 md5
WANT="$(tr -d '[:space:]' < "$TMP/manifest.checksum")"
GOT="$(md5sum "$TMP/app.tgz" | awk '{print $1}')"
if [ "$WANT" != "$GOT" ]; then
    echo "::error:: manifest.checksum 与 app.tgz 实际 md5 不符: want=$WANT got=$GOT"
    exit 1
fi
echo "✅ manifest.checksum 自洽 ($GOT)"

# 内层归档根不得有 app/ 前缀，也不得有 ./ 前缀
FIRST="$(sed -n '1p' "$TMP/inner.list")"
case "$FIRST" in
    app/*|./*)
        echo "::error:: 内层 app.tgz 首条为 '$FIRST'，带前缀会让装完路径全错位（安装必失败）"
        exit 1
        ;;
esac
echo "✅ 内层无 app/ 与 ./ 前缀（首条: $FIRST）"

if ! grep -qE '^config/privilege$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 config/privilege，fnOS 无法确定运行用户"
    exit 1
fi
echo "✅ 内层含 config/privilege"

# ── 内核对齐（装新 fpk 必须把内核带到本包内嵌版本）──
# 2026-10-15 用户实测暴露：旧行为是 install_callback 见 venv/bin/hermes 就 return，
# 升级 fpk 永远不碰内核。现在靠 ensure-kernel.sh 判定 + install_callback 对齐，
# 下面三条断言把「闸门随包 / 升级路径接线 / 失败可回滚」钉成构建门禁 ——
# 任何一处被删或改回去，构建即红（避免再次出现「注释说会做、代码没做」）。
if ! grep -qE '^config/bootstrap/ensure-kernel\.sh$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 config/bootstrap/ensure-kernel.sh —— 内核版本闸门没随包，装新 fpk 不会更新内核"
    exit 1
fi
echo "✅ 内层含 config/bootstrap/ensure-kernel.sh（内核版本闸门）"

# ⚠️ grep 的 $need 里有 `--no-venv`/`--expect-version` 这种以 `-` 开头的字面量：
#    不加 `--` 会被 grep 当选项解析（`grep: unrecognized option '--no-venv'`）→
#    断言恒判「缺失」，构建必红（2026-10-15 run#7 就是这么失败的）。
#    另外清单写文件再 grep，避免 `printf | grep -q` 命中即早退引发的 SIGPIPE 假阴性。
IC="$(grep -vE '^[[:space:]]*#' "$TMP/cmd/install_callback" || true)"
printf '%s' "$IC" > "$TMP/ic.txt"
for need in 'ensure-kernel.sh' 'prealign' 'rolled-back' '--no-venv' 'rollback_or_fail'; do
    if ! grep -qF -- "$need" "$TMP/ic.txt"; then
        echo "::error:: cmd/install_callback 缺少内核对齐要素: $need（缺了会导致升级不更新内核，或对齐失败后无法回滚）"
        exit 1
    fi
done
echo "✅ cmd/install_callback 含内核对齐（闸门/备份/回滚/复用 venv）"

# 界面显示版本硬门禁的接线（Studio 版本栏 = install-stamp.json 的 baseVersion）：
# 对齐/新装时先删内嵌源码可能自带的旧 stamp，再把本包锚点作为 --expect-version
# 传给 postinstall —— 缺任一环，界面就会静默显示 0.0.0 或旧版本。
for need in '--expect-version' 'install-stamp.json'; do
    if ! grep -qF -- "$need" "$TMP/ic.txt"; then
        echo "::error:: cmd/install_callback 缺界面显示版本硬门禁要素: $need（缺了会出现装完 fpk 界面显示 0.0.0/旧版本）"
        exit 1
    fi
done
echo "✅ cmd/install_callback 已接界面显示版本硬门禁（对齐前删 stamp + 传本包锚点）"

UC="$(grep -vE '^[[:space:]]*#' "$TMP/cmd/upgrade_callback" || true)"
printf '%s' "$UC" > "$TMP/uc.txt"
for need in 'ensure-kernel.sh' 'decide' 'run_install_callback'; do
    if ! grep -qF -- "$need" "$TMP/uc.txt"; then
        echo "::error:: cmd/upgrade_callback 未接内核对齐: 缺 $need（web-ui 版本相同时内核仍不会更新）"
        exit 1
    fi
done
echo "✅ cmd/upgrade_callback 已接内核对齐（升级路径可达）"

# 桌面入口必须是 ${wizard_port}（端口可配）而不是写死值：
# 写死会让「应用设置里改端口」失效 —— 入口跟着变、服务还在老端口，页面打不开。
#
# ⚠️ 2026-10-15 推翻（见 MAINTAINING #41）：端口模板化会让 fnOS 远程链路失效，
# 最终按 cliproxyapi 形态收敛为「单入口 + 字面量端口 + allUsers:true + 无向导端口」。
# 因此这里改为断言「ui/config 的 port 必须与 manifest 的 service_port 一致」——
# 两者错位时桌面入口指向的端口与实际监听端口不同（页面打不开），比可改端口重要。
if ! grep -qE '^ui/config$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 ui/config，桌面图标无法注册"
    exit 1
fi
# 本门禁需要 ui/config 与 manifest 两份文件，就地解包（步骤间不共享状态，
# 且后续段落各自的解包在本段之后才发生 —— 少解一份就会 FileNotFoundError）。
tar xzf "$TMP/app.tgz" -C "$TMP" ui/config 2>/dev/null || true
tar xzf "$FPK" manifest -C "$TMP" 2>/dev/null || true
if [ ! -f "$TMP/ui/config" ] || [ ! -f "$TMP/manifest" ]; then
    echo "::error:: 解包 ui/config 或 manifest 失败，无法校验入口端口一致性（构建中止）"
    exit 1
fi
UV_PORT="$(python3 - "$TMP/ui/config" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding='utf-8'))
for name, item in (cfg.get('.url') or {}).items():
    if (item or {}).get('port'):
        print(str(item['port']).strip()); break
PY
)"
MPORT="$(grep -E '^service_port[[:space:]]*=' "$TMP/manifest" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
if [ -z "${UV_PORT}" ] || [ -z "${MPORT}" ] || [ "${UV_PORT}" != "${MPORT}" ]; then
    echo "::error:: ui/config 入口端口('${UV_PORT}') 与 manifest service_port('${MPORT}') 不一致 —— 桌面入口会指向错端口，构建中止"
    exit 1
fi
echo "✅ ui/config 入口端口 == manifest service_port（${UV_PORT}，单一真源）"

# 主入口必须 allUsers:true（远程访问的权限前提）：
# allUsers:false → 系统把该入口标记为 admin-only（trim_sac.entry.is_admin=true），
# fnOS Connect（远程访问）小窗打开时被权限拦住（"暂无权限访问该服务"）。
# 全机对照：能远程打开的第三方 iframe 应用（cliproxyapi/cleanfnos/wildwork）都是
# allUsers:true；我们是唯一 allUsers:false 的（2026-10-15 实测，见 MAINTAINING #41）。
if ! python3 - "$TMP/ui/config" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding='utf-8'))
urls = cfg.get('.url') or {}
if not urls:
    print("ui/config 缺 .url 段", file=sys.stderr); sys.exit(1)
for name, item in urls.items():
    if (item or {}).get('allUsers') is not True:
        print(f"{name}: allUsers={(item or {}).get('allUsers')!r}（远程访问要求 true：false 会变成 admin-only 入口）", file=sys.stderr)
        sys.exit(1)
sys.exit(0)
PY
then
    echo "::error:: ui/config 存在非 allUsers:true 的入口 —— 远程访问会被权限拦住，构建中止"
    exit 1
fi
echo "✅ ui/config 入口均为 allUsers:true（远程访问权限前提）"

# ── 远程访问（fnOS Connect）链路：manifest 必须声明 service_port 且不得声明 micro_app ──
# ① service_port：系统据此注入 TRIM_SERVICE_PORT，并据此为 Connect 建立端口上游。
#    缺它 → 进程里 TRIM_SERVICE_PORT 为空、Connect 无上游 → 桌面小窗在 Connect
#    模式下浏览器直接 ERR_CONNECTION_REFUSED（2026-10-15 用户实测）。
# ② micro_app=true：属于「经统一网关按路径服务」的微应用形态（service_port=0 +
#    gatewaySocket + url=/app/<name>，如 fygo-browser）。本应用是端口型入口，
#    带该标记会让桌面按微应用路由去访问 → 同样打不开。
tar xzf "$FPK" manifest -C "$TMP" 2>/dev/null || true
if [ ! -f "$TMP/manifest" ]; then
    echo "::error:: 外层缺 manifest，无法校验远程访问字段"
    exit 1
fi
SP="$(grep -E '^service_port[[:space:]]*=' "$TMP/manifest" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
if [ -z "$SP" ]; then
    echo "::error:: 产物 manifest 缺 service_port —— fnOS Connect（远程访问）没有端口上游，桌面小窗打不开"
    exit 1
fi
case "$SP" in
    ''|*[!0-9]*) echo "::error:: 产物 manifest service_port 非数字: '$SP'"; exit 1 ;;
esac
if grep -qE '^micro_app[[:space:]]*=[[:space:]]*true' "$TMP/manifest"; then
    echo "::error:: 产物 manifest 声明了 micro_app=true，但入口是端口型（ui/config 有 port）—— 远程访问会走错路由"
    exit 1
fi
echo "✅ 产物 manifest 声明 service_port=$SP 且未声明 micro_app（远程访问链路可用）"

# ui/config 的 protocol 必须是非空 http/https：
# 留空会让 fnOS 渲染出入口 url = "://${host}:<port>/"（协议头缺失），
# 客户端只能自己猜协议 —— 猜成 HTTPS 就会用 TLS 打明文 HTTP 端口，
# 手机 App 报 HandshakeException: WRONG_VERSION_NUMBER(tls_record.cc:127)。
# 官方第三方应用（Lucky/1Panel/Sun-Panel/Home-Assistant/lemon-music/miair-next）
# 凡指定了 port 的一律显式写 "http"；protocol 为空只出现在「无 port、走路径路由」的应用上。
# ⚠️ 规则按入口类型区分（2026-10-15 起两入口并存）：
#   · 带 port 的入口（端口直连）→ protocol 必须显式 http/https：留空会让入口 url
#     变成 "://host:port/"，客户端猜成 HTTPS 打明文端口（手机 App 报
#     HandshakeException: WRONG_VERSION_NUMBER）。
#   · 不带 port 的路径型入口（统一网关 gatewaySocket/gatewayPrefix）→ protocol
#     允许留空（"" = 自适应），因为它是跟着桌面/浏览器当前协议走的同源路径。
if ! python3 - "$TMP/ui/config" <<'PY'
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    print(f"ui/config 不是合法 JSON: {e}", file=sys.stderr); sys.exit(1)
urls = cfg.get('.url') or {}
if not urls:
    print("ui/config 缺 .url 段", file=sys.stderr); sys.exit(1)
for name, item in urls.items():
    item = item or {}
    if item.get('port'):
        proto = item.get('protocol')
        if proto not in ('http', 'https'):
            print(f"{name}: 带 port 的入口 protocol={proto!r}（必须显式写 'http' 或 'https'）", file=sys.stderr)
            sys.exit(1)
sys.exit(0)
PY
then
    echo "::error:: ui/config 带 port 的入口必须显式写 protocol=http（留空会被客户端猜成 HTTPS 打明文端口）"
    exit 1
fi
echo "✅ ui/config protocol 规则正确（带 port 的入口显式 http；路径型入口允许自适应）"

# 桌面入口必须是 iframe（小窗模式）：type=url 会跳新浏览器标签页，
# 用户明确要求点击图标在 fnOS 桌面窗口内嵌打开（2026-10-14 拍板）。
# 防止重新 fnpack create / 模板回退把入口改回 url 造成行为回潮。
if ! python3 - "$TMP/ui/config" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding='utf-8'))
bad = [n for n, it in (cfg.get('.url') or {}).items()
       if it.get('port') and it.get('type') != 'iframe']
if bad:
    print(f"入口 {bad} type!=iframe（桌面图标会跳浏览器标签页而非小窗）", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
then
    echo "::error:: ui/config 带 port 的入口必须 type=iframe（小窗模式，用户要求）——构建中止"
    exit 1
fi
echo "✅ 桌面入口为 iframe 小窗模式（不跳浏览器标签页）"

# ── 桌面小窗 iframe 嵌入补丁三道门禁（2026-10-14 真实事故固化）────────────
# 事故模型：ui/config 改成 iframe 小窗后，上游 web-ui 对 / 硬编码
#   X-Frame-Options: DENY + CSP frame-ancestors 'none'
# → 浏览器拒绝把页面嵌进 fnOS 桌面窗口 → 桌面图标点开是空白/报错。
# 修复三层，缺一层就会以不同形态复发：
#   L1 构建期预打（build-fpk.sh 改 bundled 产物）→ 本门禁③校验
#   L2 运行时自愈（cmd/main 每次启动前重打）→ 本门禁①②校验
#     为什么必须运行时也打：install/upgrade_callback 用 cp -a 把 bundled
#     原始 node_modules 覆盖回 data/，L1 的补丁会被整个冲掉
#     （2026-10-14 实测：手工补丁被两次安装覆盖，小窗恢复空白）。
#   L3 补丁脚本本体必须随包（app/bin/patch-frame-headers.js）
# 任缺其一 → 构建红，不让出厂。
# ① 补丁函数必须在 cmd/main 定义且被 start_process 调用（定义了不调用=没有）
if ! grep -q '^patch_webui_frame_headers()' "$TMP/cmd/main"; then
    echo "::error:: cmd/main 缺 patch_webui_frame_headers() —— 重装/升级后补丁被 cp -a 覆盖，桌面小窗恢复空白"
    exit 1
fi
n="$(grep -c 'patch_webui_frame_headers' "$TMP/main.code" || true)"
if [ "${n:-0}" -lt 2 ]; then
    echo "::error:: cmd/main 定义了 patch_webui_frame_headers() 但未在 start_process 中调用（出现 ${n:-0} 次，应 ≥2：定义+调用）"
    exit 1
fi
echo "✅ cmd/main 启动前自愈重打 iframe 补丁（覆盖重装/升级覆盖路径）"
# ② 补丁脚本必须随包（cmd/main 从 ${TRIM_APPDEST}/bin/ 调它）
if ! grep -qE '^bin/patch-frame-headers\.js$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 bin/patch-frame-headers.js —— cmd/main 的自愈调用找不到脚本，桌面小窗会空白"
    exit 1
fi
echo "✅ iframe 补丁脚本随包（bin/patch-frame-headers.js）"
# ②a 补丁脚本必须【默认不限制父页面】（frame-ancestors *）并提供可选严格模式：
#     本 fpk 公开分发，安装者的域名/入口不可枚举 —— 白名单式限制必然对某类用户失效，
#     实测形态是桌面小窗被自家 CSP 拦成「拒绝连接」/ERR_BLOCKED_BY_RESPONSE。
#     上游遗留 XFO: DENY 要改成 ALLOWALL；需要收紧的部署用 FRAME_ANCESTORS_STRICT=1。
for need in "'frame-ancestors *'" 'FRAME_ANCESTORS_STRICT'; do
    if ! grep -qF -- "$need" "$TMP/bin/patch-frame-headers.js" 2>/dev/null; then
        tar xzf "$TMP/app.tgz" -C "$TMP" bin/patch-frame-headers.js 2>/dev/null || true
        if ! grep -qF -- "$need" "$TMP/bin/patch-frame-headers.js" 2>/dev/null; then
            echo "::error:: patch-frame-headers.js 缺要素 '$need' —— 默认应不限制父页面（否则特定用户的桌面小窗会被自家 CSP 拦）"
            exit 1
        fi
    fi
done
echo "✅ 补丁脚本默认不限制父页面（frame-ancestors *），并保留 FRAME_ANCESTORS_STRICT 收紧开关"
# ②a2 出厂产物（bundled dist）必须已经是不限制态：不得残留 frame-ancestors 'none'，
#      且必须出现 frame-ancestors *。做不到 = 构建期补丁没跑/被打回，远端用户装完即报错。
BUNDLED=""
if grep -qxF "node/lib/node_modules/hermes-web-ui/dist/server/index.js" "$TMP/inner.list" 2>/dev/null; then
    BUNDLED="node/lib/node_modules/hermes-web-ui/dist/server/index.js"
else
    BUNDLED="$(grep -E 'hermes-web-ui/dist/server/index\.js$' "$TMP/inner.list" | head -1 || true)"
fi
if [ -z "$BUNDLED" ]; then
    echo "::error:: 内层找不到 hermes-web-ui 的 dist/server/index.js —— 无法校验出厂 iframe 头"
    exit 1
fi
tar xzf "$TMP/app.tgz" -C "$TMP" "$BUNDLED" 2>/dev/null || true
if grep -q "frame-ancestors 'none'" "$TMP/$BUNDLED" 2>/dev/null; then
    echo "::error:: 出厂 dist 仍含 frame-ancestors 'none'（限制态）—— 远端用户桌面小窗会被拦，构建中止"
    exit 1
fi
if ! grep -q 'frame-ancestors \*' "$TMP/$BUNDLED" 2>/dev/null; then
    echo "::error:: 出厂 dist 未出现 frame-ancestors *（默认不限制未生效）—— 构建中止"
    exit 1
fi
echo "✅ 出厂 dist 为不限制态（frame-ancestors *，无 'none' 残留）"
# ②b 随包的脚本必须是「动态枚举 + 可刷新」那一版 —— 用内容特征断言，fail-closed。
# ⛔ 事故（2026-10-14）：scripts/ 升级成动态白名单后忘了同步 app/bin/ 的副本，
#    运行时自愈变成 no-op（日志 "already patched, no change"）→ 白名单里留着
#    构建机地址 <构建机IP>/fe80::…，而部署者真实入口地址被 CSP 拦。
#    只检查「文件存在」抓不到这种漂移，必须断言能力特征。
tar xzOf "$TMP/app.tgz" bin/patch-frame-headers.js > "$TMP/pfh.js" 2>/dev/null || true
if ! grep -q 'networkInterfaces' "$TMP/pfh.js"; then
    echo "::error:: 随包的 bin/patch-frame-headers.js 不是动态版（无 networkInterfaces）—— 运行时自愈不会写入本机地址，192.168.x/全局 IPv6 入口下小窗会空白"
    exit 1
fi
if ! grep -q "frame-ancestors 'self' \[^" "$TMP/pfh.js"; then
    echo "::error:: 随包脚本缺「刷新已有白名单」正则 —— 无法在升级/迁移后重算地址，构建中止"
    exit 1
fi
echo "✅ 随包补丁脚本为动态版（枚举本机地址 + 可刷新白名单）"
# ②c 构建期脚本与运行时脚本必须同源（build-fpk.sh 会 cp scripts/ → app/bin/）
if ! diff -q "scripts/patch-frame-headers.js" "app/bin/patch-frame-headers.js" >/dev/null 2>&1; then
    echo "::error:: scripts/ 与 app/bin/ 两份补丁脚本不一致 —— build-fpk.sh 的同步步骤失效（曾导致运行时自愈空转）"
    exit 1
fi
echo "✅ 构建期/运行时补丁脚本同源（无副本漂移）"
# ③ bundled 产物出厂即带补丁（fail-closed：内层 index.js 必须无 DENY/none）
#    grep -c 读完全部输入不早退，无 SIGPIPE 风险，可安全用于管道。
XFO_DENY_LEFT="$(tar xzOf "$TMP/app.tgz" node/lib/node_modules/hermes-web-ui/dist/server/index.js 2>/dev/null | grep -c '"X-Frame-Options","DENY"' || true)"
FA_NONE_LEFT="$(tar xzOf "$TMP/app.tgz" node/lib/node_modules/hermes-web-ui/dist/server/index.js 2>/dev/null | grep -c "frame-ancestors 'none'" || true)"
ALLOWALL_N="$(tar xzOf "$TMP/app.tgz" node/lib/node_modules/hermes-web-ui/dist/server/index.js 2>/dev/null | grep -c '"X-Frame-Options","ALLOWALL"' || true)"
if [ "${XFO_DENY_LEFT:-0}" != "0" ] || [ "${FA_NONE_LEFT:-0}" != "0" ] || [ "${ALLOWALL_N:-0}" = "0" ]; then
    echo "::error:: bundled index.js 未打 iframe 补丁（XFO DENY 残留=${XFO_DENY_LEFT}, frame-ancestors none 残留=${FA_NONE_LEFT}, ALLOWALL=${ALLOWALL_N}）—— 全新安装桌面小窗即空白，构建中止"
    exit 1
fi
echo "✅ bundled 产物出厂带 iframe 补丁（XFO=ALLOWALL, frame-ancestors 白名单）"
# ④ 产物零隐私 / 零机器绑定（fail-closed）：
# 默认已改为「不限制父页面」（frame-ancestors *）→ 本项自动通过。
# 若产物仍是白名单形态（有人开了 STRICT），则校验白名单里不得出现打包者私有
# 信息：私有网段 IP、IPv6 字面量（::1 除外）、或除产品常量域（fnOS 官方远程域
# fnos.net/5ddd.com/trzznas.com）以外的任何域名 —— 泄露隐私且他人机器不可用。
# ⚠️ 取值的管道必须带 `|| true`：白名单形态 grep 的 `'self'` 锚点在不限制态下
#    无命中，pipefail + set -e 会让脚本**静默**exit 1（2026-10-15 run#21 的形态）。
WL="$(tar xzOf "$TMP/app.tgz" "$BUNDLED" 2>/dev/null \
      | grep -oE "frame-ancestors ('self' )?[^\"]*" | head -1 || true)"
if printf '%s' "$WL" | grep -q 'frame-ancestors \*'; then
    echo "✅ 产物为不限制态（frame-ancestors *；任意部署方的域名/入口均可嵌入）"
else
    PRIV_IP="$(printf '%s\n' "$WL" | grep -oE 'https?://(10\.[0-9.]+|192\.168\.[0-9.]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9.]+)' | sort -u | tr '\n' ' ' || true)"
    V6_LIT="$(printf '%s\n' "$WL" | grep -oE 'https?://\[[0-9a-fA-F:]+\]' | grep -v '\[::1\]' | sort -u | tr '\n' ' ' || true)"
    DOMAIN="$(printf '%s\n' "$WL" | grep -oE 'https?://[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z]{2,}' | grep -v 'localhost' \
        | grep -vE '^https?://([A-Za-z0-9._-]*\.)?(fnos\.net|5ddd\.com|trzznas\.com)$' | sort -u | tr '\n' ' ' || true)"
    if [ -n "${PRIV_IP}${V6_LIT}${DOMAIN}" ]; then
        echo "::error:: 产物白名单含机器/个人绑定信息（私有IP=[${PRIV_IP}] IPv6=[${V6_LIT}] 域名=[${DOMAIN}]）—— 泄露打包者隐私且他人机器不可用，构建中止"
        exit 1
    fi
    echo "✅ 产物白名单零隐私（仅静态项与产品常量域；本机地址由部署方运行时枚举）"
fi

# ── 启动健康判定 fail-closed + 端口释放门禁（2026-10-14 假启动事故固化）──
# 事故模型：上一版实例仍占 8648 → 新实例 bootstrap 打「listening on 0.0.0.0:PORT」
# 后 EADDRINUSE 直接 FATAL 退出。cmd/main 只 grep 那一行 → 误报「started」，
# 应用中心显示运行中而实际无人服务：桌面图标打不开、访问网址得空白页。
# 两道修复都必须随包，否则同一形态复发：
#   ① 健康判定必须带致命错误否决（fail-closed），不能只看 listening 行
#   ② 启动前必须以端口实际占用者为准释放端口（防旧实例占端口）
if ! grep -q 'FATAL: Failed to start' "$TMP/main.code"; then
    echo "::error:: cmd/main 的启动健康判定缺致命错误否决 —— EADDRINUSE 假启动会被误报成 started（应用中心显示运行中但无人服务）"
    exit 1
fi
echo "✅ 启动健康判定 fail-closed（FATAL/EADDRINUSE 一律不算启动成功）"
if ! grep -q '^ensure_port_released()' "$TMP/main.code"; then
    echo "::error:: cmd/main 缺 ensure_port_released() —— 旧实例占端口会让新实例假启动"
    exit 1
fi
m="$(grep -c 'ensure_port_released' "$TMP/main.code" || true)"
if [ "${m:-0}" -lt 2 ]; then
    echo "::error:: cmd/main 定义了 ensure_port_released() 但未在 start_process 中调用（出现 ${m:-0} 次，应 ≥2：定义+调用）"
    exit 1
fi
echo "✅ 启动前以端口实际占用者为准释放端口（属于本应用才杀，绝不误杀他应用）"

# ── 监听地址双栈门禁（2026-10-14 IPv6 小窗打不开事故）────────────────────────
# 事故模型：上游 listen 主机取 env BIND_HOST，默认 "0.0.0.0" = 纯 IPv4。
# 用户家宽 IPv4 是 CGNAT、外网/手机全走 IPv6；fnOS 桌面 iframe 的 src 用
# ${host}:<port> 拼（host = 访问桌面用的域名，AAAA-only），而 nginx 5666 双栈、
# 同机其它 fpk 应用端口也都是 `*`（双栈）——只有本应用纯 IPv4 → 小窗
# net::ERR_CONNECTION_REFUSED。缺这一行 = 只有 IPv6 用户打不开小窗。
if ! grep -q 'BIND_HOST' "$TMP/main.code"; then
    echo "::error:: cmd/main 未注入 BIND_HOST —— 纯 IPv4 监听会让 IPv6 访问（含 AAAA-only 域名）连接被拒，桌面小窗打不开"
    exit 1
fi
echo "✅ cmd/main 注入 BIND_HOST（IPv4+IPv6 双栈监听，与其它 fpk 应用一致）"

# 三个向导文件必须存在且是合法 JSON（安装/卸载/配置界面的全部内容都在这）
for w in install uninstall config; do
    if ! grep -qE "^wizard/${w}$" "$TMP/outer.list"; then
        echo "::error:: 外层缺 wizard/${w}（安装/卸载/配置界面会缺步骤）"
        exit 1
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP/wizard/$w" 2>/dev/null; then
        echo "::error:: wizard/${w} 不是合法 JSON，fnOS 无法解析该向导"
        exit 1
    fi
done
echo "✅ wizard/install|uninstall|config 均存在且为合法 JSON"

# 卸载向导与卸载回调必须语义一致：
# 向导里出现的每个 value，uninstall_callback 都要能处理；否则用户选了却被静默忽略
# （历史 bug：向导承诺「完全删除」，回调只删 data/，用户密钥与全部会话留在盘上）。
# 处理方式有两种：显式分支 `value)`，或落到 `*)` 默认分支（必须有默认分支兜底）。
HAS_DEFAULT=0
grep -qE '^[[:space:]]*\*\)' "$TMP/cmd/uninstall_callback" && HAS_DEFAULT=1
for v in false runtime true; do
    if grep -qE "\"value\": \"${v}\"" "$TMP/wizard/uninstall"; then
        if grep -qE "(^|[[:space:]])${v}\)" "$TMP/cmd/uninstall_callback"; then
            continue
        fi
        if [ "${HAS_DEFAULT}" = "1" ]; then
            continue   # 由 *) 默认分支兜底
        fi
        echo "::error:: 卸载向导提供选项 '${v}'，但 cmd/uninstall_callback 既无该分支也无 *) 兜底（用户选择会被静默忽略）"
        exit 1
    fi
done
echo "✅ 卸载向导选项与 uninstall_callback 处理分支一致"

# 微信策略必须写到内核真正加载的 .env（$HERMES_HOME/.env = hermes-home/.env）：
# 写到 data/.hermes/.env 等于没写（内核读不到），用户在向导里的选择静默失效。
if ! grep -q 'hermes-home/.env' "$TMP/cmd/install_callback"; then
    echo "::error:: install_callback 的微信策略未写到 hermes-home/.env（内核实际加载路径），设置将静默失效"
    exit 1
fi
# 只查【可执行代码行】，跳过注释 —— 否则解释性注释里提到旧路径就会误报
# （先落文件再 grep，避免管道 + pipefail 的 SIGPIPE 假阴性/假阳性）
grep -vE '^[[:space:]]*#' "$TMP/cmd/install_callback" > "$TMP/install_cb.code" 2>/dev/null || true
if grep -q 'DATA_DIR}/\.hermes/\.env' "$TMP/install_cb.code"; then
    echo "::error:: install_callback 仍写着内核读不到的 data/.hermes/.env 路径"
    exit 1
fi
echo "✅ 微信策略写入内核实际加载的 hermes-home/.env"

if grep -qE '^(app/)?skills/' "$TMP/inner.list"; then
    echo "::error:: FPK 内层携带 skills/ 目录，安装时会覆盖用户技能库；请从仓库删除后再构建"
    exit 1
fi
if grep -qE '^skills/' "$TMP/outer.list"; then
    echo "::error:: FPK 外层携带 skills/ 目录，安装时会覆盖用户技能库"
    exit 1
fi
echo "✅ 未携带 skills/（不会覆盖用户技能库）"

if ! grep -qE '^node/lib/node_modules/hermes-web-ui/bin/hermes-web-ui\.mjs$' "$TMP/inner.list"; then
    echo "::error:: FPK 未包含 bundled app/node，安装将回退 npm install 并因 fnOS 缺 gcc 失败，构建中止"
    exit 1
fi
echo "✅ 检测到 bundled 运行时 app/node（离线安装，无需联网编译）"

if ! grep -qE '^node/.*node-pty/build/Release/[^/]*\.node$' "$TMP/inner.list"; then
    echo "::error:: 未检测到 node-pty 编译产物，离线安装仍需联网编译（fnOS 无 gcc → 卡死）"
    exit 1
fi
echo "✅ node-pty 原生模块已打包"

if ! grep -qE '^hermes-agent-src/pyproject\.toml$' "$TMP/inner.list"; then
    echo "::error:: 未包含 Hermes Agent 离线源码包，安装时仍会尝试 git clone（NAS 弱网必失败）"
    exit 1
fi
echo "✅ 检测到 Hermes Agent 离线源码包"

# 内嵌源码的 ref 标记必须与包内锚点一致：界面显示的内核版本最终来自「包内锚点」，
# 而内核对齐的判据来自这个 ref 标记 —— 两者不一致时，装出来的内核与界面显示的
# 版本会各说各话（例：锚点写 v0.22.1、源码其实是 v0.22.0）。
if ! grep -qE '^hermes-agent-src/\.bundled-agent-ref$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 hermes-agent-src/.bundled-agent-ref —— 内核版本闸门拿不到内嵌版本，装新 fpk 不会更新内核"
    exit 1
fi
tar xzf "$TMP/app.tgz" -C "$TMP" hermes-agent-src/.bundled-agent-ref config/bootstrap/hermes-agent-version.env 2>/dev/null || true
ANCHOR_VAL="$(grep -E '^HERMES_AGENT_VERSION=' "$TMP/config/bootstrap/hermes-agent-version.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)"
REF_VAL="$(tr -d '[:space:]' < "$TMP/hermes-agent-src/.bundled-agent-ref" 2>/dev/null || true)"
if [ -z "$ANCHOR_VAL" ] || [ -z "$REF_VAL" ] || [ "$ANCHOR_VAL" != "$REF_VAL" ]; then
    echo "::error:: 包内锚点('$ANCHOR_VAL')与内嵌源码 ref 标记('$REF_VAL')不一致 —— 装出来的内核版本与界面显示的版本会各说各话，构建中止"
    exit 1
fi
echo "✅ 包内锚点与内嵌源码 ref 一致（$REF_VAL）"

if ! grep -qE '^hermes-agent-node/node_modules/' "$TMP/inner.list"; then
    echo "::error:: FPK 未包含 hermes-agent-node/node_modules，首启仍会联网跑 npm install，构建中止"
    exit 1
fi
echo "✅ 检测到 Agent browser tools 依赖（首启跳过 npm install）"

if ! grep -qE '^hermes-agent-node/ui-tui/node_modules/' "$TMP/inner.list"; then
    echo "::warning:: 未包含 hermes-agent-node/ui-tui/node_modules，TUI 可能仍需联网安装"
else
    echo "✅ 检测到 Agent TUI 依赖"
fi

if grep -qE 'hermes-agent-node/(home/|.*/\.agent-node-work/)' "$TMP/inner.list"; then
    echo "::error:: hermes-agent-node 内混入构建机绝对路径，打包脚本路径处理 bug 复发，构建中止"
    exit 1
fi
echo "✅ 无构建机绝对路径污染"

# ⛔ 这里原先是 `grep -hvE ... cmd/* | grep -qE 'pkill...'` 的管道写法。
#    在 set -o pipefail 下右端 grep -q 命中即早退 → 左端收 SIGPIPE(141) →
#    管道返回 141 → `if` 为假 → **宽泛 pkill 检查被静默跳过、坏包放行**
#    （正是本文件开头警告的那类假阴性）。必须先落文件再 grep。
grep -hvE '^[[:space:]]*#' "$TMP"/cmd/* > "$TMP/cmd.code" 2>/dev/null || true
if grep -qE 'pkill[^|]*"(bin/|dist/)' "$TMP/cmd.code"; then
    echo "::error:: cmd/* 中存在宽泛 pkill 模式（bin/ / dist/ 关键词），会误杀 Docker 容器，构建中止"
    exit 1
fi
echo "✅ 无宽泛 pkill 模式"

for cb in install_callback upgrade_callback main; do
    if ! grep -q 'chmod 600' "$TMP/cmd/$cb" 2>/dev/null; then
        echo "::error:: cmd/$cb 缺 DSH 凭据 chmod 600 保护（升级一次就会复发转圈）"
        exit 1
    fi
done
echo "✅ DSH 凭据保护在 install/upgrade/main 三处入口均存在"

# ── Gateway 存活保障必须在 cmd/main 里（2026-10-02 加）────────────────────────
# 真实故障：fnOS 应用升级杀掉 gateway 却不重启它（cmd/upgrade_init 的
# clean_app_processes 明确 pkill 本应用 agent 树），而 web-ui 的
# gateway-autostart 唯一补偿路径依赖 data/config.json 的 gatewayAutoStart.enabled，
# 该键从未被写入过 → 升级后 gateway 永久不再起来，hermes cron 与消息通道全停
# （实测停摆 21 小时无人察觉）。因此 start_process 必须自带两道保障。
# 缺任一条，升级一次就会静默复发。
for fn in ensure_gateway_autostart_config ensure_gateway_watchdog ensure_fpk_ci_watchdog; do
    if ! grep -q "^${fn}()" "$TMP/cmd/main"; then
        echo "::error:: cmd/main 缺少 ${fn}() —— gateway 自愈/CI 点火能力缺失，升级后 cron 会静默停摆"
        exit 1
    fi
done
# 三个都必须真的被 start_process 调用（定义了不调用等于没有）
for fn in ensure_gateway_autostart_config ensure_gateway_watchdog ensure_fpk_ci_watchdog; do
    n="$(grep -c "^\s*${fn}$" "$TMP/cmd/main" || true)"
    if [ "${n:-0}" -lt 1 ]; then
        echo "::error:: cmd/main 定义了 ${fn}() 但未在 start_process 中调用"
        exit 1
    fi
done
echo "✅ gateway 自愈 + CI 点火已在 cmd/main 定义并被调用"

# 守护必须走【系统 cron】而非 hermes cron —— hermes cron 住在 gateway 进程里，
# gateway 挂了它一起哑，无法守护自己。回归门禁：必须出现 crontab / cron.d 写入。
if ! grep -qE 'crontab -|/etc/cron\.d/' "$TMP/cmd/main"; then
    echo "::error:: cmd/main 未把守护装进系统 cron（crontab 或 /etc/cron.d）—— 用 hermes cron 守护自己无效"
    exit 1
fi
echo "✅ gateway 守护装在系统 cron（不依赖 gateway 自身存活）"

# ── 内核更新通道必须预置好（2026-10-14 加）──────────────────────────
# 真实故障：bundle 的 .git 由 git init 生成、只带 core+user 段，没有 remote。
# 装机后 `hermes update` 必然报
#   fatal: 'origin' does not appear to be a git repository
# 而 FPK 升级【不会】覆盖内核（install_callback 见 venv/bin/hermes 存在就跳过），
# 于是「升了 FPK 但内核纹丝不动、且再也升不上去」。
# ⚠️ bundle 的 .git 不进包：fnpack 会过滤隐藏目录（松散对象 gc 后 cp stat 失败），
#    所以更新通道靠 install_callback 装机时补 + cmd/main 启动时自愈（两级幂等）。
grep -vE '^[[:space:]]*#' "$TMP/cmd/install_callback" > "$TMP/icb.code" 2>/dev/null || true
if ! grep -q "remote.origin.fetch" "$TMP/icb.code"; then
    echo "::error:: install_callback 未预置 remote/refspec —— bundle 缺 remote 时装机后 hermes update 永久不可用"
    exit 1
fi
# 自愈不得锁进 `if [ ! -d .git ]` 分支 —— 那正是老 bug 的形态：bundle 带 .git 时整段跳过。
if grep -A 6 'if \[ ! -d "\\\${AGENT_ROOT}/.git" \]' "$TMP/icb.code" | grep -q 'git init -q'; then
    echo "::warning:: install_callback 的 git 初始化仍在 [ ! -d .git ] 分支内（旧形态），确认 remote 自愈在分支外即可"
fi
if ! grep -q "^ensure_agent_update_channel()" "$TMP/cmd/main"; then
    echo "::error:: cmd/main 缺少 ensure_agent_update_channel() —— 已装旧实例只能靠启动自愈修更新通道"
    exit 1
fi
n="$(grep -c '^\s*ensure_agent_update_channel$' "$TMP/cmd/main" || true)"
if [ "${n:-0}" -lt 1 ]; then
    echo "::error:: cmd/main 定义了 ensure_agent_update_channel() 但未在 start_process 中调用"
    exit 1
fi
echo "✅ 内核更新通道两级预置（install_callback 装机补 + cmd/main 启动自愈）"

# 上游改名（hermes-studio -> ekko-studio）后新增了 ekko-studio-mcp / ekko-studio-web
# 两个 bin 入口。若 fix_bundled_bin_links 又退回写死清单，走 bundled 离线复制路径时
# 这些入口会缺失，MCP 配置里的命令就找不到 —— 必须从 package.json 动态读取。
if ! grep -q 'package.json' "$TMP/cmd/install_callback" 2>/dev/null; then
    echo "::error:: install_callback 的 fix_bundled_bin_links 未从 package.json 读取 bin 字段，"
    echo "         上游新增 bin 入口时离线复制路径会漏建软链，构建中止"
    exit 1
fi
echo "✅ bin 入口按 package.json 动态重建（上游改名/新增入口不会漏）"

# ── 内核完整性三防（2026-10-14 技术简报根因固化，防复发门禁）──
# 事故模型：上游 pyproject 把全部核心依赖 gate 在 python_version >= '3.14'
# marker 上；历史 vendored install.sh 用 PYTHON_VERSION=3.11 建 venv →
# 依赖被静默跳过 → 残缺内核正常出厂。锚点若混入 +canary/日期式 tag，
# 包内代码与 hermes_cli 版本显示同样失真。

# 1) 锚点格式：由真源 anchor-ok 判定（vX.Y.Z，或人工显式写的 main；
#    拒绝 +canary 预发布与日期式 v2026.x.y 回潮）
if [ -f "$TMP/config/bootstrap/hermes-agent-version.env" ]; then
    ANCHOR="$(grep '^HERMES_AGENT_VERSION=' "$TMP/config/bootstrap/hermes-agent-version.env" | cut -d= -f2 | tr -d '[:space:]' || true)"
    if printf '%s' "$ANCHOR" | grep -q 'canary'; then
        echo "::error:: HERMES_AGENT_VERSION 锚点含 +canary 预发布标签: '$ANCHOR' —— 打包只跟正式 release，构建中止"
        exit 1
    fi
    # 口径从唯一真源取（detect-upstream.py anchor-ok），不在本文件重抄正则 ——
    # 2026-10-15 实测：同一规则曾有手抄三份的副本，收紧时漏改本处，导致
    # 「注释声明拒绝日期式、实现照样放行」。取值失败也必须 fail-closed。
    DETECT="$(dirname "$0")/detect-upstream.py"
    if [ ! -f "$DETECT" ]; then
        echo "::error:: 缺 scripts/detect-upstream.py，无法校验锚点口径（拒绝放行）"
        exit 1
    fi
    if ! python3 "$DETECT" anchor-ok "$ANCHOR"; then
        echo "::error:: HERMES_AGENT_VERSION 锚点非法: '$ANCHOR'（见上：只许 vX.Y.Z 正式语义化标签或显式 main；日期式 v2026.x.y 与 +canary 已停止跟随）"
        exit 1
    fi
    echo "✅ Agent 版本锚点合规 ($ANCHOR)"
else
    echo "::error:: 外层缺 config/bootstrap/hermes-agent-version.env（内核锚点丢失，auto-update 链路断裂）"
    exit 1
fi

# 2) vendored install.sh 的 Python 地板必须 >= 3.14。
#    重新 vendor 上游脚本时极易把上游的 3.11 默认值带回来 → marker 静默跳依赖。
tar xzf "$TMP/app.tgz" -C "$TMP" config/bootstrap/hermes-agent-install.sh 2>/dev/null || true
if [ -f "$TMP/config/bootstrap/hermes-agent-install.sh" ]; then
    # 先落文件再 grep（勿用管道，SIGPIPE 假阴性，见本文件开头纪律）
    grep -E '^PYTHON_VERSION=' "$TMP/config/bootstrap/hermes-agent-install.sh" > "$TMP/pyver.line" 2>/dev/null || true
    PYV="$(sed -n '1p' "$TMP/pyver.line" | tr -d '"' | cut -d= -f2)"
    case "$PYV" in
        3.14|3.15|3.1[6-9]|3.[2-9][0-9]) : ;;
        *) echo "::error:: vendored install.sh PYTHON_VERSION='$PYV'（要求 >= 3.14）—— 低版本 venv 会让 marker 依赖静默跳过，装机必残，构建中止"; exit 1 ;;
    esac
    if [ "$(grep -cE '^PYTHON_VERSION=' "$TMP/config/bootstrap/hermes-agent-install.sh")" != "1" ]; then
        echo "::error:: install.sh 出现多行 PYTHON_VERSION 赋值（后写覆盖先写，FPK-PATCH 可能被重新 vendor 抹掉），构建中止"
        exit 1
    fi
    echo "✅ vendored install.sh Python 地板 = $PYV (>= 3.14)"
    # 动态地板块必须活着：上游核心 marker 跳 3.15 时全靠它自动抬；
    # re-vendor 上游脚本会整段抹掉 FPK-AUTO-FLOOR → 回到人工断点，必须红。
    if ! grep -q 'FPK-AUTO-FLOOR' "$TMP/config/bootstrap/hermes-agent-install.sh"; then
        echo "::error:: vendored install.sh 缺 FPK-AUTO-FLOOR 动态地板块（被 re-vendor 抹除？）——上游跳版本时将需人工改死值，构建中止"
        exit 1
    fi
else
    echo "::error:: 内层缺 config/bootstrap/hermes-agent-install.sh（bundled 安装器丢失）"
    exit 1
fi

# 3) 装后校验脚本必须【同时】存在于内层并被 install_callback 硬调用（fail 级）。
#    只有脚本没有调用 = 残缺内核照样静默出厂。
if ! grep -qE '^config/bootstrap/hermes-agent-postinstall\.sh$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 config/bootstrap/hermes-agent-postinstall.sh（装后内核完整性校验脚本丢失）"
    exit 1
fi
if ! grep -q 'hermes-agent-postinstall.sh' "$TMP/cmd/install_callback"; then
    echo "::error:: cmd/install_callback 未调用 hermes-agent-postinstall.sh —— Python 地板/依赖完整性/stamp 无人校验，构建中止"
    exit 1
fi
if ! grep -qE 'fail "post-install kernel verification failed' "$TMP/cmd/install_callback"; then
    echo "::error:: install_callback 对 postinstall 校验失败只是警告未 fail —— 校验形同虚设，构建中止"
    exit 1
fi
if ! grep -q 'FPK-DYNFLOOR' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null \
   || ! grep -q 'FPK-DYNDEPS' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null; then
    tar xzf "$TMP/app.tgz" -C "$TMP" config/bootstrap/hermes-agent-postinstall.sh 2>/dev/null || true
    if ! grep -q 'FPK-DYNFLOOR' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null \
       || ! grep -q 'FPK-DYNDEPS' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null; then
        echo "::error:: postinstall 缺 FPK-DYNFLOOR/FPK-DYNDEPS 动态校验 —— 上游改 marker/增删依赖将回到人工断点，构建中止"
        exit 1
    fi
fi
echo "✅ 装后内核完整性校验已内嵌且失败即判安装失败（动态地板+动态依赖完整性）"

# 4) 界面显示版本（Studio 版本栏）门禁必须随包且接线。
#    版本口径唯一真源 = ensure-kernel.sh，且探测命令必须与 Studio 前端逐字一致
#    （hermes_cli.__version__ + find_spec('hermes_cli.main')）—— 换了探测面就不再
#    代表界面显示的值，那样断言等于白写。
tar xzf "$TMP/app.tgz" -C "$TMP" config/bootstrap/ensure-kernel.sh 2>/dev/null || true
if [ ! -f "$TMP/config/bootstrap/ensure-kernel.sh" ]; then
    echo "::error:: 内层 app.tgz 解不出 config/bootstrap/ensure-kernel.sh（界面版本判定真源丢失）"
    exit 1
fi
for need in 'displayed' 'assert-displayed' 'hermes_cli.__version__' "find_spec('hermes_cli.main')"; do
    if ! grep -qF "$need" "$TMP/config/bootstrap/ensure-kernel.sh"; then
        echo "::error:: ensure-kernel.sh 缺界面显示版本判定要素: $need（装了新 fpk 也没人验证界面显示的是不是本包版本）"
        exit 1
    fi
done
echo "✅ ensure-kernel.sh 含界面显示版本判定（探测面与 Studio 前端一致）"

if ! grep -q 'assert-displayed' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null; then
    tar xzf "$TMP/app.tgz" -C "$TMP" config/bootstrap/hermes-agent-postinstall.sh 2>/dev/null || true
fi
if ! grep -q 'assert-displayed' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null; then
    echo "::error:: hermes-agent-postinstall.sh 未调用 ensure-kernel.sh assert-displayed —— 装完 fpk 界面显示版本无人断言，构建中止"
    exit 1
fi
if ! grep -q -- '--expect-version' "$TMP/config/bootstrap/hermes-agent-postinstall.sh" 2>/dev/null; then
    echo "::error:: hermes-agent-postinstall.sh 不认 --expect-version —— install_callback 的界面版本硬门禁传参无效，构建中止"
    exit 1
fi
echo "✅ 装后界面显示版本已接硬门禁（--expect-version + assert-displayed，不符即回滚）"

# ── 反自检：确保上面的门禁真的会拦 ──
# 所有检查都依赖 grep 的返回值。若有人改回 `echo "$BIG" | grep -q ...`，
# SIGPIPE 会让检查静默失效（命中也会被判成未命中）。这里断言「已知存在的
# 条目能被找到」，找得到才说明 grep 这条通路是活的。
for probe in '^manifest$' '^cmd/main$'; do
    if ! grep -qE "$probe" "$TMP/outer.list"; then
        echo "::error:: 门禁自检失败：外层清单里应当存在 $probe 却匹配不到，检查逻辑已失效"
        exit 1
    fi
done
if ! grep -qE '^hermes-agent-node/node_modules/' "$TMP/inner.list"; then
    echo "::error:: 门禁自检失败：内层清单匹配异常，检查逻辑已失效"
    exit 1
fi
echo "✅ 门禁自检通过（grep 通路正常，不存在 SIGPIPE 假阴性）"

echo "✅ 全部门禁通过"
