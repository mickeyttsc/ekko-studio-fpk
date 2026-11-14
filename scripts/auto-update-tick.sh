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
# 先自证标签过滤器行为与声明一致，再探测。过滤器一旦回归（例如 major 放宽回
# [0-9]+），日期式 tag 会被当成「最新正式版」写进锚点并被 CI 打包 —— 所以这里
# 失败就【本轮不写锚点】，把回归挡在源头，而不是留下一个装错内核的包。
if ! python3 scripts/detect-upstream.py selftest >/dev/null 2>&1; then
    # ::error:: 注解让它出现在 Actions 的 Annotations 区，而不是埋在 6 小时日志里
    echo "::error::detect-upstream.py selftest 失败 —— 标签口径回归，本轮拒绝写锚点（长驻 job 会继续空转，必须人工修）"
    log "ERROR detect-upstream.py selftest 失败（标签过滤器行为与声明不符），本轮拒绝写锚点"
    python3 scripts/detect-upstream.py selftest 2>&1 | tail -6 | while IFS= read -r l; do log "  $l"; done
    exit 0
fi

WEBUI_LATEST="$(python3 scripts/detect-upstream.py webui 2>/dev/null)"
if [ -z "${WEBUI_LATEST}" ]; then
    log "WARN 未能解析可打包的 hermes-web-ui 版本（上游可能改了资产命名），本轮跳过"
    exit 0
fi

AGENT_LATEST="$(python3 scripts/detect-upstream.py agent 2>/dev/null)"
if [ -z "${AGENT_LATEST}" ]; then
    # 收紧口径后的新失败模式：上游若整体退回日期式命名，语义式候选为空，
    # 锚点会【静默冻结】在当前值、长驻 job 空转 —— 必须显式喊出来。
    echo "::warning::hermes-agent 无可用的语义化正式 release 标签（上游可能改用日期式命名）—— 锚点保持 ${CUR_AGENT:-未知} 不变，需人工确认跟随策略"
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

# ── 1b. 复位上一轮失败的现场（必须早于读锚点）────────────────────────────────
# 2026-11-14 实锤：上一轮 push 失败可能把 checkout 留在「rebase 冲突中 + 锚点文件已被
# 本地改写」的状态。此时本轮读到的是【本地改过的锚点】→ 判 up-to-date；而补推分支要
# 求 origin/main..HEAD 有提交，冲突态下计数为 0 → 既不自愈也不补推，长驻 job 剩余
# 时长全部空转（当天把 0.8.23 拖了几小时，只有换 job 重新 checkout 才恢复）。
# 修法：每轮开始先把可疑现场复位到 origin/main —— 锚点文件全都能重算，丢弃是安全的。
# 只在「有残留 rebase」或「版本文件有未提交改动」时复位，不动正常待推的提交。
if [ -d .git ]; then
    if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        log "检测到残留 rebase（上一轮 push 失败留下的）→ 中止"
        git rebase --abort >/dev/null 2>&1 || true
    fi
    if git fetch -q origin main 2>/dev/null; then
        DIRTY_VER="$(git status --porcelain -- "$WEBUI_ENV" "$AGENT_ENV" config/upstream manifest 2>/dev/null | head -3 | tr '\n' ' ')"
        if [ -n "${DIRTY_VER}" ]; then
            log "检测到未提交的版本文件改动（上一轮失败留下的）→ 复位到 origin/main: ${DIRTY_VER}"
            git reset --hard -q origin/main >/dev/null 2>&1 || true
        fi
    fi
fi

# ── 2. 与当前记录比对 ────────────────────────────────────────────────────────
CUR_WEBUI="$(grep '^HERMES_STUDIO_VERSION=' "$WEBUI_ENV" | cut -d= -f2)"
CUR_AGENT="$(grep '^HERMES_AGENT_VERSION=' "$AGENT_ENV" | cut -d= -f2)"
CUR_VER="$(grep '^version' manifest | cut -d= -f2 | tr -d ' ')"
CUR_BASE="${CUR_VER%-*}"
CUR_BUILD="${CUR_VER##*-}"
case "${CUR_BUILD}" in ''|*[!0-9]*) CUR_BUILD=0 ;; esac

