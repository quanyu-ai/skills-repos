#!/bin/bash
# revise-module.sh - 修改已有模块（Phase 1 骨架）
# 用法: bash revise-module.sh <project> <module-name> <file>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 3 ]; then
    echo "用法: bash revise-module.sh <project> <module-name> <file>"
    exit 2
fi

PROJECT="$1"
MODULE="$2"
FILE="$3"
PROTOTYPE_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"

[ -d "$PROTOTYPE_DIR" ] || { echo "ERROR: 原型目录不存在: $PROTOTYPE_DIR"; exit 1; }

echo "[revise-module] 项目: $PROJECT, 模块: $MODULE, 文件: $FILE"
echo ""
echo "⚠️  Phase 1 骨架占位 - 仅打印将要执行的动作："
echo "  1. 把 $FILE 归档到 meta/archive/$(date +%Y-%m-%dT%H-%M)/"
echo "  2. 根据 $MODULE 关联的 REQ 重新生成 $FILE"
echo "  3. 更新 meta/requirements-map.json（更新 generated_at）"
echo "  4. 写一条 revisions.md 变更记录（含变更原因占位）"
echo ""
echo "完整实现请等 Phase 2"

exit 0
