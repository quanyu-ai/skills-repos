#!/bin/bash
# doctor.sh - project-mgmt self-check
# Last line: READY or NEED_SETUP: <reason>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
PROJECTS_ROOT="$WORKSPACE_ROOT/knowledge-repos/projects"
REGISTRY="$PROJECTS_ROOT/_registry.json"

fail() { echo "NEED_SETUP: $1"; exit 1; }

# bins
command -v jq >/dev/null 2>&1 || fail "jq not installed - sudo yum install -y jq"
command -v python3 >/dev/null 2>&1 || fail "python3 not installed"

# templates
for t in profile.template.json milestones.template.md decisions.template.md incidents.template.md metrics.template.json; do
    [ -f "$SKILL_DIR/templates/$t" ] || fail "templates/$t missing"
done

# projects root
mkdir -p "$PROJECTS_ROOT"

# registry auto-init
if [ ! -f "$REGISTRY" ]; then
    echo '{"version":"1.0","updated_at":null,"projects":{}}' > "$REGISTRY"
    echo "INFO: auto-created _registry.json"
fi

# legal stages
LEGAL_STAGES="planning requirement design develop test live deprecated"
is_legal_stage() {
    local s="$1"
    for v in $LEGAL_STAGES; do [ "$v" = "$s" ] && return 0; done
    return 1
}

CONS_FAILED=0

# Walk on-disk projects
shopt -s nullglob
for pd in "$PROJECTS_ROOT"/*/; do
    pid=$(basename "$pd")
    [ "$pid" = "_archive" ] && continue
    # check id format
    if ! [[ "$pid" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "  ✗ project dir '$pid' 不是 kebab-case"
        CONS_FAILED=1
    fi
    # required files
    for f in profile.json milestones.md decisions.md incidents.md metrics.json; do
        [ -f "$pd$f" ] || { echo "  ✗ [$pid] $f 缺失"; CONS_FAILED=1; }
    done
    # stage legal
    if [ -f "$pd/profile.json" ]; then
        stage=$(jq -r '.stage // "MISSING"' "$pd/profile.json")
        if ! is_legal_stage "$stage"; then
            echo "  ✗ [$pid] 非法 stage '$stage'"
            CONS_FAILED=1
        fi
        # registry consistency
        reg_stage=$(jq -r --arg id "$pid" '.projects[$id].stage // "MISSING"' "$REGISTRY")
        if [ "$reg_stage" = "MISSING" ]; then
            echo "  ✗ [$pid] 不在 _registry.json 中（用 new-project.sh 或 sync-registry）"
            CONS_FAILED=1
        elif [ "$reg_stage" != "$stage" ]; then
            echo "  ✗ [$pid] profile.stage=$stage 但 registry.stage=$reg_stage"
            CONS_FAILED=1
        fi
    fi
done
shopt -u nullglob

# Registry → disk consistency
while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    if [ ! -d "$PROJECTS_ROOT/$pid" ]; then
        echo "  ✗ [$pid] 在 _registry.json 但目录不存在"
        CONS_FAILED=1
    fi
done < <(jq -r '.projects | keys[]?' "$REGISTRY")

[ $CONS_FAILED -ne 0 ] && fail "一致性检查失败，见上方明细"

echo "READY"