# ── agent 引擎地板闸门（在 bump 之前判「这版我们跑得动吗」）───────────────────
# 背景（2026-11-03 实测，连红 5 次构建）：上游 hermes-agent v0.22.6 把
#   engines.node 从 "^22.22.0 || ^24.11.0 || >=26.0.0" 抬成 ">=26"，
#   而源码树自带 .npmrc 里 engine-strict=true —— 本包捆绑的 node 24 当场
#   EBADENGINE，npm install 全挂、hermes-agent-node/node_modules 生成不出来，
#   构建只能 fail-closed 红掉。旧 tick 只比版本号高低，完全看不出这层不兼容，
#   于是每轮都「成功 bump」→ 每轮都构建失败，锚点停在跑不动的版本上。
# 现改为：拉候选 tag 的 package.json，用 config/bootstrap/node-runtime.env 声明的
#   本包 node 版本判它的 engines.node；不是 yes（no / unknown / 网络失败）一律
#   【保留原锚点】并喊 ::warning::，让人知道「上游又抬地板了」而不是静默卡住。
#   fail-closed 的理由和标签闸门一致：宁可不跟，也不出装不起来的包。
if [ "${AGENT_LATEST}" != "${CUR_AGENT}" ]; then
    NODE_ENGINE="$(grep '^NODE_RUNTIME_ENGINE=' config/bootstrap/node-runtime.env 2>/dev/null | cut -d= -f2)"
    if [ -z "${NODE_ENGINE}" ]; then
        log "ERROR 读不到 config/bootstrap/node-runtime.env 的 NODE_RUNTIME_ENGINE —— 本轮不改 agent 锚点"
        echo "::error::缺 NODE_RUNTIME_ENGINE（config/bootstrap/node-runtime.env），引擎地板无法判定，已保持锚点 ${CUR_AGENT}"
        AGENT_LATEST="${CUR_AGENT}"
    else
        ENG="$(python3 scripts/detect-upstream.py agent-node-ok "${AGENT_LATEST}" "${NODE_ENGINE}" 2>/dev/null)"
        if [ "${ENG}" != "yes" ]; then
            log "候选 agent ${AGENT_LATEST} 的 engines.node 不被本包 node ${NODE_ENGINE} 满足（判定=${ENG:-空}）—— 拒绝 bump，保留 ${CUR_AGENT}"
            echo "::warning::hermes-agent ${AGENT_LATEST} 要求更高的 node（本包 ${NODE_ENGINE}，判定=${ENG:-unknown}），已保留锚点 ${CUR_AGENT}；要跟上请先升级 config/bootstrap/node-runtime.env 并重打 node"
            AGENT_LATEST="${CUR_AGENT}"
        fi
    fi
fi

WEBUI_ASSET="hermes-web-ui-${WEBUI_LATEST}.tar.gz"
PIN_ENV="config/upstream/${WEBUI_ASSET}.env"

CHANGED=0
if [ "${WEBUI_LATEST}" != "${CUR_WEBUI}" ]; then CHANGED=1; fi

# ── agent 锚点单调性守卫 ─────────────────────────────────────────────────────
# 「published_at 最新」≠「版本最高」：上游重新发布一个旧 tag（backport 补丁、
# 或误重发）会让它成为 published_at 最新者，照写就把内核锚点【倒退】了，
# 进而打包出比现状更旧的内核。故候选低于当前锚点时保持现值并显式告警；
# 确需回退请人工把锚点写成目标值（人工动作就是明确意图）。
if [ -n "${CUR_AGENT}" ] && [ "${AGENT_LATEST}" != "${CUR_AGENT}" ]; then
    DOWNGRADE="$(python3 - "${CUR_AGENT}" "${AGENT_LATEST}" <<'PY'
import sys
def key(t):
    t = t.strip()
    if not t.startswith("v"):
        return None                      # main 等非 vX.Y.Z：不参与比较
    try:
        p = tuple(int(x) for x in t[1:].split("."))
    except ValueError:
        return None
    return p if len(p) == 3 else None
a, b = key(sys.argv[1]), key(sys.argv[2])
# 输出而非退出码承载结论 —— 早前用 sys.exit(1 if 倒退 else 0) 配 `if cmd; then 回退`
# 是极性反的：不是倒退时退出 0，反而每轮都把候选打回现值，自动升级通道被静默锁死。
print("yes" if (a is not None and b is not None and b < a) else "no")
PY
)"
    # 只有明确判出「not 倒退」(no) 才放行；yes / 空串（python 崩溃、被 OOM kill、
    # 输出异常）一律保持现值 —— fail-closed：拿不准就不动锚点，
    # 也不能因为判不出来就写进一个可能更旧的内核。
    if [ "${DOWNGRADE}" != "no" ]; then
        if [ "${DOWNGRADE}" = "yes" ]; then
            log "候选 agent ${AGENT_LATEST} 低于当前锚点 ${CUR_AGENT}（上游可能重发旧 tag）—— 拒绝倒退"
            echo "::warning::hermes-agent 候选 ${AGENT_LATEST} 低于当前锚点 ${CUR_AGENT}，已拒绝倒退"
        else
            log "ERROR 倒退判定不可用（DOWNGRADE='${DOWNGRADE}'）—— 保守起见本轮不改 agent 锚点"
            echo "::error::agent 锚点倒退守卫无法判定（候选=${AGENT_LATEST} 现值=${CUR_AGENT}），已保持现值"
        fi
        AGENT_LATEST="${CUR_AGENT}"
    fi
