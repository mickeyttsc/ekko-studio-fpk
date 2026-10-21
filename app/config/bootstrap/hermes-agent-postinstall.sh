#!/bin/bash
# ============================================================================
# FPK 装后内核完整性校验 + install-stamp 补写（2026-10-14 根因固化）
#
# 背景（本机实测/技术简报核实过的坑）：
#  1. hermes-agent 上游把全部核心依赖 gate 在 `python_version >= 'X.Y'`
#     marker 上（现值 3.14）。venv 若落在更低版本（历史默认 3.11），这些依赖
#     被【静默跳过】——安装显示成功、hermes 命令存在，但 import openai 即炸，
#     全程无任何报错，归因极难。必须在装后硬性验收。
#  2. 上游 install.sh 完成后只写 .install_method，【不写 install-stamp.json】；
#     hermes_cli.__version__ 只认 stamp（无 stamp 时返回 pyproject 的占位符
#     "0.0.0"）→ Studio 版本显示 0.0.0。官方打包面（Docker/Nix/desktop）都由
#     scripts/write_install_stamp.py 补 stamp，FPK 属同类 packaged 构建，
#     这里对齐：装后补写，base-version 取包内版本锚点。
#
# 自动化原则（用户拍板：跟随上游全链路不得有人工断点）：
#  - 地板与依赖清单都从内核自带 pyproject.toml 的 marker【动态推导】——
#    上游跳 3.15/3.16 或增删依赖时，本脚本【无需修改】即可继续正确把关。
#  - 硬编码 3.14/9 包名单仅作兜底下限，不是判据主体。
#
# 用法: hermes-agent-postinstall.sh <AGENT_ROOT> <APP_DIR> [--expect-version <vX.Y.Z>]
#   AGENT_ROOT: 已装内核目录（含 venv/ 与 scripts/write_install_stamp.py）
#   APP_DIR   : fpk 应用根（读 config/bootstrap/hermes-agent-version.env 锚点）
#   --expect-version: 本包锚点版本。传了它 = 硬门禁模式：强制按锚点重写
#     install-stamp.json，并实测「Studio 版本栏会显示的值」必须等于它，不符即
#     exit 1（调用方回滚）。只有【从内嵌源码铺出来的树】才该传 —— 那是本包的版本。
# 退出码: 0=内核完整且界面版本正确；非 0=残缺/版本显示不对（调用方必须回滚或标失败）
# ============================================================================
set -u

AGENT_ROOT="${1:?用法: $0 <AGENT_ROOT> <APP_DIR> [--expect-version <vX.Y.Z>]}"
APP_DIR="${2:?用法: $0 <AGENT_ROOT> <APP_DIR> [--expect-version <vX.Y.Z>]}"
EXPECT_VERSION=""
shift 2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --expect-version)
            EXPECT_VERSION="${2:-}"
            shift
            [ "$#" -gt 0 ] && shift
            ;;
        *) shift ;;
    esac
done
PY="${AGENT_ROOT}/venv/bin/python"

[ -x "$PY" ] || { echo "ERROR: venv python 不存在: $PY"; exit 1; }

# ---- 1. FPK-DYNFLOOR: 地板 = max(3.14 静态下限, marker 最小值) ---------------
# min 语义与 install.sh FPK-AUTO-FLOOR 一致：核心 marker 恒为同一地板值，
# 面向未来版本的实验依赖（>=3.99 之类）不得推高地板造成误拦。
FLOOR="$("$PY" - "$AGENT_ROOT/pyproject.toml" <<'PYEOF' 2>/dev/null
import re, sys
try:
    txt = open(sys.argv[1], encoding="utf-8").read()
    marks = re.findall(r"python_version\s*>=\s*'(\d+\.\d+)'", txt)
    def key(v):
        a, b = v.split(".")
        return int(a) * 100 + int(b)
    print(min(marks, key=key) if marks else "")
except Exception:
    print("")
PYEOF
)"
# marker 解析不出来时用静态下限；两者取高 —— 地板永不因异常降级
FLOOR_TEST="${FLOOR:-3.14}"
FLOOR_FINAL="$(printf '%s\n%s\n' "3.14" "$FLOOR_TEST" | sort -V | tail -1)"
echo "FPK-DYNFLOOR: marker 推导地板=${FLOOR:-无法解析(用下限)}，实际要求 >= $FLOOR_FINAL"

PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
"$PY" - "$FLOOR_FINAL" <<'PYEOF' 2>/dev/null
import sys
need = tuple(int(x) for x in sys.argv[1].split("."))
raise SystemExit(0 if sys.version_info[:2] >= need else 1)
PYEOF
if [ $? -ne 0 ]; then
    echo "ERROR: venv Python=$PYVER < 要求地板 $FLOOR_FINAL —— marker 依赖必被静默跳过，内核残缺"
    echo "       （若反复如此：检查 install.sh FPK-AUTO-FLOOR 块是否被 re-vendor 抹掉）"
    exit 1
