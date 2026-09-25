#!/usr/bin/env bash
# 校验 fpk 内容：外层结构 + 内层 app.tgz（双层，缺一不可）
#
# 用法:
#   verify-fpk-content.sh <file.fpk> [forbidden_regex ...]
#
# 默认禁查正则: '^(app/)?skills/'
# 设计依据：fpk 是双层 tar.gz，`tar tzf x.fpk | grep` 只看得到外层条目，
# 内层 app.tgz 里的内容必须解开再查，否则会得到假的"校验通过"。
set -uo pipefail

FPK="${1:?用法: $0 <file.fpk> [forbidden_regex ...]}"
shift || true
FORBIDDEN=("$@")
[ ${#FORBIDDEN[@]} -eq 0 ] && FORBIDDEN=('^(app/)?skills/')

[ -f "$FPK" ] || { echo "❌ 找不到 $FPK"; exit 1; }

FAIL=0

echo "=== 文件 ==="
ls -la "$FPK"

OUTER="$(tar tzf "$FPK")" || { echo "❌ 外层归档不可解"; exit 1; }
echo "=== 外层条目 ==="
echo "$OUTER"

for need in '^manifest$' '^manifest\.checksum$' '^cmd/' '^wizard/' '^app\.tgz$'; do
    echo "$OUTER" | grep -qE "$need" || { echo "❌ 外层缺必要条目: $need"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] && echo "✅ 外层结构完整"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar xzf "$FPK" -C "$TMP" app.tgz || { echo "❌ 解内层 app.tgz 失败"; exit 1; }
[ -s "$TMP/app.tgz" ] || { echo "❌ app.tgz 缺失或为空"; exit 1; }

INNER="$(tar tzf "$TMP/app.tgz")"
echo "=== 内层顶层目录 ==="
echo "$INNER" | grep -E '^[^/]+/$'
echo "内层条目数: $(echo "$INNER" | wc -l)"

for pat in "${FORBIDDEN[@]}"; do
    if echo "$INNER" | grep -qE "$pat"; then
        echo "❌ 内层命中禁查内容 /$pat/："
        echo "$INNER" | grep -E "$pat" | head -10
        FAIL=1
    else
        echo "✅ 内层未命中 /$pat/"
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "✅ 校验通过"
else
    echo "❌ 校验失败"
    exit 1
fi
