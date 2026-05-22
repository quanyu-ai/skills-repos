#!/bin/bash
# diff-version.sh - 比较两个版本的 REQ 差异
# Usage: bash diff-version.sh <project> <v1> <v2>
#
# v1/v2 可以是:
#   - 完整归档目录名: v3.0-20260522
#   - 仅版本号: v3.0 (会自动匹配 _archive/ 下以该版本开头的目录)
#   - "current" 表示当前 requirements/ 工作目录

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 3 ] && { echo "Usage: $0 <project> <v1> <v2>" >&2; exit 1; }

PROJECT="$1"
V1="$2"
V2="$3"

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
ARCHIVE_ROOT="$REQ_DIR/_archive"

resolve_version_dir() {
    local v="$1"
    if [ "$v" = "current" ]; then
        echo "$REQ_DIR"
        return
    fi
    # 完全匹配
    if [ -d "$ARCHIVE_ROOT/$v" ]; then
        echo "$ARCHIVE_ROOT/$v"
        return
    fi
    # 模糊匹配 (按版本号开头)
    local match
    match="$(ls -d "$ARCHIVE_ROOT/$v"-* 2>/dev/null | head -1)"
    if [ -n "$match" ]; then
        echo "$match"
        return
    fi
    echo "ERROR: 找不到版本: $v (在 $ARCHIVE_ROOT/ 下)" >&2
    exit 2
}

DIR1="$(resolve_version_dir "$V1")"
DIR2="$(resolve_version_dir "$V2")"

echo "═════════════════════════════════════"
echo "  版本对比: $PROJECT"
echo "═════════════════════════════════════"
echo "  V1: $DIR1"
echo "  V2: $DIR2"
echo "═════════════════════════════════════"

# 列出两边的 REQ 文件
list_reqs() {
    local dir="$1"
    (cd "$dir" && ls REQ-*.md 2>/dev/null | sort)
}

LIST1="$(list_reqs "$DIR1")"
LIST2="$(list_reqs "$DIR2")"

ADDED="$(comm -13 <(echo "$LIST1") <(echo "$LIST2"))"
REMOVED="$(comm -23 <(echo "$LIST1") <(echo "$LIST2"))"
COMMON="$(comm -12 <(echo "$LIST1") <(echo "$LIST2"))"

echo ""
echo "── 新增 (V2 中有, V1 中无) ──"
if [ -n "$ADDED" ]; then
    echo "$ADDED" | sed 's/^/  + /'
else
    echo "  (无)"
fi

echo ""
echo "── 删除 (V1 中有, V2 中无) ──"
if [ -n "$REMOVED" ]; then
    echo "$REMOVED" | sed 's/^/  - /'
else
    echo "  (无)"
fi

echo ""
echo "── 修改 (两版都有但内容不同) ──"
MODIFIED_COUNT=0
MODIFIED_LIST=""
for f in $COMMON; do
    if ! diff -q "$DIR1/$f" "$DIR2/$f" >/dev/null 2>&1; then
        MODIFIED_LIST="${MODIFIED_LIST}${f}\n"
        MODIFIED_COUNT=$((MODIFIED_COUNT+1))
    fi
done
if [ "$MODIFIED_COUNT" -gt 0 ]; then
    echo -e "$MODIFIED_LIST" | sed '/^$/d' | sed 's/^/  ~ /'
    echo ""
    echo "── 修改详情 (diff -u) ──"
    for f in $(echo -e "$MODIFIED_LIST" | sed '/^$/d'); do
        echo ""
        echo "▶ $f"
        diff -u "$DIR1/$f" "$DIR2/$f" | head -80 || true
    done
else
    echo "  (无)"
fi

echo ""
echo "═════════════════════════════════════"
echo "  汇总: +$(echo "$ADDED" | grep -c . || echo 0) / -$(echo "$REMOVED" | grep -c . || echo 0) / ~${MODIFIED_COUNT}"
echo "═════════════════════════════════════"
