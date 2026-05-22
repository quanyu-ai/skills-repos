#!/bin/bash
# archive.sh - 归档当前需求快照到 _archive/<version>-YYYYMMDD/
# Usage: bash archive.sh <project> <version> [--source-doc <docx-path>]
#
# 动作:
#   1. 创建 docs-repos/<project>/requirements/_archive/<version>-YYYYMMDD/
#   2. 复制当前所有 REQ-*.md 到归档目录
#   3. 复制 requirements-map.json / INDEX.md 到归档目录
#   4. 如果传了 --source-doc，把原始 docx 也复制进去
#   5. 在 CHANGELOG.md 顶部 prepend 一条 "## <version> (YYYY-MM-DD)" 记录
#   6. 输出归档摘要（条目数、文件大小）

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

usage() {
    cat >&2 <<EOF
Usage: $0 <project> <version> [--source-doc <docx-path>]

Examples:
  $0 smart-college v3.0
  $0 smart-college v3.0 --source-doc docs-repos/smart-college/requirements/原始需求.docx
EOF
    exit 1
}

[ $# -lt 2 ] && usage

PROJECT="$1"
VERSION="$2"
shift 2

SOURCE_DOC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source-doc) SOURCE_DOC="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found" >&2; exit 2; }

DATE_TAG="$(date +%Y%m%d)"
DATE_HUMAN="$(date +%Y-%m-%d)"
ARCHIVE_NAME="${VERSION}-${DATE_TAG}"
ARCHIVE_DIR="$REQ_DIR/_archive/$ARCHIVE_NAME"

if [ -d "$ARCHIVE_DIR" ]; then
    echo "[archive] 目录已存在，覆盖归档: $ARCHIVE_DIR"
    rm -rf "$ARCHIVE_DIR"
fi
mkdir -p "$ARCHIVE_DIR"

# 1. 拷贝 REQ-*.md
REQ_COUNT=0
shopt -s nullglob
for f in "$REQ_DIR"/REQ-*.md; do
    cp "$f" "$ARCHIVE_DIR/"
    REQ_COUNT=$((REQ_COUNT+1))
done
shopt -u nullglob

# 2. 拷贝 map / index
[ -f "$REQ_DIR/requirements-map.json" ] && cp "$REQ_DIR/requirements-map.json" "$ARCHIVE_DIR/"
[ -f "$REQ_DIR/INDEX.md" ] && cp "$REQ_DIR/INDEX.md" "$ARCHIVE_DIR/"

# 3. 拷贝原始文档
if [ -n "$SOURCE_DOC" ]; then
    if [ -f "$SOURCE_DOC" ]; then
        cp "$SOURCE_DOC" "$ARCHIVE_DIR/"
        echo "[archive] 已拷贝原始文档: $(basename "$SOURCE_DOC")"
    else
        echo "WARN: --source-doc 文件不存在: $SOURCE_DOC" >&2
    fi
fi

# 4. CHANGELOG.md prepend
CHANGELOG="$REQ_DIR/CHANGELOG.md"
TMP_LOG="$(mktemp)"

SOURCE_LINE=""
if [ -n "$SOURCE_DOC" ]; then
    SOURCE_LINE="- 原始文档: \`$(basename "$SOURCE_DOC")\`"
fi

NEW_ENTRY="## ${VERSION} (${DATE_HUMAN})

- 归档目录: \`_archive/${ARCHIVE_NAME}/\`
- 条目数: ${REQ_COUNT}
${SOURCE_LINE}

"

if [ -f "$CHANGELOG" ]; then
    {
        # 先保留首行标题（如果有 # 开头）
        head -1 "$CHANGELOG" > "$TMP_LOG"
        FIRST_LINE="$(head -1 "$CHANGELOG")"
        if [[ "$FIRST_LINE" == \#* ]]; then
            echo "" >> "$TMP_LOG"
            echo "$NEW_ENTRY" >> "$TMP_LOG"
            tail -n +2 "$CHANGELOG" >> "$TMP_LOG"
        else
            : > "$TMP_LOG"
            echo "$NEW_ENTRY" >> "$TMP_LOG"
            cat "$CHANGELOG" >> "$TMP_LOG"
        fi
    }
    mv "$TMP_LOG" "$CHANGELOG"
else
    cat > "$CHANGELOG" <<EOF
# 需求变更日志 - $PROJECT

$NEW_ENTRY
EOF
fi

# 5. 摘要
SIZE="$(du -sh "$ARCHIVE_DIR" | awk '{print $1}')"
FILE_COUNT="$(find "$ARCHIVE_DIR" -type f | wc -l | tr -d ' ')"

echo ""
echo "═════════════════════════════════════"
echo "  归档完成: $PROJECT / $VERSION"
echo "═════════════════════════════════════"
echo "  归档目录: $ARCHIVE_DIR"
echo "  REQ 条目: $REQ_COUNT"
echo "  总文件数: $FILE_COUNT"
echo "  总大小:   $SIZE"
echo "  CHANGELOG: $CHANGELOG"
echo "═════════════════════════════════════"
