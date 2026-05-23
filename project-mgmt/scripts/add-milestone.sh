#!/bin/bash
# add-milestone.sh - 加里程碑
# Usage: add-milestone.sh <id> "<title>" [--date YYYY-MM-DD]
set -e
. "$(dirname "$0")/_lib.sh"

usage() { echo 'Usage: '"$0"' <id> "<title>" [--date YYYY-MM-DD]' >&2; exit 1; }
[ $# -lt 2 ] && usage

ID="$1"; TITLE="$2"; shift 2
DATE=$(today)
while [ $# -gt 0 ]; do
    case "$1" in
        --date) DATE="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

require_project_exists "$ID"
echo "| $DATE | MILESTONE | $TITLE |" >> "$PROJECTS_ROOT/$ID/milestones.md"
jq_inplace "$PROJECTS_ROOT/$ID/profile.json" --arg t "$(now_iso)" '.updated_at=$t'
echo "✓ $ID + milestone: [$DATE] $TITLE"
auto_refresh_context