fi
echo "OK: venv Python $PYVER (>= $FLOOR_FINAL)"

# ---- 2. FPK-DYNDEPS: 依赖完整性 = 按 marker 动态推导的直依赖全集 -------------
# 用 importlib.metadata 比对【已安装发行包名】（大小写/下划线规范化），覆盖
# 当前解释器应装的每一个直接依赖 —— 上游新增/改名依赖自动纳入，无需维护
# 硬编码名单。仅严格评估纯 python_version marker；含 sys_platform 等复合
# 条件的跳过（不误报），交由兜底的 import 硬检查覆盖。
# 无法动态解析（老内核无 tomllib 等）→ 退回旧版 9 包 import 检查。
DYN_OUT="$("$PY" - "$AGENT_ROOT/pyproject.toml" <<'PYEOF' 2>/dev/null
import re, sys
try:
    import tomllib
    from importlib.metadata import distributions
except Exception:
    print("PARSE_FAIL"); sys.exit(0)
def vkey(v):
    parts = [int(x) for x in v.split(".")[:2]]
    while len(parts) < 2:
        parts.append(0)
    return tuple(parts)
try:
    with open(sys.argv[1], "rb") as f:
        data = tomllib.load(f)
except Exception:
    print("PARSE_FAIL"); sys.exit(0)
cur = "%d.%d" % sys.version_info[:2]
expected = []
for d in data.get("project", {}).get("dependencies", []):
    if ";" in d:
        spec, marker = d.split(";", 1)
        if re.search(r"sys_platform|platform_system|os_name|implementation", marker):
            continue
        if re.search(r"python_version\s*<=?\s*", marker):
            continue  # 上界形式不评估，保守跳过
        gs = re.findall(r"python_version\s*>=\s*'([\d.]+)'", marker)
        if gs and vkey(cur) < vkey(gs[-1]):
            continue  # 当前解释器本就不该安装它
        name = spec
    else:
        name = d
    m = re.match(r"^([A-Za-z0-9._-]+)", name.strip())
    if m:
        expected.append(m.group(1).lower().replace("_", "-"))
try:
    have = set()
    for dist in distributions():
        n = dist.metadata["Name"]
        if n:
            have.add(n.lower().replace("_", "-"))
except Exception:
    print("PARSE_FAIL"); sys.exit(0)
missing = sorted({e for e in expected if e not in have})
if missing:
    print("MISSING " + " ".join(missing))
else:
    print("COMPLETE %d" % len(set(expected)))
PYEOF
)"
case "$DYN_OUT" in
    COMPLETE*)
        echo "OK: 依赖完整 —— marker 动态推导的全部直依赖在场 ($DYN_OUT)" ;;
    MISSING*)
        echo "ERROR: 核心依赖缺失（marker 静默跳过特征）: ${DYN_OUT#MISSING } —— 拒绝放行"
        exit 1 ;;
    *)
        echo "WARNING: 动态依赖解析不可用（${DYN_OUT:-空}），退回硬编码核心包检查"
        MISSING="$("$PY" - <<'PYEOF' 2>/dev/null
import importlib
cores = ["openai", "httpx", "requests", "rich", "pydantic", "certifi", "dotenv", "jinja2", "cryptography"]
bad = []
for m in cores:
    try:
        importlib.import_module(m)
    except Exception:
        bad.append(m)
print(" ".join(bad))
PYEOF
)"
        if [ -n "${MISSING// /}" ]; then
            echo "ERROR: 核心依赖缺失: $MISSING —— 内核不完整，拒绝放行"
            exit 1
        fi
        echo "OK: 核心依赖完整（fallback 9 包检查通过）" ;;
esac

# ---- 3. install-stamp.json：按本包锚点写/重写 --------------------------------
# 背景：Studio 版本栏读 hermes_cli.__version__，它【只认 install-stamp.json 的
# baseVersion】、不回退 git —— stamp 缺失/损坏时界面显示 0.0.0（用户视角就是
# 「版本显示不对」）。所以装完 fpk 后「界面显示本包版本」只能靠装后实测断言，
# 不能拿安装脚本 exit 0 当证据。
# 传了 --expect-version（= 本包锚点，仅内嵌源码路径会传）即硬门禁模式：
#   · 现有 stamp 与本包锚点不符（例如内嵌源码自带旧 stamp）→ 强制重写；
#   · 写不成 / 写完仍读不出 → 由第 4 步断言判死（调用方回滚）。
# 没传则维持旧的软行为：保护 `hermes update` 写入的带 distance/通道信息的真 stamp。
STAMP="${AGENT_ROOT}/install-stamp.json"
EXPECT_NORM="$(printf '%s' "${EXPECT_VERSION:-}" | tr -d '[:space:]')"
EXPECT_NORM="${EXPECT_NORM#v}"
if [ -n "${EXPECT_NORM}" ] && ! printf '%s' "${EXPECT_NORM}" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "WARNING: --expect-version '${EXPECT_VERSION}' 非语义化版本 —— 本机无法断言界面显示版本，退回软行为"
    EXPECT_NORM=""
