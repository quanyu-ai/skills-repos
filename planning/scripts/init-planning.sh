#!/bin/bash
# init-planning.sh - 项目首次建 planning/ 目录 + 三件套骨架
# Usage: init-planning.sh <project-id> [--migrate]
#   --migrate  历史项目首次接入，frontmatter 标 legacy: true

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DOCS_ROOT="$WORKSPACE_ROOT/docs-repos"
PROJ_ROOT="$DOCS_ROOT/$1"
PLANNING_DIR="$PROJ_ROOT/planning"
TEMPLATES="$SKILL_DIR/templates"

usage() {
    cat >&2 <<EOF
Usage: $0 <project-id> [--migrate]

Options:
  --migrate    历史项目首次接入，frontmatter 标 legacy: true

Example:
  $0 smartops
  $0 smartops --migrate
EOF
    exit 1
}

[ -z "$1" ] && usage

PROJECT_ID="$1"
MIGRATE=false
[ "$2" = "--migrate" ] && MIGRATE=true

# 校验项目目录存在
if [ ! -d "$PROJ_ROOT" ]; then
    echo "❌ 错误：docs-repos/$PROJECT_ID/ 不存在，请检查 project-id 是否正确" >&2
    exit 1
fi

# 校验 jq
if ! command -v jq &>/dev/null; then
    echo "❌ 错误：需要 jq，请先安装" >&2
    exit 1
fi

# 创建 planning 目录
mkdir -p "$PLANNING_DIR/_archive"

# 日期
TODAY=$(TZ=Asia/Shanghai date +%Y-%m-%d)
DATETIME=$(TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S+08:00)

LEGACY_FLAG="false"
if $MIGRATE; then
    LEGACY_FLAG="true"
fi

# 生成 PRD.md
if [ ! -f "$PLANNING_DIR/PRD.md" ]; then
    sed -e "s/<project-id>/$PROJECT_ID/g" \
        -e "s/<YYYY-MM-DD>/$TODAY/g" \
        -e "s/legacy: false/legacy: $LEGACY_FLAG/g" \
        "$TEMPLATES/PRD.template.md" > "$PLANNING_DIR/PRD.md"
    echo "✅ 创建 $PLANNING_DIR/PRD.md"
else
    echo "⚠️  已存在 $PLANNING_DIR/PRD.md，跳过"
fi

# 生成 ROADMAP.md
if [ ! -f "$PLANNING_DIR/ROADMAP.md" ]; then
    sed -e "s/<project-id>/$PROJECT_ID/g" \
        -e "s/<YYYY-MM-DD>/$TODAY/g" \
        -e "s/legacy: false/legacy: $LEGACY_FLAG/g" \
        "$TEMPLATES/ROADMAP.template.md" > "$PLANNING_DIR/ROADMAP.md"
    echo "✅ 创建 $PLANNING_DIR/ROADMAP.md"
else
    echo "⚠️  已存在 $PLANNING_DIR/ROADMAP.md，跳过"
fi

# 生成 OKR.md
if [ ! -f "$PLANNING_DIR/OKR.md" ]; then
    QUARTER=$(TZ=Asia/Shanghai date +%Y-Q%q)
    sed -e "s/<project-id>/$PROJECT_ID/g" \
        -e "s/<YYYY-MM-DD>/$TODAY/g" \
        -e "s/<YYYY-QN>/$QUARTER/g" \
        -e "s/legacy: false/legacy: $LEGACY_FLAG/g" \
        "$TEMPLATES/OKR.template.md" > "$PLANNING_DIR/OKR.md"
    echo "✅ 创建 $PLANNING_DIR/OKR.md"
else
    echo "⚠️  已存在 $PLANNING_DIR/OKR.md，跳过"
fi

# 自动 sync-to-profile
SYNC_SCRIPT="$SKILL_DIR/scripts/sync-to-profile.sh"
if [ -x "$SYNC_SCRIPT" ]; then
    echo ""
    echo "🔄 自动同步 profile.json..."
    bash "$SYNC_SCRIPT" "$PROJECT_ID"
else
    echo "⚠️  sync-to-profile.sh 不存在或不可执行，请手动运行"
fi

echo ""
echo "🎉 planning 三件套初始化完成：$PLANNING_DIR/"
echo "   - PRD.md"
echo "   - ROADMAP.md"
echo "   - OKR.md"
if $MIGRATE; then
    echo "   - 模式：历史项目迁移（legacy: true）"
else
    echo "   - 模式：新项目（legacy: false）"
fi