fi

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
# 抽成函数：推送被拒后需要「复位到远端 → 重算版本号 → 重写 → 重提」，两处逻辑必须同源。
# 判空/判 pin 是否过期都在函数内现算 —— 复位到 origin/main 后远端内容可能已变。
apply_anchors() {
    local new_ver="$1"
    sed -i "s/^HERMES_STUDIO_VERSION=.*/HERMES_STUDIO_VERSION=${WEBUI_LATEST}/" "$WEBUI_ENV"
    sed -i "s/^HERMES_AGENT_VERSION=.*/HERMES_AGENT_VERSION=${AGENT_LATEST}/" "$AGENT_ENV"

    if [ ! -f "$PIN_ENV" ] || ! grep -qF "HERMES_WEB_UI_SHA256=${WEBUI_SHA}" "$PIN_ENV" 2>/dev/null; then
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
    sed -i "s/^version[[:space:]]*=.*/version               = ${new_ver}/" manifest
}

# read_version_triplet：从当前工作树（复位后=远端最新）重读版本号三元组
read_version_triplet() {
    CUR_WEBUI="$(grep '^HERMES_STUDIO_VERSION=' "$WEBUI_ENV" | cut -d= -f2)"
    CUR_AGENT="$(grep '^HERMES_AGENT_VERSION=' "$AGENT_ENV" | cut -d= -f2)"
    CUR_VER="$(grep '^version' manifest | cut -d= -f2 | tr -d ' ')"
    CUR_BASE="${CUR_VER%-*}"
    CUR_BUILD="${CUR_VER##*-}"
    case "${CUR_BUILD}" in ''|*[!0-9]*) CUR_BUILD=0 ;; esac
}

next_version() {
    if [ "${WEBUI_LATEST}" != "${CUR_BASE}" ]; then
        echo "${WEBUI_LATEST}-1"
    else
        echo "${CUR_BASE}-$((CUR_BUILD + 1))"
    fi
}

NEW_VER="$(next_version)"
apply_anchors "$NEW_VER"
log "新 FPK 版本: ${NEW_VER}"

# ── 4. 提交并推送（失败可重试，绝不停在冲突态）──────────────────────────────
# 2026-11-14 实测故障（把 0.8.23 拖了几小时）：这里原本是
#   git commit → git pull --rebase --autostash → git push
# 而 autostash 的 rebase 一旦与远端同一区域冲突（当天人工刚把 manifest 的 version
# 行从 0.8.22-1 改成 0.8.22-2），rebase 就停在半途：push 必失败，且后续每轮读到的
# 锚点已是本地改过的值 → 判「up-to-date」；补推分支要求 origin/main..HEAD 有提交，
# 冲突态下计数为 0 → 既不自愈也不补推，整个长驻 job 剩余 5 小时全空转，
# 只能等下一次 job 重新 checkout 才恢复（表现为「自动构建像停了」）。
# 现改为：直接 push；被拒就 abort rebase + 复位到 origin/main + 重算版本号重来，
# 最多 3 次。复位丢弃的内容（锚点/manifest 版本行）全部可由本函数重算，安全。
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

PUSHED=0
for attempt in 1 2 3; do
    git add "$WEBUI_ENV" "$AGENT_ENV" config/upstream manifest
    if git diff --cached --quiet; then
        # 与远端已一致（可能被其它 run/人工处理过）：无需提交，直接结束本轮
        log "无实际改动可提交（可能已被其它 run 处理）"
        PUSHED=1
        break
    fi
    git commit -q -m "chore: auto-bump upstream -> web-ui ${WEBUI_LATEST} / agent ${AGENT_LATEST} (FPK ${NEW_VER})"
    if git push -q origin main 2>/dev/null; then
        PUSHED=1
        break
    fi
    log "推送被拒（第 ${attempt} 次）→ 中止残留 rebase、复位到 origin/main 后重算重试"
    git rebase --abort >/dev/null 2>&1 || true
    if ! git fetch -q origin main 2>/dev/null; then
        sleep 5
        continue
    fi
    git reset --hard -q origin/main >/dev/null 2>&1 || { log "ERROR 复位到 origin/main 失败"; break; }
    read_version_triplet
    NEW_VER="$(next_version)"
    apply_anchors "$NEW_VER"
    log "重算后 FPK 版本: ${NEW_VER}"
done

if [ "${PUSHED}" != "1" ]; then
    log "ERROR 推送三次均失败（下一轮重试；工作树已复位，不会卡在冲突态）"
    exit 0
fi
log "已推送 bump 提交"

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
