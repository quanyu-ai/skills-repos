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

# 联动：自动渲染 HTML dashboard（失败容忍，不阻塞）
bash "$SCRIPT_DIR/render-dashboard-html.sh" >/dev/null 2>&1 || true
