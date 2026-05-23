#!/bin/bash
# publish-version.sh - 把 _archive/ 下的归档快照发布到 prototype/archive/<version>/ 作为可访问历史版本
# 用法: bash publish-version.sh <project> <version>
#   例: bash publish-version.sh smart-college v3.0

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "用法: bash publish-version.sh <project> <version>"
    echo "例: bash publish-version.sh smart-college v3.0"
    exit 2
fi

PROJECT="$1"
VERSION="$2"

PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
PROTOTYPE_DIR="$PROJECT_DOCS/prototype"
ARCHIVE_SRC_ROOT="$PROTOTYPE_DIR/_archive"

# 1. 校验项目原型目录
if [ ! -d "$PROTOTYPE_DIR" ]; then
    echo "ERROR: 项目原型目录不存在: $PROTOTYPE_DIR"
    exit 1
fi

# 2. 查找归档源目录（支持 v3.0-* / v3.0_* / 精确 v3.0 等命名）
if [ ! -d "$ARCHIVE_SRC_ROOT" ]; then
    echo "ERROR: 归档根目录不存在: $ARCHIVE_SRC_ROOT"
    echo "请先把 ${VERSION} 时期的原型快照放到 $ARCHIVE_SRC_ROOT/${VERSION}-<date>/"
    exit 1
fi

# 优先级：精确 == VERSION > VERSION-* > VERSION_*
ARCHIVE_SRC=""
if [ -d "$ARCHIVE_SRC_ROOT/$VERSION" ]; then
    ARCHIVE_SRC="$ARCHIVE_SRC_ROOT/$VERSION"
else
    # 取第一个 VERSION-* 形式（按字典序）
    CAND="$(ls -d "$ARCHIVE_SRC_ROOT/${VERSION}-"* 2>/dev/null | head -1 || true)"
    if [ -z "$CAND" ]; then
        CAND="$(ls -d "$ARCHIVE_SRC_ROOT/${VERSION}_"* 2>/dev/null | head -1 || true)"
    fi
    ARCHIVE_SRC="$CAND"
fi

if [ -z "$ARCHIVE_SRC" ] || [ ! -d "$ARCHIVE_SRC" ]; then
    echo "ERROR: 找不到 ${VERSION} 对应的归档目录"
    echo "已查 $ARCHIVE_SRC_ROOT/ 下：$(ls "$ARCHIVE_SRC_ROOT" 2>/dev/null | tr '\n' ' ')"
    echo "请确认归档目录名形如：${VERSION}/ 或 ${VERSION}-YYYY-MM-DD/"
    exit 1
fi

echo "[publish-version] 源: $ARCHIVE_SRC"

# 3. 准备目标目录
PUBLISH_DIR="$PROTOTYPE_DIR/archive/$VERSION"
echo "[publish-version] 目标: $PUBLISH_DIR"

if [ -d "$PUBLISH_DIR" ]; then
    echo "[publish-version] 目标已存在，先清理"
    rm -rf "$PUBLISH_DIR"
fi
mkdir -p "$PUBLISH_DIR"

# 4. 复制完整快照
echo "[publish-version] 复制中..."
# 用 cp -a 保留权限/时间戳；末尾 /. 表示复制目录内容
cp -a "$ARCHIVE_SRC/." "$PUBLISH_DIR/"

# 5. Assertion：文件数对比
SRC_COUNT=$(find "$ARCHIVE_SRC" -type f | wc -l)
DST_COUNT=$(find "$PUBLISH_DIR" -type f | wc -l)
echo "[publish-version] 文件数 src=$SRC_COUNT dst=$DST_COUNT"
if [ "$SRC_COUNT" -ne "$DST_COUNT" ]; then
    echo "ERROR: 文件数不一致 src=$SRC_COUNT dst=$DST_COUNT"
    exit 1
fi

# 6. 更新 prototype/meta/versions.json
META_DIR="$PROTOTYPE_DIR/meta"
mkdir -p "$META_DIR"
VERSIONS_JSON="$META_DIR/versions.json"

PUBLISHED_AT="$(date -Iseconds)"
ARCHIVE_REL="archive/$VERSION"

if [ ! -f "$VERSIONS_JSON" ]; then
    cat > "$VERSIONS_JSON" <<JSONEOF
{
  "project": "$PROJECT",
  "current": "current",
  "versions": []
}
JSONEOF
fi

# 用 jq 更新（去重 + 追加）
TMP_JSON="$(mktemp)"
jq --arg v "$VERSION" \
   --arg p "$PUBLISHED_AT" \
   --arg a "$ARCHIVE_REL" \
   --argjson c "$DST_COUNT" \
   '.versions = ((.versions // []) | map(select(.version != $v)) + [{version:$v, published_at:$p, archive_dir:$a, file_count:$c}])' \
   "$VERSIONS_JSON" > "$TMP_JSON"
mv "$TMP_JSON" "$VERSIONS_JSON"

# 7. Assertion：versions.json 字段完整
ASSERT_FIELDS=$(jq -r --arg v "$VERSION" '.versions[] | select(.version==$v) | [.version,.published_at,.archive_dir,(.file_count|tostring)] | join("|")' "$VERSIONS_JSON")
if [ -z "$ASSERT_FIELDS" ]; then
    echo "ERROR: versions.json 写入后未找到 $VERSION 条目"
    exit 1
fi
echo "[publish-version] versions.json: $ASSERT_FIELDS"

# 8. 检查 index.html 是否有版本切换器
INDEX_HTML="$PROTOTYPE_DIR/index.html"
if [ -f "$INDEX_HTML" ]; then
    if grep -q 'id="version-switcher"' "$INDEX_HTML"; then
        echo "[publish-version] ✓ index.html 已带 version-switcher"
    else
        echo ""
        echo "⚠️  WARN: $INDEX_HTML 未发现 version-switcher 区块"
        echo "    请手动在 <body> 顶部插入以下片段（或重新跑 init.sh 模板）："
        echo "    参考: $SKILL_DIR/templates/shared/version-switcher.html"
    fi
fi

echo ""
echo "✅ 发布完成"
echo "   版本: $VERSION"
echo "   入口: $PROTOTYPE_DIR/archive/$VERSION/index.html"
echo "   文件: $DST_COUNT"
echo ""
echo "下一步：重新部署项目让历史版本对外可访问"
echo "   bash $WORKSPACE_ROOT/skills/deploy-app/scripts/deploy.sh proto $PROJECT"
