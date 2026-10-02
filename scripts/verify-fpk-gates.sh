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

# 桌面入口必须是 ${wizard_port}（端口可配）而不是写死值：
# 写死会让「应用设置里改端口」失效 —— 入口跟着变、服务还在老端口，页面打不开。
if ! grep -qE '^ui/config$' "$TMP/inner.list"; then
    echo "::error:: 内层缺 ui/config，桌面图标无法注册"
    exit 1
fi
tar xzf "$TMP/app.tgz" -C "$TMP" ui/config
if ! grep -q '\${wizard_port}' "$TMP/ui/config"; then
    echo "::error:: ui/config 的 port 未使用 \${wizard_port}，端口将无法在应用设置中修改"
    exit 1
fi
echo "✅ ui/config 端口使用 \${wizard_port}（可在应用设置中修改）"

# ui/config 的 protocol 必须是非空 http/https：
# 留空会让 fnOS 渲染出入口 url = "://${host}:<port>/"（协议头缺失），
# 客户端只能自己猜协议 —— 猜成 HTTPS 就会用 TLS 打明文 HTTP 端口，
# 手机 App 报 HandshakeException: WRONG_VERSION_NUMBER(tls_record.cc:127)。
# 官方第三方应用（Lucky/1Panel/Sun-Panel/Home-Assistant/lemon-music/miair-next）
# 凡指定了 port 的一律显式写 "http"；protocol 为空只出现在「无 port、走路径路由」的应用上。
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
    proto = (item or {}).get('protocol')
    if proto not in ('http', 'https'):
        print(f"{name}: protocol={proto!r}（必须显式写 'http' 或 'https'）", file=sys.stderr)
        sys.exit(1)
    # 指定了 port 却不带协议头 = 客户端必然猜错协议
    if (item or {}).get('port') and proto not in ('http', 'https'):
        sys.exit(1)
sys.exit(0)
PY
then
    echo "::error:: ui/config 的 protocol 必须显式写 'http'（留空会导致入口 url 变成 ://host:port/ ，客户端猜成 HTTPS 打明文端口）"
    exit 1
fi
echo "✅ ui/config protocol 显式声明（入口 url 协议头完整）"

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

# 上游改名（hermes-studio -> ekko-studio）后新增了 ekko-studio-mcp / ekko-studio-web
# 两个 bin 入口。若 fix_bundled_bin_links 又退回写死清单，走 bundled 离线复制路径时
# 这些入口会缺失，MCP 配置里的命令就找不到 —— 必须从 package.json 动态读取。
if ! grep -q 'package.json' "$TMP/cmd/install_callback" 2>/dev/null; then
    echo "::error:: install_callback 的 fix_bundled_bin_links 未从 package.json 读取 bin 字段，"
    echo "         上游新增 bin 入口时离线复制路径会漏建软链，构建中止"
    exit 1
fi
echo "✅ bin 入口按 package.json 动态重建（上游改名/新增入口不会漏）"

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
