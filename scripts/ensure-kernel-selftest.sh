#!/bin/bash
# ── 内核版本闸门的行为契约自检（无网络、无真实内核）─────────────────────────
#
# 为什么需要它：闸门的判错方向是「静默」的 —— 判成 skip 时内核纹丝不动，
# 没有任何报错，用户只在界面上看到版本没变（这正是 2026-10-15 那次投诉的形态）。
# 所以「文件存在 + 有正则」这类结构门禁不够，必须钉住判定结果本身。
#
# 用法: bash scripts/ensure-kernel-selftest.sh
# 退出码 0 = 全部通过；非 0 = 有断言失败（构建必须中止）。
#
# 覆盖的坑：
#   · 日期式 tag（v2026.9.24）必须判成「不可比」而不是「更新」—— 否则
#     sort -V 会得出 2026.9.24 > 0.22.1，内核永远升不上去。
#   · 用户自己 hermes update 到更新版本时必须 skip（绝不降级）。
#   · hermes --version 不可用时要退到 fpk 装的标记文件，而不是一律 skip。
#   · 两位/三位数段（0.9.9 → 0.10.0）不能按字符串比大小。

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/app/config/bootstrap/ensure-kernel.sh"

if [ ! -f "${HELPER}" ]; then
    echo "::error:: 找不到 ${HELPER}（内核版本闸门脚本必须随包）"
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0

# 造一棵假内核树：venv/bin/hermes 是桩，--version 输出由参数决定
mk_tree() {
    local case_dir="$1" stub_out="$2"
    mkdir -p "${case_dir}/agent/venv/bin" "${case_dir}/app/hermes-agent-src" \
             "${case_dir}/app/config/bootstrap"
    if [ -n "${stub_out}" ]; then
        cat > "${case_dir}/agent/venv/bin/hermes" <<STUB
#!/bin/bash
echo "${stub_out}"
STUB
        chmod +x "${case_dir}/agent/venv/bin/hermes"
    fi
}

# check <名称> <期望判定> <case 目录>
check() {
    local name="$1" expect="$2" dir="$3" got why
    got="$(bash "${HELPER}" decide "${dir}/agent" "${dir}/app" 2>/dev/null | head -1)"
    why="$(bash "${HELPER}" decide "${dir}/agent" "${dir}/app" 2>/dev/null | sed -n '2p')"
    if [ "${got}" = "${expect}" ]; then
        printf '  ✅ %-28s → %s (%s)\n' "${name}" "${got}" "${why}"
        PASS=$((PASS + 1))
    else
        printf '  ❌ %-28s → 期望 %s，实得 "%s"\n' "${name}" "${expect}" "${got}"
        FAIL=$((FAIL + 1))
    fi
}

echo "内核版本闸门自检（${HELPER}）"

# 1) 全新机器：没有内核 → fresh
D="${TMP}/fresh"; mk_tree "${D}" ""; check "fresh（无内核）" "fresh" "${D}"

# 2) 内嵌更新 → upgrade
D="${TMP}/up"; mk_tree "${D}" "Hermes Agent v0.22.0 (2026.9.24) · stable · local deadbeef"
echo "v0.22.1" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "内嵌更新" "upgrade" "${D}"

# 3) 一致 → skip
D="${TMP}/eq"; mk_tree "${D}" "Hermes Agent v0.22.1 (2026.9.24) · stable · local deadbeef"
echo "v0.22.1" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "版本一致" "skip" "${D}"

# 4) 用户自己升到更新版 → 绝不降级
D="${TMP}/newer"; mk_tree "${D}" "Hermes Agent v0.23.0 (2026.9.24) · stable · local deadbeef"
echo "v0.22.1" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "已装更新（防降级）" "skip" "${D}"

# 5) 日期式内嵌 tag → 不可比，不动内核（不能算成「更新」）
D="${TMP}/date"; mk_tree "${D}" "Hermes Agent v0.22.0 (2026.9.24) · stable · local deadbeef"
echo "v2026.9.24" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "日期式 tag（不可比）" "skip" "${D}"

# 6) hermes --version 不可用 → 退到 fpk 标记文件
D="${TMP}/marker"; mk_tree "${D}" "Traceback (most recent call last): boom"
echo "v0.22.0" > "${D}/agent/.fpk-kernel-version"
echo "v0.22.1" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "版本桩失效→标记回退" "upgrade" "${D}"

# 7) 内嵌 ref 缺失 → 退到外层锚点 env
D="${TMP}/env"; mk_tree "${D}" "Hermes Agent v0.22.0 (2026.9.24) · stable · local deadbeef"
echo "HERMES_AGENT_VERSION=v0.22.1" > "${D}/app/config/bootstrap/hermes-agent-version.env"
check "ref 缺失→锚点 env 回退" "upgrade" "${D}"

# 8) 两侧都判不出 → skip（不猜）
D="${TMP}/unknown"; mk_tree "${D}" "Traceback (most recent call last): boom"
check "两侧皆不可判" "skip" "${D}"

# 9) 数字段位数不同（0.9.9 → 0.10.0）不能被字符串比较骗过
D="${TMP}/digits"; mk_tree "${D}" "Hermes Agent v0.9.9 (2026.9.24) · stable · local deadbeef"
echo "v0.10.0" > "${D}/app/hermes-agent-src/.bundled-agent-ref"
check "0.9.9 → 0.10.0" "upgrade" "${D}"

# 10) 参数缺失必须给出可用输出（第 1 行非空），不能崩在调用方手里
got="$(bash "${HELPER}" decide "" "" 2>/dev/null | head -1)"
if [ -n "${got}" ]; then
    printf '  ✅ %-28s → %s\n' "参数缺失仍给判定" "${got}"
    PASS=$((PASS + 1))
else
    printf '  ❌ %-28s → 输出为空（调用方会拿到空判定）\n' "参数缺失仍给判定"
    FAIL=$((FAIL + 1))
fi

echo "内核版本闸门自检：通过 ${PASS} / 失败 ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
