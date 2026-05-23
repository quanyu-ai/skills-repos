#!/bin/bash
# add-incident.sh - 加事故/客户反馈/内部踩坑
# Usage: add-incident.sh <id> "<title>" [--type bug|feedback|inner|outage] [--severity P0|P1|P2] [--date YYYY-MM-DD]
set -e
. "$(dirname "$0")/_lib.sh"

usage() { echo 'Usage: '"$0"' <id> "<title>" [--type bug|feedback|inner|outage] [--severity P0|P1|P2] [--date YYYY-MM-DD]' >&2; exit 1; }
[ $# -lt 2 ] && usage

ID="$1"; TITLE="$2"; shift 2
TYPE="inner"; SEV="P2"; DATE=$(today)
while [ $# -gt 0 ]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --severity) SEV="$2"; shift 2 ;;
        --date) DATE="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

# validate type / severity
case "$TYPE" in bug|feedback|inner|outage) ;; *) echo "✗ --type 仅支持 bug/feedback/inner/outage" >&2; exit 1 ;; esac
case "$SEV" in P0|P1|P2) ;; *) echo "✗ --severity 仅支持 P0/P1/P2" >&2; exit 1 ;; esac

require_project_exists "$ID"
echo "| $DATE | $TYPE | $SEV | $TITLE |" >> "$PROJECTS_ROOT/$ID/incidents.md"
jq_inplace "$PROJECTS_ROOT/$ID/profile.json" --arg t "$(now_iso)" '.updated_at=$t'
echo "✓ $ID + incident: [$DATE][$TYPE][$SEV] $TITLE"
