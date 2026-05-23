#!/bin/bash
# update-status.sh - 改生命周期阶段
# Usage: update-status.sh <id> <new-stage> [--reason "..."] [--force]
set -e
. "$(dirname "$0")/_lib.sh"

usage() { echo "Usage: $0 <id> <new-stage> [--reason \"...\"] [--force]" >&2; exit 1; }
[ $# -lt 2 ] && usage

ID="$1"; NEW="$2"; shift 2
REASON=""; FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

require_project_exists "$ID"
is_legal_stage "$NEW" || { echo "✗ 非法 stage '$NEW'（合法: $LEGAL_STAGES）" >&2; exit 1; }

PROFILE="$PROJECTS_ROOT/$ID/profile.json"
OLD=$(jq -r '.stage' "$PROFILE")

if [ "$OLD" = "$NEW" ]; then
    echo "ℹ️  $ID 当前已是 stage=$NEW，无变更"
    exit 0
fi

FORCED=""
if ! is_legal_transition "$OLD" "$NEW"; then
    if [ $FORCE -eq 1 ]; then
        FORCED=" [FORCE]"
        echo "⚠️  非常规跳转 $OLD → $NEW，--force 已生效"
    else
        echo "✗ 非法状态转换 $OLD → $NEW（如需绕过加 --force）" >&2
        echo "   合法路径: planning→requirement→design→develop→test→live, live→develop, any→deprecated" >&2
        exit 1
    fi
fi

NOW=$(now_iso)
TODAY=$(today)
DISPLAY=$(jq -r '.display_name' "$PROFILE")
PRIO=$(jq -r '.priority' "$PROFILE")

jq_inplace "$PROFILE" --arg s "$NEW" --arg t "$NOW" '.stage=$s | .updated_at=$t'

MSG="STAGE-CHANGE: $OLD → $NEW$FORCED"
[ -n "$REASON" ] && MSG="$MSG ($REASON)"
echo "| $TODAY | STAGE | $MSG |" >> "$PROJECTS_ROOT/$ID/milestones.md"

registry_upsert "$ID" "$NEW" "$DISPLAY" "$PRIO"

echo "✓ $ID: $OLD → $NEW"
