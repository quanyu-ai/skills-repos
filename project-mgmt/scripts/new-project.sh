#!/bin/bash
# new-project.sh - 新建项目档案
# Usage: new-project.sh <id> --display-name "<name>" --client "<client>" --stage <stage> [options]
set -e
. "$(dirname "$0")/_lib.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 <id> [options]
Required:
  --display-name "<中文名>"
  --client       "<客户>"
  --stage        planning|requirement|design|develop|test|live|deprecated
Optional:
  --owner        <name>            (default: 龙哥)
  --tech-stack   "..."
  --priority     high|medium|low   (default: medium)
  --docs-dir     <path>            (default: docs-repos/<id> 若存在则自动填)
  --code-dir     <path>            (default: code-repos/<id> 若存在则自动填)
  --tags         tag1,tag2
  --next         "<下一里程碑>"
EOF
    exit 1
}

[ $# -lt 1 ] && usage
ID="$1"; shift
validate_id "$ID"

DISPLAY="" CLIENT="" STAGE="" OWNER="龙哥" TECH="" PRIO="medium"
DOCS_DIR="" CODE_DIR="" TAGS="" NEXT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --display-name) DISPLAY="$2"; shift 2 ;;
        --client) CLIENT="$2"; shift 2 ;;
        --stage) STAGE="$2"; shift 2 ;;
        --owner) OWNER="$2"; shift 2 ;;
        --tech-stack) TECH="$2"; shift 2 ;;
        --priority) PRIO="$2"; shift 2 ;;
        --docs-dir) DOCS_DIR="$2"; shift 2 ;;
        --code-dir) CODE_DIR="$2"; shift 2 ;;
        --tags) TAGS="$2"; shift 2 ;;
        --next) NEXT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

[ -z "$DISPLAY" ] && { echo "✗ --display-name 必填" >&2; exit 1; }
[ -z "$STAGE" ] && { echo "✗ --stage 必填" >&2; exit 1; }
is_legal_stage "$STAGE" || { echo "✗ 非法 stage '$STAGE'（合法: $LEGAL_STAGES）" >&2; exit 1; }

ensure_registry
PDIR="$PROJECTS_ROOT/$ID"
[ -d "$PDIR" ] && { echo "✗ 项目 '$ID' 已存在 ($PDIR)" >&2; exit 1; }

# auto-detect docs/code
[ -z "$DOCS_DIR" ] && [ -d "$WORKSPACE_ROOT/docs-repos/$ID" ] && DOCS_DIR="docs-repos/$ID"
[ -z "$CODE_DIR" ] && [ -d "$WORKSPACE_ROOT/code-repos/$ID" ] && CODE_DIR="code-repos/$ID"

NOW=$(now_iso)
TODAY=$(today)

mkdir -p "$PDIR"

# tags csv → json array
if [ -n "$TAGS" ]; then
    TAGS_JSON=$(printf '%s' "$TAGS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
else
    TAGS_JSON='[]'
fi

# key_dirs
REQ_DIR="null"; PROTO_DIR="null"; SOL_DIR="null"
if [ -n "$DOCS_DIR" ]; then
    [ -d "$WORKSPACE_ROOT/$DOCS_DIR/requirements" ] && REQ_DIR="\"$DOCS_DIR/requirements\""
    [ -d "$WORKSPACE_ROOT/$DOCS_DIR/prototype" ] && PROTO_DIR="\"$DOCS_DIR/prototype\""
    [ -d "$WORKSPACE_ROOT/$DOCS_DIR/solution" ] && SOL_DIR="\"$DOCS_DIR/solution\""
fi

# build profile.json from template
jq \
    --arg id "$ID" --arg name "$DISPLAY" --arg stage "$STAGE" --arg client "$CLIENT" \
    --arg started "$TODAY" --arg updated "$NOW" --arg owner "$OWNER" --arg tech "$TECH" \
    --arg prio "$PRIO" --arg next "$NEXT" \
    --arg docs "$DOCS_DIR" --arg code "$CODE_DIR" \
    --argjson tags "$TAGS_JSON" \
    --argjson reqd "$REQ_DIR" --argjson protod "$PROTO_DIR" --argjson sold "$SOL_DIR" \
    '
    .id = $id
    | .display_name = $name
    | .stage = $stage
    | .client = $client
    | .started_at = $started
    | .updated_at = $updated
    | .owner = $owner
    | .tech_stack = $tech
    | .priority = $prio
    | .next_milestone = $next
    | .tags = $tags
    | .github_repos.docs = (if $docs == "" then null else $docs end)
    | .github_repos.code = (if $code == "" then null else $code end)
    | .key_dirs.requirements = $reqd
    | .key_dirs.prototype = $protod
    | .key_dirs.solution = $sold
    ' "$TEMPLATES_DIR/profile.template.json" > "$PDIR/profile.json"

# milestones / decisions / incidents
sed "s/{{DISPLAY_NAME}}/$DISPLAY/g" "$TEMPLATES_DIR/milestones.template.md" > "$PDIR/milestones.md"
echo "| $TODAY | INIT | 项目档案创建（stage=$STAGE）|" >> "$PDIR/milestones.md"

sed "s/{{DISPLAY_NAME}}/$DISPLAY/g" "$TEMPLATES_DIR/decisions.template.md" > "$PDIR/decisions.md"
sed "s/{{DISPLAY_NAME}}/$DISPLAY/g" "$TEMPLATES_DIR/incidents.template.md" > "$PDIR/incidents.md"

# metrics.json
jq --arg id "$ID" --arg t "$NOW" '.project=$id | .snapshot_at=$t' \
    "$TEMPLATES_DIR/metrics.template.json" > "$PDIR/metrics.json"

# registry
registry_upsert "$ID" "$STAGE" "$DISPLAY" "$PRIO"

echo "✓ 项目档案已创建: $PDIR"
echo "  display_name : $DISPLAY"
echo "  stage        : $STAGE"
echo "  client       : $CLIENT"
echo "  docs_dir     : ${DOCS_DIR:-<none>}"
echo "  code_dir     : ${CODE_DIR:-<none>}"
