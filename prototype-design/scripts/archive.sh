#!/bin/bash
# archive.sh - 归档当前原型快照到 _archive/<version>-YYYYMMDD/
# Usage: bash archive.sh <project> <version>
#
# 动作:
#   1. 创建 docs-repos/<project>/prototype/_archive/<version>-YYYYMMDD/
#   2. 复制 _shared/ / modules/ / meta/ / index.html 全部内容到归档目录
#   3. 在 meta/revisions.md 顶部 prepend "## <version> (YYYY-MM-DD)" 记录
#   4. 输出归档摘要

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 2 ] && { echo "Usage: $0 <project> <version>" >&2; exit 1; }

PROJECT="$1"
VERSION="$2"

PROTO_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"
[ -d "$PROTO_DIR" ] || { echo "ERROR: $PROTO_DIR not found" >&2; exit 2; }

DATE_TAG="$(date +%Y%m%d)"
DATE_HUMAN="$(date +%Y-%m-%d)"
ARCHIVE_NAME="${VERSION}-${DATE_TAG}"
ARCHIVE_DIR="$PROTO_DIR/_archive/$ARCHIVE_NAME"

if [ -d "$ARCHIVE_DIR" ]; then
    echo "[archive] 目录已存在，覆盖归档: $ARCHIVE_DIR"
    rm -rf "$ARCHIVE_DIR"
fi
mkdir -p "$ARCHIVE_DIR"

# 拷贝标准目录与 index.html（存在即拷）
for item in _shared modules meta index.html; do
    src="$PROTO_DIR/$item"
    if [ -e "$src" ]; then
        cp -r "$src" "$ARCHIVE_DIR/"
    fi
done

# revisions.md prepend
REVISIONS="$PROTO_DIR/meta/revisions.md"
mkdir -p "$PROTO_DIR/meta"
TMP_LOG="$(mktemp)"

FILE_COUNT="$(find "$ARCHIVE_DIR" -type f | wc -l | tr -d ' ')"
SIZE="$(du -sh "$ARCHIVE_DIR" | awk '{print $1}')"

NEW_ENTRY="## ${VERSION} (${DATE_HUMAN})

- 归档目录: \`_archive/${ARCHIVE_NAME}/\`
- 文件数: ${FILE_COUNT}
- 总大小: ${SIZE}

"

if [ -f "$REVISIONS" ]; then
    FIRST_LINE="$(head -1 "$REVISIONS")"
    if [[ "$FIRST_LINE" == \#* ]]; then
        {
            echo "$FIRST_LINE"
            echo ""
            echo "$NEW_ENTRY"
            tail -n +2 "$REVISIONS"
        } > "$TMP_LOG"
    else
        {
            echo "$NEW_ENTRY"
            cat "$REVISIONS"
        } > "$TMP_LOG"
    fi
    mv "$TMP_LOG" "$REVISIONS"
else
    cat > "$REVISIONS" <<EOF
# 原型版本记录 - $PROJECT

$NEW_ENTRY
EOF
fi

echo ""
echo "═════════════════════════════════════"
echo "  原型归档完成: $PROJECT / $VERSION"
echo "═════════════════════════════════════"
echo "  归档目录: $ARCHIVE_DIR"
echo "  文件数: $FILE_COUNT"
echo "  总大小: $SIZE"
echo "  revisions: $REVISIONS"
echo "═════════════════════════════════════"
