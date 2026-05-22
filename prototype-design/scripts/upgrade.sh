#!/bin/bash
# upgrade.sh - 风格升级（Phase 1 骨架）
# 用法: bash upgrade.sh <project> <from> <to>
# 例: bash upgrade.sh smart-college wireframe highfi

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 3 ]; then
    echo "用法: bash upgrade.sh <project> <from> <to>"
    echo "  <from>/<to>: wireframe / highfi / interactive"
    exit 2
fi

PROJECT="$1"
FROM="$2"
TO="$3"

case "$FROM" in
    wireframe|highfi|interactive) ;;
    *) echo "ERROR: <from> 必须是 wireframe / highfi / interactive"; exit 2 ;;
esac
case "$TO" in
    wireframe|highfi|interactive) ;;
    *) echo "ERROR: <to> 必须是 wireframe / highfi / interactive"; exit 2 ;;
esac

PROTOTYPE_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"
[ -d "$PROTOTYPE_DIR" ] || { echo "ERROR: 原型目录不存在: $PROTOTYPE_DIR"; exit 1; }

echo "[upgrade] 项目: $PROJECT, $FROM → $TO"
echo ""
echo "⚠️  Phase 1 骨架占位 - 仅打印将要执行的动作："
echo "  1. 把当前 $FROM 版本完整归档到 meta/archive/$(date +%Y-%m-%dT%H-%M)-$FROM/"
echo "  2. 用 templates/$TO/base.html 重生成所有模块"
echo "  3. 切换 _shared/styles.css 为 $TO 风格"
echo "  4. 更新 meta/requirements-map.json 的 style 字段"
echo "  5. 写一条 revisions.md 升级记录"
echo ""
echo "完整实现请等 Phase 3/4"

exit 0
