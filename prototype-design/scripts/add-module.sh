#!/bin/bash
# add-module.sh - 增量加新模块（Phase 1 骨架）
# 用法: bash add-module.sh <project> <module-name>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "用法: bash add-module.sh <project> <module-name>"
    exit 2
fi

PROJECT="$1"
MODULE="$2"
PROTOTYPE_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"

[ -d "$PROTOTYPE_DIR" ] || { echo "ERROR: 原型目录不存在: $PROTOTYPE_DIR"; exit 1; }

echo "[add-module] 项目: $PROJECT, 模块: $MODULE"
echo ""
echo "⚠️  Phase 1 骨架占位 - 仅打印将要执行的动作："
echo "  1. 在 modules/<推断角色>/$MODULE.html 创建新文件"
echo "  2. 复制 templates/wireframe/base.html 作为骨架"
echo "  3. 更新 meta/requirements-map.json 追加 mapping"
echo "  4. 写一条 revisions.md 变更记录"
echo ""
echo "完整实现请等 Phase 2"

exit 0
