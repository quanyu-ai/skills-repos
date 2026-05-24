#!/bin/bash
# post-dispatch-verify.sh - 子Agent完成后验证产出真实性
# Usage: bash post-dispatch-verify.sh <TASK-ID>
#
# 验证内容：
#   1. TASK-TRACKER.json 状态是否为 completed
#   2. 提交的文件路径/行数/大小
#   3. commit hash / push 状态
#   4. 输出验证报告

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

TASK_ID="${1:-}"
[ -z "$TASK_ID" ] && { echo "用法: $0 <TASK-ID>" >&2; exit 1; }

TRACKER="$WORKSPACE_ROOT/knowledge-repos/management/TASK-TRACKER.json"

echo "═══════════════════════════════════════"
echo "  派发后验证: $TASK_ID"
echo "═══════════════════════════════════════"

# 1. 检查 TASK-TRACKER 状态
echo "[1/4] TASK-TRACKER 状态..."
if [ ! -f "$TRACKER" ]; then
    echo -e "  ${RED}❌ FAIL${NC}  T