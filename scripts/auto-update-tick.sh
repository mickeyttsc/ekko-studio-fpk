#!/usr/bin/env bash
# auto-update-tick.sh — 单次上游巡检（一次「tick」）
#
# 设计目标：让 GitHub 侧【全自动】跟随上游，不依赖任何外部机器。
#
# 背景（2026-10-02 实测）：
#   GitHub 的 `on: schedule` 对公共仓极不可靠 —— 单槽位 12 次/天实测只触发
#   4.3 次/天（守约率 36%），且 29 次触发【0 次】落在预期分钟上（全部晚 2~59 分钟），
#   说明主体机制是「延迟投递」而非准点投递。改成 */5（288 次/天）实测 54 分钟
#   0 触发，加密无效。
#   结论：靠 cron 频率追不上上游，必须换机制。
#
# 机制：把「每次 cron 只做一次检查」改成【长驻轮询】——
#   单次 job 内部每 TICK_INTERVAL 秒调用本脚本一次，持续到接近 job 时限；
#   并用 workflow 的 concurrency 让下一次 cron 触发【排队】等待，
#   当前 job 一结束就无缝接管。于是：
#     不可靠的 cron 只需「每 6 小时内成功点火一次」，
#     链路就能 24 小时连续覆盖 —— 把「触发可靠性」问题变成「覆盖时长」问题。
#
# 本脚本只做【一次】巡检，可独立手动运行（不依赖 CI，便于本机验证）。
#
# 退出码：始终 0（巡检失败不应中断长驻循环，由日志体现）。
set -uo pipefail

WEBUI_ENV=config/bootstrap/hermes-studio-version.env
AGENT_ENV=config/bootstrap/hermes-agent-version.env

log() { echo "[$(date -u '+%H:%M:%S')] $*"; }

# ── 1. 探测上游 ──────────────────────────────────────────────────────────────
WEBUI_LATEST="$(python3 scripts/detect-upstream.py webui 2>/dev/null)"
if [ -z "${WEBUI_LATEST}" ]; then
    log "WARN 未能解析可打包的 hermes-web-ui 版本（上游可能改了资产命名），本轮跳过"
    exit 0
fi

AGENT_LATEST="$(python3 scripts/detect-upstream.py agent 2>/dev/null)"
if [ -z "${AGENT_LATEST}" ]; then
    log "WARN 未能解析 hermes-agent 最新 release 标签，本轮跳过"
    exit 0
fi

# 校验 agent 标签真实存在（git/refs/tags 单请求，无重定向，比下 tarball 稳）
if ! python3 scripts/detect-upstream.py agent-tag-exists "${AGENT_LATEST}" >/dev/null 2>&1; then
    log "WARN hermes-agent 标签 ${AGENT_LATEST} 在 GitHub 上不存在，本轮跳过"
    exit 0
fi

WEBUI_SHA="$(python3 scripts/detect-upstream.py sha256 "${WEBUI_LATEST}" 2>/dev/null)"
if ! printf '%s' "${WEBUI_SHA}" | grep -qE '^[0-9a-f]{64}$'; then
    log "WARN 官方 release v${WEBUI_LATEST} 缺 sidecar 或格式非法，本轮跳过"
    exit 0
fi

# ── 2. 与当前记录比对 ────────────────────────────────────────────────────────
CUR_WEBUI="$(grep '^HERMES_STUDIO_VERSION=' "$WEBUI_ENV" | cut -d= -f2)"
CUR_AGENT="$(grep '^HERMES_AGENT_VERSION=' "$AGENT_ENV" | cut -d= -f2)"
CUR_VER="$(grep '^version' manifest | cut -d= -f2 | tr -d ' ')"
CUR_BASE="${CUR_VER%-*}"
CUR_BUILD="${CUR_VER##*-}"
case "${CUR_BUILD}" in ''|*[!0-9]*) CUR_BUILD=0 ;; esac

WEBUI_ASSET="hermes-web-ui-${WEBUI_LATEST}.tar.gz"
PIN_ENV="config/upstream/${WEBUI_ASSET}.env"

CHANGED=0
if [ "${WEBUI_LATEST}" != "${CUR_WEBUI}" ]; then CHANGED=1; fi
if [ "${AGENT_LATEST}" != "${CUR_AGENT}" ]; then CHANGED=1; fi
PIN_STALE=0
if [ ! -f "$PIN_ENV" ] || ! grep -qF "HERMES_WEB_UI_SHA256=${WEBUI_SHA}" "$PIN_ENV" 2>/dev/null; then
    PIN_STALE=1; CHANGED=1
fi

