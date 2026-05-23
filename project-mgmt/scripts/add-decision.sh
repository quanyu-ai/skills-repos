#!/bin/bash
# add-decision.sh - 加决策记录
# Usage: add-decision.sh <id> "<title>" [--ref ADR-001] [--rationale "..."] [--date YYYY-MM-DD]
set -e
. "$(dirname "$0")/_lib.sh"

usage() { echo 'Usage: '"$0"' <id> "<title>" [--ref ADR-001] [--rationale "..."] [--date YYYY-MM-DD]' >&2; exit 1; }
[ $# -lt 2 ] && usage

ID="$1"; TITLE="$2"; shift 2
REF=""; RAT=""; DATE=$(today)
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --rationale) RAT="$2"; shift 2 ;;
        --date) DATE="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

require_project_exists "$ID"
REF_DISPLAY="${REF:-—}"
RAT_DISPLAY="${RAT:-—}"
echo "| $DATE | $TITLE | $REF_DISPLAY | $RAT_DISPLAY |" >> "$PROJECTS_ROOT/$ID/decisions.md"

# also append to profile.key_decisions if --ref given
if [ -n "$REF" ]; then
    jq_inplace "$PROJECTS_ROOT/$ID/profile.json" --arg r "$REF" --arg t "$(now_iso)" \
        '.key_decisions = (.key_decisions + [$r] | unique) | .updated_at=$t'
else
    jq_inplace "$PROJECTS_ROOT/$ID/profile.json" --arg t "$(now_iso)" '.updated_at=$t'
fi

echo "✓ $ID + decision: [$DATE] $TITLE${REF:+ ($REF)}"
