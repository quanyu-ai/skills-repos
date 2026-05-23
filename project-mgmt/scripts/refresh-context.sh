#!/bin/bash
# refresh-context.sh - 重新生成 knowledge-repos/management/PROJECTS-CONTEXT.md
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

OUT="$WORKSPACE_ROOT/knowledge-repos/management/PROJECTS-CONTEXT.md"
TMP=$(mktemp)
bash "$SCRIPT_DIR/render-projects-context.sh" > "$TMP"
mv "$TMP" "$OUT"
LINES=$(wc -l < "$OUT")
echo "✓ 已刷新 $OUT（$LINES 行）"
