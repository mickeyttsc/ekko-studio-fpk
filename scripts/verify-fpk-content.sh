#!/usr/bin/env bash
# 校验 fpk 内容：外层结构 + 内层 app.tgz（双层，缺一不可）
#
# 用法:
#   verify-fpk-content.sh <file.fpk> [forbidden_regex ...]
#
# 默认禁查正则: '^(app/)?skills/'
# 设计依据：fpk 是双层 tar.gz，`tar tzf x.fpk | grep` 只看得到外层条目，
# 内层 app.tgz 里的内容必须解开再查，否则会得到假的"校验通过"。
#
# ⛔ 不要把清单塞进变量再 `echo "$LIST" | grep ...`：
#    内层有 3 万多行（400KB+），`grep -q` 命中即早退 → echo 收 SIGPIPE(141)。
#    在 pipefail 下这会让 `if echo "$L" | grep -q X` 判成「未命中」，
#    **安全检查静默失效**（假阴性，实测复现）。一律写文件再 grep。
set -uo pipefail

FPK="${1:?用法: $0 <file.fpk> [forbidden_regex ...]}"
shift || true
FORBIDDEN=("$@")
[ ${#FORBIDDEN[@]} -eq 0 ] && FORBIDDEN=('^(app/)?skills/')

[ -f "$FPK" ] || { echo "❌ 找不到 $FPK"; exit 1; }

FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 文件 ==="
ls -la "$FPK"

tar tzf "$FPK" > "$TMP/outer.list" 2>/dev/null || { echo "❌ 外层归档不可解"; exit 1; }
echo "=== 外层条目 ==="
cat "$TMP/outer.list"

for need in '^manifest$' '^manifest\.checksum$' '^cmd/' '^config/' '^wizard/' '^app\.tgz$'; do
    grep -qE "$need" "$TMP/outer.list" || { echo "❌ 外层缺必要条目: $need"; FAIL=1; }
done
[ "$FAIL" -eq 0 ] && echo "✅ 外层结构完整"

tar xzf "$FPK" -C "$TMP" app.tgz || { echo "❌ 解内层 app.tgz 失败"; exit 1; }
[ -s "$TMP/app.tgz" ] || { echo "❌ app.tgz 缺失或为空"; exit 1; }

tar tzf "$TMP/app.tgz" > "$TMP/inner.list"
echo "=== 内层顶层目录 ==="
grep -E '^[^/]+/$' "$TMP/inner.list"
echo "内层条目数: $(wc -l < "$TMP/inner.list")"

for pat in "${FORBIDDEN[@]}"; do
    if grep -qE "$pat" "$TMP/inner.list"; then
        echo "❌ 内层命中禁查内容 /$pat/："
        grep -E "$pat" "$TMP/inner.list" | head -10
        FAIL=1
    else
        echo "✅ 内层未命中 /$pat/"
    fi
done

# 反自检：确认 grep 通路是活的（防止有人改回管道写法导致假阴性）
if ! grep -qE '^config/privilege$' "$TMP/inner.list"; then
    echo "❌ 门禁自检失败：内层应含 config/privilege 却匹配不到，检查逻辑已失效"
    FAIL=1
else
    echo "✅ 门禁自检通过（grep 通路正常）"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "✅ 校验通过"
else
    echo "❌ 校验失败"
    exit 1
fi
