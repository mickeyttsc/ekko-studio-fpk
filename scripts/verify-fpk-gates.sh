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
if grep -vE '^[[:space:]]*#' "$TMP/cmd/install_callback" | grep -q 'DATA_DIR}/\.hermes/\.env'; then
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

if grep -hvE '^[[:space:]]*#' "$TMP"/cmd/* 2>/dev/null | grep -qE 'pkill[^|]*"(bin/|dist/)'; then
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
