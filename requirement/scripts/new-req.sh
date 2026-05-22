#!/bin/bash
# new-req.sh - 创建一条新需求
# Usage: new-req.sh <project> "<title>" [--role <role>] [--phase <phase>] [--priority P0|P1|P2]
#                                       [--category <cat>] [--source-doc <doc>] [--source-section <sec>]

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
TEMPLATE="$SKILL_DIR/templates/req-template.md"

usage() {
    cat >&2 <<EOF
Usage: $0 <project> "<title>" [options]

Options:
  --role <role>             角色名（学院领导|教师|辅导员|学生|校友|系统管理员|...）
  --phase <phase>           一阶段|二阶段|unscheduled  (default: unscheduled)
  --priority P0|P1|P2       优先级 (default: P1)
  --category <cat>          业务功能|数据需求|非功能需求 (default: 业务功能)
  --source-doc <doc>        来源文档文件名
  --source-section <sec>    来源章节号
  --status <s>              初始状态 (default: draft)

Example:
  $0 smart-college "学院领导-工作台" --role 学院领导 --phase 一阶段 --priority P0
EOF
    exit 1
}

[ $# -lt 2 ] && usage

PROJECT="$1"
TITLE="$2"
shift 2

ROLE=""
PHASE="unscheduled"
PRIORITY="P1"
CATEGORY="业务功能"
SOURCE_DOC=""
SOURCE_SECTION=""
STATUS="draft"

while [ $# -gt 0 ]; do
    case "$1" in
        --role)            ROLE="$2"; shift 2;;
        --phase)           PHASE="$2"; shift 2;;
        --priority)        PRIORITY="$2"; shift 2;;
        --category)        CATEGORY="$2"; shift 2;;
        --source-doc)      SOURCE_DOC="$2"; shift 2;;
        --source-section)  SOURCE_SECTION="$2"; shift 2;;
        --status)          STATUS="$2"; shift 2;;
        *) echo "Unknown option: $1" >&2; usage;;
    esac
done

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
mkdir -p "$REQ_DIR"

TODAY="$(date +%Y%m%d)"
TODAY_ISO="$(date +%Y-%m-%d)"

# 找到当天最大编号
MAX_N=0
for f in "$REQ_DIR"/REQ-${TODAY}-*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .md | awk -F- '{print $3}' | sed 's/^0*//')
    [ -z "$n" ] && n=0
    if [ "$n" -gt "$MAX_N" ]; then
        MAX_N=$n
    fi
done
NEXT_N=$((MAX_N + 1))
[ "$NEXT_N" -lt 1 ] && NEXT_N=1
[ "$NEXT_N" -gt 999 ] && { echo "ERROR: 当天编号超过 999"; exit 2; }
NNN=$(printf "%03d" "$NEXT_N")
REQ_ID="REQ-${TODAY}-${NNN}"
OUT="$REQ_DIR/${REQ_ID}.md"

# 渲染模板
sed \
    -e "s|REQ-YYYYMMDD-NNN|$REQ_ID|g" \
    -e "s|^title: .*|title: $TITLE|" \
    -e "s|^status: .*|status: $STATUS|" \
    -e "s|^phase: .*|phase: $PHASE|" \
    -e "s|^priority: .*|priority: $PRIORITY|" \
    -e "s|^category: .*|category: $CATEGORY|" \
    -e "s|^role: .*|role: $ROLE|" \
    -e "s|^source_doc: .*|source_doc: \"$SOURCE_DOC\"|" \
    -e "s|^source_section: .*|source_section: \"$SOURCE_SECTION\"|" \
    -e "s|^created: .*|created: $TODAY_ISO|" \
    -e "s|^updated: .*|updated: $TODAY_ISO|" \
    -e "s|<角色>-<功能名>|$TITLE|g" \
    "$TEMPLATE" > "$OUT"

REL="${OUT#$WORKSPACE_ROOT/}"
echo "✓ Created: $REL"
echo "  id=$REQ_ID role=$ROLE phase=$PHASE priority=$PRIORITY"
