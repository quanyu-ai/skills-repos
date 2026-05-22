#!/bin/bash
# diff-version.sh - 比较两个版本的原型差异
# Usage: bash diff-version.sh <project> <v1> <v2>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 3 ] && { echo "Usage: $0 <project> <v1> <v2>" >&2; exit 1; }

PROJECT="$1"
V1="$2"
V2="$3"

PROTO_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"
ARCHIVE_ROOT="$PROTO_DIR/_archive"

resolve_version_dir() {
    local v="$1"
    if [ "$v" = "current" ]; then
        echo "$PROTO_DIR"
        return
    fi
    if [ -d "$ARCHIVE_ROOT/$v" ]; then
        echo "$ARCHIVE_ROOT/$v"
        return
    fi
    local match
    match="$(ls -d "$ARCHIVE_ROOT/$v"-* 2>/dev/null | head -1)"
    if [ -n "$match" ]; then
        echo "$match"
        return
    fi
    echo "ERROR: 找不到原型版本: $v" >&2
    exit 2
}

DIR1="$(resolve_version_dir "$V1")"
DIR2="$(resolve_version_dir "$V2")"

echo "═════════════════════════════════════"
echo "  原型版本对比: $PROJECT"
echo "═════════════════════════════════════"
echo "  V1: $DIR1"
echo "  V2: $DIR2"
echo "═════════════════════════════════════"

# 列出所有 .html 相对路径（排除归档目录嵌套）
list_html() {
    local dir="$1"
    (cd "$dir" && find . -name "*.html" -not -path "./_archive/*" 2>/dev/null | sed 's|^./||' | sort)
}

LIST1="$(list_html "$DIR1")"
LIST2="$(list_html "$DIR2")"

ADDED="$(comm -13 <(echo "$LIST1") <(echo "$LIST2"))"
REMOVED="$(comm -23 <(echo "$LIST1") <(echo "$LIST2"))"
COMMON="$(comm -12 <(echo "$LIST1") <(echo "$LIST2"))"

echo ""
echo "── 新增 ──"
[ -n "$ADDED" ] && echo "$ADDED" | sed 's/^/  + /' || echo "  (无)"

echo ""
echo "── 删除 ──"
[ -n "$REMOVED" ] && echo "$REMOVED" | sed 's/^/  - /' || echo "  (无)"

echo ""
echo "── 修改 ──"
MOD_COUNT=0
MOD_LIST=""
for f in $COMMON; do
    if ! diff -q "$DIR1/$f" "$DIR2/$f" >/dev/null 2>&1; then
        L1=$(wc -l < "$DIR1/$f" | tr -d ' ')
        L2=$(wc -l < "$DIR2/$f" | tr -d ' ')
        DELTA=$((L2-L1))
        SIGN="+"; [ $DELTA -lt 0 ] && SIGN=""
        MOD_LIST="${MOD_LIST}${f} (${L1}→${L2}行, Δ${SIGN}${DELTA})\n"
        MOD_COUNT=$((MOD_COUNT+1))
    fi
done
if [ "$MOD_COUNT" -gt 0 ]; then
    echo -e "$MOD_LIST" | sed '/^$/d' | sed 's/^/  ~ /'
    echo ""
    echo "── 修改详情 ──"
    for f in $COMMON; do
        if ! diff -q "$DIR1/$f" "$DIR2/$f" >/dev/null 2>&1; then
            L1=$(wc -l < "$DIR1/$f" | tr -d ' ')
            L2=$(wc -l < "$DIR2/$f" | tr -d ' ')
            echo ""
            echo "▶ $f"
            if [ $L1 -gt 500 ] || [ $L2 -gt 500 ]; then
                echo "  (大文件, 仅显示行数变化: $L1 → $L2)"
            else
                diff -u "$DIR1/$f" "$DIR2/$f" | head -60 || true
            fi
        fi
    done
else
    echo "  (无)"
fi

echo ""
echo "═════════════════════════════════════"
echo "  汇总: +$(echo "$ADDED" | grep -c . || echo 0) / -$(echo "$REMOVED" | grep -c . || echo 0) / ~${MOD_COUNT}"
echo "═════════════════════════════════════"
