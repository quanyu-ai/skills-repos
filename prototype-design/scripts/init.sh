#!/bin/bash
# init.sh - 初始化项目原型骨架
# 用法: bash init.sh <project>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 1 ]; then
    echo "用法: bash init.sh <project>"
    echo "例: bash init.sh smart-college"
    exit 2
fi

PROJECT="$1"
PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"

# 校验项目目录存在
if [ ! -d "$PROJECT_DOCS" ]; then
    echo "ERROR: 项目目录不存在: $PROJECT_DOCS"
    echo "请先在 docs-repos/ 下创建该项目目录"
    exit 1
fi

PROTOTYPE_DIR="$PROJECT_DOCS/prototype"

# 检测是否已初始化
if [ -d "$PROTOTYPE_DIR" ] && [ "$(ls -A "$PROTOTYPE_DIR" 2>/dev/null)" ]; then
    echo "WARN: $PROTOTYPE_DIR 已存在且非空"
    echo "若要重新初始化，请先备份并清空该目录"
    exit 1
fi

# 建标准目录
echo "[init] 创建目录骨架..."
mkdir -p "$PROTOTYPE_DIR/_shared/components"
mkdir -p "$PROTOTYPE_DIR/modules"
mkdir -p "$PROTOTYPE_DIR/meta/archive"

# 复制 styles.css
echo "[init] 复制 _shared/styles.css..."
cp "$SKILL_DIR/templates/wireframe/styles.css" "$PROTOTYPE_DIR/_shared/styles.css"

# 复制 nav.html 和 sidebar.html（如果模板里有）
if [ -f "$SKILL_DIR/templates/wireframe/components.html" ]; then
    cp "$SKILL_DIR/templates/wireframe/components.html" "$PROTOTYPE_DIR/_shared/components/all.html"
fi

# 复制 index.template.html → index.html，注入项目名和品牌
echo "[init] 生成 index.html..."
BRAND_JSON="$SKILL_DIR/config/brand.json"
COMPANY_NAME=$(jq -r '.company_name // "权舆科技"' "$BRAND_JSON")
SLOGAN=$(jq -r '.slogan // ""' "$BRAND_JSON")

sed -e "s|{{PROJECT}}|$PROJECT|g" \
    -e "s|{{COMPANY_NAME}}|$COMPANY_NAME|g" \
    -e "s|{{SLOGAN}}|$SLOGAN|g" \
    "$SKILL_DIR/templates/shared/index.template.html" > "$PROTOTYPE_DIR/index.html"

# 复制 index-config.template.json → meta/index-config.json（如不存在）
INDEX_CFG_OUT="$PROTOTYPE_DIR/meta/index-config.json"
INDEX_CFG_TPL="$SKILL_DIR/templates/shared/index-config.template.json"
if [ ! -f "$INDEX_CFG_OUT" ] && [ -f "$INDEX_CFG_TPL" ]; then
  echo "[init] 创建 meta/index-config.json..."
  sed -e "s|{{PROJECT}}|$PROJECT|g" "$INDEX_CFG_TPL" > "$INDEX_CFG_OUT"
fi

# 创建空 requirements-map.json
echo "[init] 创建 meta/requirements-map.json..."
cat > "$PROTOTYPE_DIR/meta/requirements-map.json" <<JSONEOF
{
  "project": "$PROJECT",
  "style": "wireframe",
  "updated": "$(date -Iseconds)",
  "mappings": []
}
JSONEOF

# 创建 revisions.md
cat > "$PROTOTYPE_DIR/meta/revisions.md" <<MDEOF
# $PROJECT 原型变更日志

> 自动维护，请勿手改。

## $(date -Iseconds) - 初始化

- 项目原型骨架创建完成
- 风格：wireframe
- 已建目录：_shared/ / modules/ / meta/

---
MDEOF

echo ""
echo "✅ 初始化完成"
echo "目录：$PROTOTYPE_DIR"
echo ""
echo "下一步："
echo "  bash $SKILL_DIR/scripts/generate.sh wireframe $PROJECT --role <角色>"
