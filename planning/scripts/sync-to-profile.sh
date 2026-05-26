#!/bin/bash
# sync-to-profile.sh - 把 planning_docs 路径同步到 knowledge-repos/projects/<id>/profile.json
# Usage:
#   sync-to-profile.sh <project-id>                  # 默认 status=draft
#   sync-to-profile.sh <project-id> --status approved
#   sync-to-profile.sh <project-id> --status reviewing

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DOCS_ROOT="$WORKSPACE_ROOT/docs-repos"
PROJECTS_ROOT="$WORKSPACE_ROOT/knowledge-repos/projects"

usage() {
    cat >&2 <<EOF
Usage:
  $0 <project-id> [--status draft|reviewing|approved]
EOF
    exit 1
}

[ -z "$1" ] && usage

PROJECT_ID="$1"
shift

STATUS=""
while [ -n "$1" ]; do
    case "$1" in
        --status)
            STATUS="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

PROFILE="$PROJECTS_ROOT/$PROJECT_ID/profile.json"
PLANNING_DIR="$DOCS_ROOT/$PROJECT_ID/planning"

if [ ! -f "$PROFILE" ]; then
    echo "❌ profile.json 不存在：$PROFILE" >&2
    echo "提示：请先用 project-mgmt new-project.sh 注册项目" >&2
    exit 1
fi

if [ ! -d "$PLANNING_DIR" ]; then
    echo "❌ planning/ 目录不存在：$PLANNING_DIR" >&2
    echo "提示：请先跑 init-planning.sh $PROJECT_ID" >&2
    exit 1
fi

# 拼相对路径
PRD_PATH=""
ROADMAP_PATH=""
OKR_PATH=""
LEGACY="false"

[ -f "$PLANNING_DIR/PRD.md" ] && PRD_PATH="docs-repos/$PROJECT_ID/planning/PRD.md"
[ -f "$PLANNING_DIR/ROADMAP.md" ] && ROADMAP_PATH="docs-repos/$PROJECT_ID/planning/ROADMAP.md"
[ -f "$PLANNING_DIR/OKR.md" ] && OKR_PATH="docs-repos/$PROJECT_ID/planning/OKR.md"

# 自动从 PRD frontmatter 读 status / legacy（若未指定）
if [ -f "$PLANNING_DIR/PRD.md" ]; then
    if [ -z "$STATUS" ]; then
        STATUS=$(awk '/^status:/{print $2; exit}' "$PLANNING_DIR/PRD.md" 2>/dev/null || echo "")
    fi
    LEGACY=$(awk '/^legacy:/{print $2; exit}' "$PLANNING_DIR/PRD.md" 2>/dev/null || echo "false")
fi

[ -z "$STATUS" ] && STATUS="draft"

NOW=$(TZ=Asia/Shanghai date +%Y-%m-%dT%H:%M:%S+08:00)

# 用 jq 写入 planning_docs 字段
TMP=$(mktemp)
jq --arg prd "$PRD_PATH" \
   --arg roadmap "$ROADMAP_PATH" \
   --arg okr "$OKR_PATH" \
   --arg status "$STATUS" \
   --arg now "$NOW" \
   --argjson legacy "$LEGACY" \
   '.planning_docs = {
      prd: (if $prd == "" then null else $prd end),
      roadmap: (if $roadmap == "" then null else $roadmap end),
      okr: (if $okr == "" then null else $okr end),
      status: $status,
      last_updated: $now,
      legacy: $legacy
   } | .updated_at = $now' \
   "$PROFILE" > "$TMP"

mv "$TMP" "$PROFILE"

echo "✅ 已更新 $PROFILE"
echo "   planning_docs:"
echo "     prd: $PRD_PATH"
echo "     roadmap: $ROADMAP_PATH"
echo "     okr: ${OKR_PATH:-null}"
echo "     status: $STATUS"
echo "     legacy: $LEGACY"
echo "     last_updated: $NOW"

# 若 status=approved，把 PRD/ROADMAP frontmatter 也改为 approved
if [ "$STATUS" = "approved" ]; then
    for f in "$PLANNING_DIR/PRD.md" "$PLANNING_DIR/ROADMAP.md" "$PLANNING_DIR/OKR.md"; do
        [ -f "$f" ] || continue
        if grep -q "^status: draft" "$f"; then
            sed -i 's/^status: draft/status: approved/' "$f"
            echo "✅ $f frontmatter 已改为 status: approved"
        fi
    done

    # 调 project-mgmt add-milestone（若可用）
    MS_SCRIPT="$WORKSPACE_ROOT/skills/project-mgmt/scripts/add-milestone.sh"
    if [ -x "$MS_SCRIPT" ]; then
        bash "$MS_SCRIPT" "$PROJECT_ID" "PLANNING-APPROVED: PRD/ROADMAP/OKR 三件套审定通过" || \
            echo "⚠️  add-milestone.sh 执行失败（非致命）"
    else
        echo "⚠️  project-mgmt add-milestone.sh 不存在，跳过里程碑追加"
    fi
fi
