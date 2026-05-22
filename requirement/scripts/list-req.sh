#!/bin/bash
# list-req.sh - 列出某项目的所有需求
# Usage: list-req.sh <project> [--status <s>] [--phase <p>] [--role <r>] [--priority <pri>]

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 1 ] && { echo "Usage: $0 <project> [--status <s>] [--phase <p>] [--role <r>] [--priority <pri>]"; exit 1; }

PROJECT="$1"
shift

F_STATUS=""
F_PHASE=""
F_ROLE=""
F_PRIORITY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --status)   F_STATUS="$2"; shift 2;;
        --phase)    F_PHASE="$2"; shift 2;;
        --role)     F_ROLE="$2"; shift 2;;
        --priority) F_PRIORITY="$2"; shift 2;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found"; exit 2; }

# 从 frontmatter 提取字段
get_field() {
    local f="$1" key="$2"
    awk -v k="$key" '
        BEGIN { in_fm=0 }
        /^---$/ { if (in_fm) exit; in_fm=1; next }
        in_fm && $0 ~ "^"k": " { sub("^"k": ", ""); gsub(/^"|"$/, ""); print; exit }
    ' "$f"
}

printf "%-22s | %-30s | %-14s | %-10s | %-3s | %-14s\n" "ID" "TITLE" "STATUS" "PHASE" "PRI" "ROLE"
printf -- "-----------------------+--------------------------------+----------------+------------+-----+---------------\n"

COUNT=0
for f in "$REQ_DIR"/REQ-*.md; do
    [ -f "$f" ] || continue
    id=$(get_field "$f" "id")
    title=$(get_field "$f" "title")
    status=$(get_field "$f" "status")
    phase=$(get_field "$f" "phase")
    priority=$(get_field "$f" "priority")
    role=$(get_field "$f" "role")

    [ -n "$F_STATUS" ] && [ "$status" != "$F_STATUS" ] && continue
    [ -n "$F_PHASE" ] && [ "$phase" != "$F_PHASE" ] && continue
    [ -n "$F_ROLE" ] && [ "$role" != "$F_ROLE" ] && continue
    [ -n "$F_PRIORITY" ] && [ "$priority" != "$F_PRIORITY" ] && continue

    # 截断长 title
    if [ ${#title} -gt 30 ]; then
        title="${title:0:27}..."
    fi
    printf "%-22s | %-30s | %-14s | %-10s | %-3s | %-14s\n" "$id" "$title" "$status" "$phase" "$priority" "$role"
    COUNT=$((COUNT + 1))
done

echo ""
echo "Total: $COUNT"