fi
HARD=0
[ -n "${EXPECT_NORM}" ] && HARD=1

# ---- 3a. 版本锚点 tag 自愈：让「内核自己重写 stamp」也算得出版本 --------------
# 这一步不是优化，是上面 stamp 能活过装机的唯一前提：
#   · Studio 版本栏读 install-stamp.json 的 baseVersion；
#   · 装机后内核还会自己重写这张 stamp（source_completion / post_update →
#     write_source_stamp），它用 `git tag --merged HEAD --list 'v[0-9]*'` 推
#     base_version；
#   · 打包树是 tarball + git init 的单提交仓库，没有任何可达 tag → 重写成
#     "unknown" → 界面回退 0.0.0（2026-10-21 实测：postinstall 写对 0.22.3，
#     装完 3 分钟被后台 source_completion 洗成 unknown）。
# install_callback 的离线源码路径已按锚点打 tag；这里再兜一次，覆盖「源码树
# 自带旧 .git」「老版本安装路径」等没有走那段的情况。幂等：tag 已在 HEAD 上
# 可达就不动。锚点非语义化（跟踪 main / 日期式 tag）时绝不打 —— 宁可让
# 界面降级占位符，也不谎报一个与内核无关的版本号。
ANCHOR_VER="${EXPECT_NORM}"
if [ -z "${ANCHOR_VER}" ] && [ -f "${APP_DIR}/config/bootstrap/hermes-agent-version.env" ]; then
    ANCHOR_VER="$(grep -E '^HERMES_AGENT_VERSION=' "${APP_DIR}/config/bootstrap/hermes-agent-version.env" 2>/dev/null \
        | head -1 | cut -d= -f2 | tr -d '[:space:]')"
    ANCHOR_VER="${ANCHOR_VER#v}"
fi
if printf '%s' "${ANCHOR_VER}" | grep -qE '^[0-9]{1,3}[.][0-9]{1,3}[.][0-9]{1,3}$' \
   && [ -d "${AGENT_ROOT}/.git" ] && command -v git >/dev/null 2>&1; then
    if git -C "${AGENT_ROOT}" tag --merged HEAD --list "v${ANCHOR_VER}" 2>/dev/null | grep -q .; then
        echo "OK: 版本锚点 tag v${ANCHOR_VER} 已在 HEAD 上可达（内核重写 stamp 不会回退）"
    elif git -C "${AGENT_ROOT}" tag -f "v${ANCHOR_VER}" HEAD >/dev/null 2>&1; then
        echo "OK: 已补版本锚点 tag v${ANCHOR_VER} -> $(git -C "${AGENT_ROOT}" rev-parse --short HEAD 2>/dev/null)"
    else
        echo "WARNING: 补版本锚点 tag v${ANCHOR_VER} 失败（界面可能在装后回退 0.0.0）"
    fi
fi

CURVER="$("$PY" -c 'import hermes_cli; print(hermes_cli.__version__)' 2>/dev/null)"
NEED_WRITE=0
if [ ! -s "$STAMP" ] || [ -z "$CURVER" ] || [ "$CURVER" = "0.0.0" ]; then
    NEED_WRITE=1
elif [ "${HARD}" = "1" ] && [ "$CURVER" != "${EXPECT_NORM}" ]; then
    echo "WARNING: 现有 install-stamp 显示 ${CURVER} != 本包锚点 ${EXPECT_NORM} —— 按锚点重写（界面显示的是 stamp，不是 git）"
    NEED_WRITE=1
else
    echo "OK: install-stamp 已存在且可用 (displayVersion=$CURVER)，跳过补写"
fi

