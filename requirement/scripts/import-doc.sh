#!/bin/bash
# import-doc.sh - 从 docx 解析需求文档（Phase 1: 仅解析输出大纲，不自动拆分）
# Usage: import-doc.sh <project> <docx_path> [--auto-split]

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 2 ] && { echo "Usage: $0 <project> <docx_path> [--auto-split]"; exit 1; }

PROJECT="$1"
DOCX="$2"
AUTO_SPLIT=0
if [ "${3:-}" = "--auto-split" ]; then
    AUTO_SPLIT=1
fi

[ -f "$DOCX" ] || { echo "ERROR: $DOCX not found"; exit 2; }
command -v pandoc >/dev/null 2>&1 || { echo "ERROR: pandoc not installed"; exit 2; }

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
mkdir -p "$REQ_DIR"

CACHE_DIR="$REQ_DIR/.import-cache"
mkdir -p "$CACHE_DIR"

BASENAME=$(basename "$DOCX" .docx)
MD_OUT="$CACHE_DIR/${BASENAME}.md"

echo "▶ Parsing docx → markdown ..."
pandoc -f docx -t markdown "$DOCX" -o "$MD_OUT"
echo "  ✓ saved to: ${MD_OUT#$WORKSPACE_ROOT/}"
echo ""

echo "▶ 章节大纲（headers）："
echo ""
grep -nE "^#+|^={3,}$|^-{3,}$" "$MD_OUT" | head -100
echo ""

if [ "$AUTO_SPLIT" -eq 1 ]; then
    echo "▶ --auto-split 模式：Phase 1 尚未实现自动拆分逻辑"
    echo "  推荐工作流："
    echo "    1. 人工/Agent 阅读上面的大纲与原 docx"
    echo "    2. 用 new-req.sh 逐条创建 REQ-*.md"
    echo "    3. 跑 sync-map.sh 重建索引"
    exit 0
fi

echo "▶ 接下来你可以："
echo "    1. cat ${MD_OUT#$WORKSPACE_ROOT/}    # 查看完整 markdown"
echo "    2. 用 new-req.sh 按章节逐条创建 REQ"
echo "    3. 跑 sync-map.sh 重建索引"
