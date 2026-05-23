#!/bin/bash
# init-solution.sh - 为指定项目初始化方案设计目录骨架
#
# 用法：
#   bash init-solution.sh <project>
#   例：bash init-solution.sh smart-college
#
# 行为：
#   1. 校验 docs-repos/<project>/ 存在
#   2. 若 docs-repos/<project>/solution/ 已存在 → exit 1（保护现有内容）
#   3. 复制 templates/solution-structure/ → docs-repos/<project>/solution/
#   4. 替换占位符 {{PROJECT}} 为项目名，{{INIT_AT}} 为 ISO 时间
#   5. assertion 校验关键文件齐全
#   6. 输出后续操作建议

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
TEMPLATE_SRC="$SKILL_DIR/templates/solution-structure"

# ─── 参数校验 ─────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "❌ 用法: bash init-solution.sh <project>"
    echo "   例: bash init-solution.sh smart-college"
    exit 1
fi

PROJECT="$1"
DRY_RUN="${DRY_RUN:-0}"

if [ "$DRY_RUN" = "1" ]; then
    PROJECT_DIR="${DRY_RUN_BASE:-/tmp/solution-design-dry-run}/docs-repos/$PROJECT"
    mkdir -p "$PROJECT_DIR"
    echo "🧪 [DRY-RUN] 目标目录: $PROJECT_DIR"
else
    PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"
fi

SOLUTION_DIR="$PROJECT_DIR/solution"

# ─── 前置检查 ─────────────────────────────────────────
if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ 项目目录不存在: $PROJECT_DIR"
    echo "   请先创建项目文档仓库目录，或检查项目名拼写"
    exit 1
fi

if [ -d "$SOLUTION_DIR" ]; then
    echo "❌ solution/ 目录已存在: $SOLUTION_DIR"
    echo "   为保护现有内容，本脚本不会覆盖。"
    echo "   如确认要重建，请先备份："
    echo "     mv $SOLUTION_DIR ${SOLUTION_DIR}.bak.\$(date +%Y%m%d-%H%M%S)"
    exit 1
fi

if [ ! -d "$TEMPLATE_SRC" ]; then
    echo "❌ 模板目录缺失: $TEMPLATE_SRC"
    echo "   skill 安装可能损坏，请重新拉取 skills-repos"
    exit 1
fi

# ─── 执行复制 ─────────────────────────────────────────
echo "📋 复制模板 → $SOLUTION_DIR"
cp -r "$TEMPLATE_SRC" "$SOLUTION_DIR"

# ─── 替换占位符 ───────────────────────────────────────
INIT_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "🔧 替换占位符: PROJECT=$PROJECT, INIT_AT=$INIT_AT"

# 用 find + sed 替换所有文本文件中的占位符
find "$SOLUTION_DIR" -type f \( -name "*.md" -o -name "*.json" \) -print0 | \
while IFS= read -r -d '' file; do
    # macOS / GNU sed 兼容写法
    if sed --version >/dev/null 2>&1; then
        sed -i "s|{{PROJECT}}|$PROJECT|g; s|{{INIT_AT}}|$INIT_AT|g" "$file"
    else
        sed -i '' "s|{{PROJECT}}|$PROJECT|g; s|{{INIT_AT}}|$INIT_AT|g" "$file"
    fi
done

# ─── Assertion: 关键文件必须存在 ─────────────────────
echo "🔍 校验关键文件..."
REQUIRED_FILES=(
    "architecture/overview.md"
    "architecture/deployment.md"
    "architecture/data-flow.md"
    "database/er-diagram.md"
    "database/schema.md"
    "api/api-design.md"
    "modules/_example/design.md"
    "modules/_example/reqs.json"
    "modules/_example/apis.json"
    "adr/README.md"
    "adr/_template.md"
    "meta/version.json"
)

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$SOLUTION_DIR/$f" ]; then
        echo "  ❌ 缺失: $f"
        MISSING=$((MISSING + 1))
    fi
done

if [ $MISSING -gt 0 ]; then
    echo "❌ 初始化失败：$MISSING 个关键文件缺失"
    exit 1
fi

# ─── 校验 version.json 占位符替换成功 ────────────────
if grep -q "{{PROJECT}}\|{{INIT_AT}}" "$SOLUTION_DIR/meta/version.json"; then
    echo "❌ version.json 占位符未替换成功"
    exit 1
fi

# ─── 输出后续操作建议 ─────────────────────────────────
echo ""
echo "✅ 方案目录初始化成功!"
echo ""
echo "📍 位置: $SOLUTION_DIR"
echo "📊 文件数: $(find "$SOLUTION_DIR" -type f | wc -l)"
echo ""
echo "📝 后续建议（推荐顺序）:"
echo "   1. 编辑 architecture/overview.md  ← 写清分层和模块清单"
echo "   2. 新增 adr/ADR-001-tech-stack.md ← 记录技术选型决策"
echo "      cp adr/_template.md adr/ADR-001-tech-stack.md"
echo "   3. 编辑 database/er-diagram.md     ← ER 图（mermaid）"
echo "   4. 编辑 database/schema.md         ← 表结构"
echo "   5. 编辑 api/api-design.md          ← API 总览"
echo "   6. 新增业务模块:"
echo "      cp -r modules/_example modules/<your-module>"
echo ""
echo "💡 git 提交建议:"
echo "   cd $PROJECT_DIR && git add solution/ && git commit -m 'feat(solution): init solution skeleton'"

exit 0