if [ "${NEED_WRITE}" = "1" ]; then
    ANCHOR_ENV="${APP_DIR}/config/bootstrap/hermes-agent-version.env"
    ANCHOR=""
    if [ -f "$ANCHOR_ENV" ]; then
        ANCHOR="$(grep -E '^HERMES_AGENT_VERSION=' "$ANCHOR_ENV" | cut -d= -f2 | tr -d '[:space:]')"
    fi
    # 硬门禁模式下期望值优先（它就是调用方给的锚点）；否则读随包锚点 env。
    BASE="${EXPECT_NORM:-${ANCHOR#v}}"
    STAMP_SCRIPT="${AGENT_ROOT}/scripts/write_install_stamp.py"
    # 锚点非 vX.Y.Z（显式 main 跟踪 / 日期式 tag）时不写：宁可显示占位符，也不写
    # 一个与内核真实版本无关的数字。硬门禁模式下这种树由第 4 步判死。
    if [ -z "$BASE" ] || ! printf '%s' "$BASE" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "WARNING: 无法解析语义化锚定版本（锚点 env='${ANCHOR}'，期望='${EXPECT_NORM}'），跳过 stamp 补写"
    elif [ ! -f "$STAMP_SCRIPT" ]; then
        echo "WARNING: $STAMP_SCRIPT 不存在（内核无此脚本），跳过 stamp 补写"
    else
        (
            cd "$AGENT_ROOT" || exit 1
            "$PY" scripts/write_install_stamp.py \
                --output install-stamp.json \
                --update-mechanism self \
                --base-version "$BASE" \
                --distance 0
        ) || echo "WARNING: write_install_stamp.py 执行失败（版本显示会降级为占位符）"
    fi

    NEWVER="$("$PY" -c 'import hermes_cli; print(hermes_cli.__version__)' 2>/dev/null)"
    if [ "$NEWVER" = "0.0.0" ] || [ -z "$NEWVER" ]; then
        echo "WARNING: stamp 写入后 __version__ 仍为占位符 ($NEWVER) —— stamp 读取链路异常，请人工核对 $STAMP"
    else
        echo "OK: install-stamp 已写入 (displayVersion=$NEWVER, base=$BASE, mechanism=self)"
    fi
fi

# ---- 4. 界面显示版本硬门禁（装完 fpk 后 Studio 版本栏必须显示本包版本）--------
# 判定真源 = ensure-kernel.sh assert-displayed（版本口径只有那一份，本文件不重抄
# 正则/探测命令）。只在硬门禁模式（调用方给了语义化锚点）下断言。
if [ "${HARD}" = "1" ]; then
    ENSURE="${APP_DIR}/config/bootstrap/ensure-kernel.sh"
    if [ ! -f "${ENSURE}" ]; then
        ENSURE="$(cd "$(dirname "$0")" && pwd)/ensure-kernel.sh"
    fi
    if [ ! -f "${ENSURE}" ]; then
        echo "ERROR: 缺 ensure-kernel.sh —— 无法断言界面显示版本（构建门禁本应拦下）"
        exit 1
    fi
    GATE_OUT="$(bash "${ENSURE}" assert-displayed "${AGENT_ROOT}" "${EXPECT_NORM}" 2>&1 || true)"
    printf '%s\n' "${GATE_OUT}" | sed 's/^/    /'
    if [ "$(printf '%s\n' "${GATE_OUT}" | head -1)" != "OK" ]; then
        echo "ERROR: 界面显示版本断言失败（期望 ${EXPECT_NORM}）—— Studio 版本栏会显示错误版本，拒绝放行"
        exit 1
    fi
    echo "OK: 界面显示版本 = ${EXPECT_NORM}（Studio 版本栏将显示此值）"

    # ---- 4b. 自愈版本硬门禁：此刻对 ≠ 装完还对 ------------------------------
    # 第 4 步只证明 install-stamp.json 现在是对的；它证明不了「装机后内核自己
    # 重写这张 stamp 时不把它洗成 unknown」。2026-10-21 事故正是这样：postinstall
    # 写对 0.22.3 并通过了第 4 步，3 分钟后后台 source_completion 用打包树的
    # git（无可达 tag）重写 → baseVersion=unknown → 界面 0.0.0。
    # 这里直接问内核「你自己重写会算出什么」，把回退在装机阶段就拦死。
    # 判定真源 = ensure-kernel.sh assert-rewrite（与 version_info 同口径）。
    RW_OUT="$(bash "${ENSURE}" assert-rewrite "${AGENT_ROOT}" "${EXPECT_NORM}" 2>&1 || true)"
    printf '%s\n' "${RW_OUT}" | sed 's/^/    /'
    if [ "$(printf '%s\n' "${RW_OUT}" | head -1)" = "MISMATCH" ]; then
        echo "ERROR: 内核自愈版本断言失败（期望 ${EXPECT_NORM}）—— 装后 stamp 会被重写成 unknown、界面回退 0.0.0，拒绝放行"
        exit 1
    fi
    echo "OK: 内核自愈版本 = ${EXPECT_NORM}（装后由内核重写 stamp 也保持此值）"
fi
exit 0
