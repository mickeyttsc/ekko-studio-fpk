#!/bin/bash
# ── 内核版本闸门（唯一真源）──────────────────────────────────────────────────
#
# 目的：让「装新 fpk」把运行内核带到该 fpk 内嵌的版本。
#
# 旧行为（2026-10-15 用户实测暴露的坑）：install_callback 见 venv/bin/hermes
# 存在就 return，于是升级 fpk 永远不碰内核 —— 界面显示的内核版本一直停在装机
# 那一版，包里内嵌的新内核只对全新机器生效。用户视角就是「APK/fpk 都更新了，
# 系统里显示的内核还是 0.22.0」。
#
# 判据只比「上游正式语义化版本」，不比提交号 —— 内嵌源码包的 .git 不进 fpk，
# 装机后是本地 git init 出来的假历史，两边没有可比对的 sha。
#
# 输出契约（stdout）：
#   第 1 行 = fresh | upgrade | skip
#   第 2 行 = 人类可读理由（写日志用）
#   fresh   = 没有 venv/bin/hermes（全新安装，走完整安装流程）
#   upgrade = 内嵌版本 > 已装版本（需要原地重装内核）
#   skip    = 已装版本 >= 内嵌版本，或任一侧版本无法判定（绝不猜、绝不降级）
#
# 用法：
#   ensure-kernel.sh decide    <AGENT_ROOT> <APP_DIR>
#   ensure-kernel.sh installed <AGENT_ROOT>
#   ensure-kernel.sh bundled   <APP_DIR>
#
# ⛔ 调用方不得重抄版本解析/比较逻辑（本项目在别处重抄正则吃过亏：三处漏改两处，
#    见 MAINTAINING 事故表）。行为契约由 scripts/ensure-kernel-selftest.sh 钉住，
#    build.yml 与 verify-fpk-gates.sh 都会跑它。
# ⚠️ 版本正则的 major 限 3 位：上游历史 tag 是日期式（v2026.9.24，major 是 4 位
#    年份），放开就会算出「2026.9.24 > 0.22.1」这种方向相反的比较，进而把内核
#    判成「已装更新」而永不升级。口径与 scripts/detect-upstream.py 的
#    AGENT_TAG_PATTERN 一致（那边是唯一真源，这边只做防御性复判）。

set -u

SEMVER_ERE='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'

# 规范化：去空白 / v 前缀 / +canary、-rc 等后缀；非 X.Y.Z（major ≤ 3 位）输出空
norm_ver() {
    local v="${1:-}"
    v="$(printf '%s' "${v}" | tr -d '[:space:]')"
    v="${v#v}"
    v="${v%%+*}"
    v="${v%%-*}"
    printf '%s' "${v}" | grep -qE "${SEMVER_ERE}" && printf '%s' "${v}"
    return 0
}

# 已装内核版本。首选 hermes --version —— 它是唯一能反映「用户自己跑过
# hermes update」的真实版本；标记文件只反映 fpk 装了什么，update 不会更新它。
installed_ver() {
    local root="${1:-}" out=""
    if [ -x "${root}/venv/bin/hermes" ]; then
        out="$(timeout 30 "${root}/venv/bin/hermes" --version 2>/dev/null \
               | grep -oE 'Hermes Agent v[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1 \
               | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' || true)"
    fi
    [ -n "${out}" ] || out="$(norm_ver "$(cat "${root}/.fpk-kernel-version" 2>/dev/null || true)")"
    [ -n "${out}" ] || out="$(norm_ver "$(cat "${root}/.bundled-agent-ref" 2>/dev/null || true)")"
    printf '%s' "${out}"
}

# fpk 内嵌内核版本：优先包内源码树的 ref 标记（build-fpk.sh 写入的锚点值），
# 回退到外层锚点 env（回调期源码树尚未解包时也能判定）。
bundled_ver() {
    local app_dir="${1:-}" v=""
    v="$(norm_ver "$(cat "${app_dir}/hermes-agent-src/.bundled-agent-ref" 2>/dev/null || true)")"
    if [ -z "${v}" ] && [ -f "${app_dir}/config/bootstrap/hermes-agent-version.env" ]; then
        v="$(norm_ver "$(grep -E '^HERMES_AGENT_VERSION=' \
             "${app_dir}/config/bootstrap/hermes-agent-version.env" 2>/dev/null \
             | head -1 | cut -d= -f2 || true)")"
    fi
    printf '%s' "${v}"
}

decide() {
    local root="${1:-}" app_dir="${2:-}" inst bun top
    if [ -z "${root}" ] || [ -z "${app_dir}" ]; then
        printf 'skip\n%s\n' "调用参数缺失（AGENT_ROOT/APP_DIR 为空）—— 保守不动内核"
        return 3
    fi
    if [ ! -x "${root}/venv/bin/hermes" ]; then
        printf 'fresh\n%s\n' "未安装内核（${root}/venv/bin/hermes 不存在）"
        return 0
    fi
    inst="$(installed_ver "${root}")"
    bun="$(bundled_ver "${app_dir}")"
    if [ -z "${bun}" ]; then
        printf 'skip\n%s\n' "内嵌内核版本无法判定（缺 .bundled-agent-ref/锚点，或非语义化标签）—— 不猜、不动内核"
        return 0
    fi
    if [ -z "${inst}" ]; then
        printf 'skip\n%s\n' "已装内核版本无法判定（hermes --version 失败且无标记文件）—— 不自动重装，避免重装循环"
        return 0
    fi
    if [ "${inst}" = "${bun}" ]; then
        printf 'skip\n%s\n' "已装 ${inst} = 内嵌 ${bun}（无需同步）"
        return 0
    fi
    top="$(printf '%s\n%s\n' "${inst}" "${bun}" | sort -V | tail -1)"
    if [ "${top}" = "${bun}" ]; then
        printf 'upgrade\n%s\n' "内嵌 ${bun} > 已装 ${inst}（内核落后，需原地重装）"
    else
        printf 'skip\n%s\n' "已装 ${inst} > 内嵌 ${bun}（用户已自行升级内核，绝不降级）"
    fi
    return 0
}

case "${1:-}" in
    decide)    decide "${2:-}" "${3:-}" ;;
    installed) installed_ver "${2:-}" ;;
    bundled)   bundled_ver "${2:-}" ;;
    *) echo "用法: $0 decide|installed|bundled <AGENT_ROOT> [APP_DIR]" >&2; exit 2 ;;
esac
