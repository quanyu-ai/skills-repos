#!/bin/bash
# sync-map.sh - 扫描 docs-repos/<project>/requirements/REQ-*.md，
#               重建 requirements-map.json 和 INDEX.md
# Usage: sync-map.sh <project>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 1 ] && { echo "Usage: $0 <project>"; exit 1; }

PROJECT="$1"
REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
MAP="$REQ_DIR/requirements-map.json"
INDEX="$REQ_DIR/INDEX.md"

[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found"; exit 2; }

# 提取 frontmatter 字段
get_field() {
    local f="$1" key="$2"
    awk -v k="$key" '
        BEGIN { in_fm=0 }
        /^---$/ { if (in_fm) exit; in_fm=1; next }
        in_fm && $0 ~ "^"k": " { sub("^"k": ", ""); gsub(/^"|"$/, ""); print; exit }
    ' "$f"
}

NOW="$(date -Iseconds)"

# 初始化 stats
declare -A STATUS_CNT PHASE_CNT PRIORITY_CNT ROLE_CNT
TOTAL=0

# 第一遍：扫描，构建 jq 输入
REQS_JSON="{}"
TMP=$(mktemp)
trap "rm -f $TMP" EXIT

echo "{}" > "$TMP"

for f in "$REQ_DIR"/REQ-*.md; do
    [ -f "$f" ] || continue
    id=$(get_field "$f" "id")
    [ -z "$id" ] && { echo "WARN: $f missing id, skip" >&2; continue; }
    title=$(get_field "$f" "title")
    status=$(get_field "$f" "status")
    phase=$(get_field "$f" "phase")
    priority=$(get_field "$f" "priority")
    category=$(get_field "$f" "category")
    role=$(get_field "$f" "role")
    source_doc=$(get_field "$f" "source_doc")
    source_section=$(get_field "$f" "source_section")
    source_review=$(get_field "$f" "source_review")
    merged_to=$(get_field "$f" "merged_to")
    created=$(get_field "$f" "created")
    updated=$(get_field "$f" "updated")
    relpath="${f#$WORKSPACE_ROOT/}"

    TOTAL=$((TOTAL+1))
    STATUS_CNT[$status]=$((${STATUS_CNT[$status]:-0}+1))
    PHASE_CNT[$phase]=$((${PHASE_CNT[$phase]:-0}+1))
    PRIORITY_CNT[$priority]=$((${PRIORITY_CNT[$priority]:-0}+1))
    [ -n "$role" ] && ROLE_CNT[$role]=$((${ROLE_CNT[$role]:-0}+1))

    jq --arg id "$id" \
       --arg title "$title" \
       --arg status "$status" \
       --arg phase "$phase" \
       --arg priority "$priority" \
       --arg category "$category" \
       --arg role "$role" \
       --arg source_doc "$source_doc" \
       --arg source_section "$source_section" \
       --arg source_review "$source_review" \
       --arg merged_to "$merged_to" \
       --arg created "$created" \
       --arg updated "$updated" \
       --arg file "$relpath" \
       '. + {($id): {id:$id,title:$title,status:$status,phase:$phase,priority:$priority,category:$category,role:$role,source_doc:$source_doc,source_section:$source_section,source_review:$source_review,merged_to:$merged_to,created:$created,updated:$updated,file:$file}}' \
       "$TMP" > "$TMP.new" && mv "$TMP.new" "$TMP"
done

# stats -> json
stats_json() {
    local -n arr=$1
    local out="{"
    local first=1
    for k in "${!arr[@]}"; do
        [ -z "$k" ] && continue
        [ $first -eq 0 ] && out+=","
        out+="\"$k\":${arr[$k]}"
        first=0
    done
    out+="}"
    echo "$out"
}

STATUS_J=$(stats_json STATUS_CNT)
PHASE_J=$(stats_json PHASE_CNT)
PRIORITY_J=$(stats_json PRIORITY_CNT)
ROLE_J=$(stats_json ROLE_CNT)

jq --arg project "$PROJECT" \
   --arg now "$NOW" \
   --argjson total "$TOTAL" \
   --argjson status "$STATUS_J" \
   --argjson phase "$PHASE_J" \
   --argjson priority "$PRIORITY_J" \
   --argjson role "$ROLE_J" \
   --slurpfile reqs "$TMP" \
   '{schema_version:"1.0", project:$project, generated_at:$now, stats:{total:$total, by_status:$status, by_phase:$phase, by_priority:$priority, by_role:$role}, requirements: $reqs[0]}' \
   <<< '{}' > "$MAP"

echo "✓ Synced: ${MAP#$WORKSPACE_ROOT/}"
echo "  total=$TOTAL"

# 生成 INDEX.md
{
    echo "# $PROJECT 需求索引"
    echo ""
    echo "> 自动生成于 $NOW，请勿手改。"
    echo ""
    echo "## 统计"
    echo ""
    echo "- 总数：$TOTAL"
    echo "- 状态分布：$(echo "$STATUS_J" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")')"
    echo "- 阶段分布：$(echo "$PHASE_J" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")')"
    echo "- 优先级分布：$(echo "$PRIORITY_J" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")')"
    echo "- 角色分布：$(echo "$ROLE_J" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")')"
    echo ""
    echo "## 需求列表"
    echo ""
    echo "| ID | 标题 | 角色 | 阶段 | 优先级 | 状态 |"
    echo "|----|------|------|------|--------|------|"
    jq -r '.requirements | to_entries | sort_by(.key) | .[] | .value | "| [\(.id)](\(.file | sub(".*/requirements/"; "")) ) | \(.title) | \(.role) | \(.phase) | \(.priority) | \(.status) |"' "$MAP"
} > "$INDEX"

echo "✓ Wrote: ${INDEX#$WORKSPACE_ROOT/}"
