#!/bin/bash
# ============================================================================
# FPK 装后内核完整性校验 + install-stamp 补写（2026-10-14 根因固化）
#
# 背景（两条都是本机实测/技术简报核实过的坑）：
#  1. hermes-agent v0.21.7/v0.22.0 的 pyproject 把全部核心依赖 gate 在
#     `python_version >= '3.14'` marker 上。若 venv 落在 <3.14（历史默认 3.11），
#     openai/httpx/requests/pydantic 等被【静默跳过】——安装显示成功，内核却是
#     残缺的。install.sh 本身不检查这个不变式，必须在装后硬性验收。
#  2. 上游 install.sh 完成后只写 .install_method，【不写 install-stamp.json】；
#     hermes_cli.__version__ 只认 stamp（无 stamp 时返回 pyproject 的占位符
#     "0.0.0"）→ Studio 版本显示 0.0.0。官方打包面（Docker/Nix/desktop）都由
#     scripts/write_install_stamp.py 补 stamp，FPK 属同类 packaged 构建，
#     这里对齐：装后补写，base-version 取包内版本锚点。
#
# 用法: hermes-agent-postinstall.sh <AGENT_ROOT> <APP_DIR>
#   AGENT_ROOT: 已装内核目录（含 venv/ 与 scripts/write_install_stamp.py）
#   APP_DIR   : fpk 应用根（读 config/bootstrap/hermes-agent-version.env 锚点）
# 退出码: 0=内核完整；非 0=残缺（调用方必须标 install failed，禁止静默放行）
# ============================================================================
set -u

AGENT_ROOT="${1:?用法: $0 <AGENT_ROOT> <APP_DIR>}"
APP_DIR="${2:?用法: $0 <AGENT_ROOT> <APP_DIR>}"
PY="${AGENT_ROOT}/venv/bin/python"

[ -x "$PY" ] || { echo "ERROR: venv python 不存在: $PY"; exit 1; }

# ---- 1. Python 地板校验：venv 必须 >= 3.14 ---------------------------------
PYVER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
"$PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 14) else 1)' 2>/dev/null || {
    echo "ERROR: venv Python=$PYVER < 3.14 —— marker 依赖必被静默跳过，内核残缺"
    echo "       （若反复如此：检查 install.sh 的 PYTHON_VERSION 是否被改回旧值）"
    exit 1
}
echo "OK: venv Python $PYVER (>= 3.14)"

# ---- 2. 核心依赖完整性校验 --------------------------------------------------
# 这些全部是 pyproject 里带 python_version >= '3.14' marker 的直依赖，
# 任一缺失 = marker 曾被跳过 = 残缺内核。报错要具体到模块名，方便定位。
MISSING="$("$PY" - <<'PYEOF' 2>/dev/null
import importlib, sys
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
    echo "ERROR: 核心依赖缺失: $MISSING —— 内核不完整（marker 静默跳过特征），拒绝放行"
    exit 1
fi
echo "OK: 核心依赖完整 (openai/httpx/requests/rich/pydantic/...)"

# ---- 3. install-stamp.json 补写 ----------------------------------------------
# 已有可用 stamp（__version__ 非占位符）就不动 —— 保护存量装机经 `hermes update`
# 写入的带 distance/通道信息的真 stamp，只有缺失或 0.0.0 才补。
STAMP="${AGENT_ROOT}/install-stamp.json"
CURVER="$("$PY" -c 'import hermes_cli; print(hermes_cli.__version__)' 2>/dev/null)"
if [ -s "$STAMP" ] && [ -n "$CURVER" ] && [ "$CURVER" != "0.0.0" ]; then
    echo "OK: install-stamp 已存在且可用 (displayVersion=$CURVER)，跳过补写"
    exit 0
fi

ANCHOR_ENV="${APP_DIR}/config/bootstrap/hermes-agent-version.env"
ANCHOR=""
if [ -f "$ANCHOR_ENV" ]; then
    ANCHOR="$(grep -E '^HERMES_AGENT_VERSION=' "$ANCHOR_ENV" | cut -d= -f2 | tr -d '[:space:]')"
fi
BASE="${ANCHOR#v}"
STAMP_SCRIPT="${AGENT_ROOT}/scripts/write_install_stamp.py"
if [ -z "$BASE" ] || [ "$BASE" = "$ANCHOR" ]; then
    # 锚点缺失或无 v 前缀语义（防御：锚点应是 vX.Y.Z）
    echo "WARNING: 无法从 $ANCHOR_ENV 解析锚定版本（got='${ANCHOR}'），跳过 stamp 补写"
    echo "         （Studio 将显示占位符版本，直至下一次 hermes update）"
    exit 0
fi
if [ ! -f "$STAMP_SCRIPT" ]; then
    echo "WARNING: $STAMP_SCRIPT 不存在（内核 <0.19 无此脚本？），跳过 stamp 补写"
    exit 0
fi

(
    cd "$AGENT_ROOT" || exit 1
    "$PY" scripts/write_install_stamp.py \
        --output install-stamp.json \
        --update-mechanism self \
        --base-version "$BASE" \
        --distance 0
) || {
    echo "WARNING: write_install_stamp.py 执行失败（不阻断安装：版本显示降级为占位符，功能不受损）"
    exit 0
}

NEWVER="$("$PY" -c 'import hermes_cli; print(hermes_cli.__version__)' 2>/dev/null)"
if [ "$NEWVER" = "0.0.0" ] || [ -z "$NEWVER" ]; then
    echo "WARNING: stamp 已写入但 __version__ 仍为占位符 ($NEWVER) —— stamp 读取链路异常，请人工核对 $STAMP"
    exit 0
fi
echo "OK: install-stamp 已补写 (displayVersion=$NEWVER, base=$BASE, mechanism=self)"
exit 0