if [ "${CHANGED}" != "1" ]; then
    # ⚠️ 幂等 ≠ 什么都不做：版本已一致，但本地可能还有【未推送成功】的提交
    #    （上一轮 push 失败，例如远端被其它提交推进、瞬时网络故障）。
    #    若这里直接 exit，那些改动永远推不上去、构建也永不触发 ——
    #    实测踩过：bump 成功但 push 失败后，后续每轮都报 up-to-date 而不再重试。
    #    故先补推，再退出。
    if [ -n "${GITHUB_REPOSITORY:-}" ] && git rev-parse --verify origin/main >/dev/null 2>&1; then
        AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
        if [ "${AHEAD:-0}" -gt 0 ]; then
            log "up-to-date 但本地领先远端 ${AHEAD} 个提交 → 补推"
            git pull --rebase --autostash -q origin main 2>/dev/null || true
            if git push -q origin main 2>/dev/null; then
                log "补推成功，触发构建"
                curl -sS -o /dev/null -w '' --max-time 60 -X POST \
                    -H "Authorization: token ${GITHUB_TOKEN}" \
                    -H "Accept: application/vnd.github+json" \
                    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/build.yml/dispatches" \
                    -d '{"ref":"main"}' 2>/dev/null || true
            else
                log "补推仍失败（下一轮重试）"
            fi
            exit 0
        fi
    fi
    log "up-to-date: webui=${CUR_WEBUI} agent=${CUR_AGENT} fpk=${CUR_VER}"
    exit 0
fi

log "发现更新: webui ${CUR_WEBUI} -> ${WEBUI_LATEST} / agent ${CUR_AGENT} -> ${AGENT_LATEST}"

# ── 3. 写回版本锚点与 sha256 固定值 ──────────────────────────────────────────
sed -i "s/^HERMES_STUDIO_VERSION=.*/HERMES_STUDIO_VERSION=${WEBUI_LATEST}/" "$WEBUI_ENV"
sed -i "s/^HERMES_AGENT_VERSION=.*/HERMES_AGENT_VERSION=${AGENT_LATEST}/" "$AGENT_ENV"

if [ "${PIN_STALE}" = "1" ]; then
    mkdir -p config/upstream
    {
        echo "# 上游 hermes-web-ui 预构建产物的固定校验值（入库，由 auto-update 自动更新）"
        echo "#"
        echo "# 为什么固定进版本控制：只做「现拉 sidecar 现比」挡不住上游事后替换同版本"
        echo "# 资产（sidecar 会跟着一起变，等于没校验）。固定值入库才能发现变更。"
        echo "# build-fpk.sh 优先读这里的 SHA256，没有才退回拉取上游 <asset>.sha256 sidecar。"
        echo "HERMES_WEB_UI_VERSION=${WEBUI_LATEST}"
        echo "HERMES_WEB_UI_SHA256=${WEBUI_SHA}"
    } > "$PIN_ENV"
    find config/upstream -maxdepth 1 -name 'hermes-web-ui-*.env' ! -name "$(basename "$PIN_ENV")" -delete 2>/dev/null || true
fi

# 版本号规则：web-ui 主版本变化则重置 build 为 1，否则 build+1
if [ "${WEBUI_LATEST}" != "${CUR_BASE}" ]; then
    NEW_VER="${WEBUI_LATEST}-1"
else
    NEW_VER="${CUR_BASE}-$((CUR_BUILD + 1))"
fi
sed -i "s/^version[[:space:]]*=.*/version               = ${NEW_VER}/" manifest
log "新 FPK 版本: ${NEW_VER}"

# ── 4. 提交并推送 ────────────────────────────────────────────────────────────
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "$WEBUI_ENV" "$AGENT_ENV" config/upstream manifest
if ! git diff --cached --quiet; then
    git commit -q -m "chore: auto-bump upstream -> web-ui ${WEBUI_LATEST} / agent ${AGENT_LATEST} (FPK ${NEW_VER})"
    # 长驻期间可能有其它提交推进了 main，先 rebase 再推，避免被拒
    git pull --rebase --autostash -q origin main 2>/dev/null || true
    if git push -q origin main 2>/dev/null; then
        log "已推送 bump 提交"
    else
        log "ERROR 推送失败（下一轮重试）"
        exit 0
    fi
else
    log "无实际改动可提交（可能已被其它 run 处理）"
fi

# ── 5. 立刻触发构建 ──────────────────────────────────────────────────────────
# ⚠️ 不能用「等 auto-update 结束再由 workflow_run 接力」—— 本 job 会长驻数小时，
#    那样构建要等到 job 结束才发生，等于把「快速跟进」拖成几小时。
#    必须主动 dispatch build.yml（需要 permissions.actions: write）。
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/build.yml/dispatches" \
        -d '{"ref":"main"}' 2>/dev/null || echo 000)"
    if [ "${CODE}" = "204" ]; then
        log "已触发 build.yml（HTTP 204）"
    else
        log "WARN 触发 build.yml 失败 HTTP ${CODE}（bump 已入库，可手动/下次重试）"
    fi
else
    log "本地模式：跳过触发 build.yml（无 GITHUB_TOKEN/GITHUB_REPOSITORY）"
fi

exit 0
