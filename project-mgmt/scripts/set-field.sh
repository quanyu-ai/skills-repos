#!/bin/bash
# set-field.sh - 统一字段更新（受白名单约束）
# Usage: set-field.sh <id> <field> <value> --reason "..."
# 合法 field 白名单: risk_level | health | priority | next_milestone | tech_stack
set -e
. "$(dirname "$0")/_lib.sh"

WHITELIST="risk_level health priority next_milestone tech_stack"

usage() {
    cat >&2 <<EOF
Usage: $0 <id> <field> <value> --reason "..."
  合法 field 白名单: $WHITELIST
  枚举字段:
    risk_level : low | medium | high | critical
    health     : green | yellow | red
    priority   : high | medium | low
EOF
    exit 1
}

[ $# -lt 3 ] && usage

ID="$1"; FIELD="$2"; VALUE="$3"; shift 3
REASON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

# field 必须在白名单
ok=0
for f in $WHITELIST; do [ "$f" = "$FIELD" ] && ok=1; done
[ $ok -eq 1 ] || { echo "✗ field '$FIELD' 不在白名单（合法: $WHITELIST）" >&2; exit 1; }

# reason 必填且 ≥ 5 字符
[ -z "$REASON" ] && { echo "✗ --reason 必填" >&2; exit 1; }
if [ ${#REASON} -lt 5 ]; then
    echo "✗ --reason 太短（≥5字符），请写清楚原因" >&2
    exit 1
fi

# 枚举校验
case "$FIELD" in
    risk_level)
        case "$VALUE" in low|medium|high|critical) ;; *) echo "✗ 非法 risk_level '$VALUE'（合法: low|medium|high|critical）" >&2; exit 1 ;; esac ;;
    health)
        case "$VALUE" in green|yellow|red) ;; *) echo "✗ 非法 health '$VALUE'（合法: green|yellow|red）" >&2; exit 1 ;; esac ;;
    priority)
        case "$VALUE" in high|medium|low) ;; *) echo "✗ 非法 priority '$VALUE'（合法: high|medium|low）" >&2; exit 1 ;; esac ;;
esac

require_project_exists "$ID"
PROFILE="$PROJECTS_ROOT/$ID/profile.json"

OLD=$(jq -r ".${FIELD} // \"\"" "$PROFILE")

if [ "$OLD" = "$VALUE" ]; then
    echo "ℹ️  $ID.$FIELD 已经是 '$VALUE'，无变更"
    exit 0
fi

NOW=$(now_iso)
TODAY=$(today)
DISPLAY=$(jq -r '.display_name' "$PROFILE")
STAGE=$(jq -r '.stage' "$PROFILE")
PRIO=$(jq -r '.priority' "$PROFILE")

jq_inplace "$PROFILE" --arg f "$FIELD" --arg v "$VALUE" --arg t "$NOW" \
    '.[$f] = $v | .updated_at = $t'

# 若改的是 priority，registry 也要同步
if [ "$FIELD" = "priority" ]; then
    registry_upsert "$ID" "$STAGE" "$DISPLAY" "$VALUE"
fi

echo "| $TODAY | FIELD-CHANGE | $FIELD: $OLD → $VALUE ($REASON) |" >> "$PROJECTS_ROOT/$ID/milestones.md"

echo "✓ $ID.$FIELD: $OLD → $VALUE"
auto_refresh_context
