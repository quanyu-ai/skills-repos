#!/bin/bash
# generate.sh - 主生成脚本
# 用法: bash generate.sh <style> <project> [--modules m1,m2] [--role <role>] [--req <REQ-id>] [--phase <一阶段|二阶段>] [--dry-run]
# Phase 1: 跑通参数解析 + 读取需求 + 生成 1 个示例文件

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "用法: bash generate.sh <style> <project> [选项...]"
    echo ""
    echo "  <style>           wireframe / highfi / interactive"
    echo "  <project>         项目名"
    echo "  --modules <list>  仅生成指定模块（逗号分隔）"
    echo "  --role <role>     仅生成指定角色"
    echo "  --req <REQ-id>    仅生成指定 REQ"
    echo "  --phase <phase>   仅生成指定阶段（一阶段/二阶段）"
    echo "  --dry-run         只打印将生成的文件清单"
    exit 2
fi

STYLE="$1"
PROJECT="$2"
shift 2

FILTER_MODULES=""
FILTER_ROLE=""
FILTER_REQ=""
FILTER_PHASE=""
DRY_RUN="no"

while [ $# -gt 0 ]; do
    case "$1" in
        --modules) FILTER_MODULES="$2"; shift 2 ;;
        --role)    FILTER_ROLE="$2";    shift 2 ;;
        --req)     FILTER_REQ="$2";     shift 2 ;;
        --phase)   FILTER_PHASE="$2";   shift 2 ;;
        --dry-run) DRY_RUN="yes";       shift ;;
        *) echo "ERROR: 未知参数: $1"; exit 2 ;;
    esac
done

# 风格校验
case "$STYLE" in
    wireframe|highfi|interactive) ;;
    *) echo "ERROR: <style> 必须是 wireframe / highfi / interactive"; exit 2 ;;
esac

PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
PROTOTYPE_DIR="$PROJECT_DOCS/prototype"
REQ_MAP="$PROJECT_DOCS/requirements/requirements-map.json"

# 校验项目已初始化
[ -d "$PROTOTYPE_DIR" ] || { echo "ERROR: 原型目录不存在，请先运行 init.sh: $PROTOTYPE_DIR"; exit 1; }

# 校验需求映射可读
[ -f "$REQ_MAP" ] || { echo "ERROR: requirements-map.json 不存在: $REQ_MAP"; exit 1; }

# 模板路径
BASE_TEMPLATE="$SKILL_DIR/templates/$STYLE/base.html"
[ -f "$BASE_TEMPLATE" ] || { echo "ERROR: 模板不存在: $BASE_TEMPLATE"; exit 1; }

# 过滤需求
echo "[generate] 读取需求映射: $REQ_MAP"

JQ_FILTER='.requirements | to_entries | .[]'

# 增加过滤条件
if [ -n "$FILTER_ROLE" ]; then
    JQ_FILTER="$JQ_FILTER | select(.value.role == \"$FILTER_ROLE\")"
fi
if [ -n "$FILTER_PHASE" ]; then
    JQ_FILTER="$JQ_FILTER | select(.value.phase == \"$FILTER_PHASE\")"
fi
if [ -n "$FILTER_REQ" ]; then
    JQ_FILTER="$JQ_FILTER | select(.key == \"$FILTER_REQ\")"
fi

FILTERED=$(jq -r "$JQ_FILTER | \"\\(.key)|\\(.value.title)|\\(.value.role)\"" "$REQ_MAP")

if [ -z "$FILTERED" ]; then
    echo "WARN: 过滤后无匹配需求"
    exit 0
fi

COUNT=$(echo "$FILTERED" | wc -l)
echo "[generate] 风格: $STYLE  项目: $PROJECT  匹配需求: $COUNT 条"

if [ "$DRY_RUN" = "yes" ]; then
    echo ""
    echo "[dry-run] 将生成的需求:"
    echo "$FILTERED" | while IFS='|' read -r req_id title role; do
        echo "  - $req_id  [$role]  $title"
    done
    exit 0
fi

# Phase 1: 仅生成第 1 条作为示例
FIRST_LINE=$(echo "$FILTERED" | head -1)
REQ_ID=$(echo "$FIRST_LINE" | cut -d'|' -f1)
TITLE=$(echo "$FIRST_LINE" | cut -d'|' -f2)
ROLE=$(echo "$FIRST_LINE" | cut -d'|' -f3)

# 推断模块名（从 title 提取，去掉角色前缀；保留中英文，删除空格和斜杠）
MODULE=$(echo "$TITLE" | sed "s|^${ROLE}-||" | tr -d ' /\\\t')
[ -z "$MODULE" ] && MODULE="example"

OUTPUT_DIR="$PROTOTYPE_DIR/modules/$ROLE"
mkdir -p "$OUTPUT_DIR"

# 用 sed 填充模板占位符（Phase 1 极简实现）
OUTPUT_FILE="$OUTPUT_DIR/${MODULE}"
sed -e "s|{{REQ_ID}}|$REQ_ID|g" \
    -e "s|{{TITLE}}|$TITLE|g" \
    -e "s|{{ROLE}}|$ROLE|g" \
    -e "s|{{PROJECT}}|$PROJECT|g" \
    -e "s|{{STYLE}}|$STYLE|g" \
    "$BASE_TEMPLATE" > "$OUTPUT_FILE"

echo "[generate] ✅ 生成示例文件: $OUTPUT_FILE"

# 更新 revisions.md
REVISIONS="$PROTOTYPE_DIR/meta/revisions.md"
cat >> "$REVISIONS" <<MDEOF

## $(date -Iseconds) - 生成 [$STYLE]

- 过滤条件: role=$FILTER_ROLE, phase=$FILTER_PHASE, req=$FILTER_REQ, modules=$FILTER_MODULES
- 匹配需求: $COUNT 条（Phase 1 仅生成首条）
- 新增文件: modules/$ROLE/${MODULE}

MDEOF

# 更新 meta/requirements-map.json（追加 mapping）
META_MAP="$PROTOTYPE_DIR/meta/requirements-map.json"
TMP_MAP="$META_MAP.tmp"
jq --arg req "$REQ_ID" \
   --arg title "$TITLE" \
   --arg role "$ROLE" \
   --arg file "modules/$ROLE/${MODULE}" \
   --arg style "$STYLE" \
   --arg now "$(date -Iseconds)" \
   '.style = $style
    | .updated = $now
    | .mappings += [{
        req_id: $req,
        title: $title,
        role: $role,
        files: [$file],
        generated_at: $now
      }]' "$META_MAP" > "$TMP_MAP" && mv "$TMP_MAP" "$META_MAP"

echo "[generate] ✅ 已更新 meta/requirements-map.json"
echo ""
echo "⚠️  Phase 1 仅生成首条匹配需求作为示例。完整生成请等 Phase 2 实装。"
