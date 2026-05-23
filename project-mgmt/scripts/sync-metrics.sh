#!/bin/bash
# sync-metrics.sh - 自动算并更新指标
# Usage: sync-metrics.sh <id>  |  sync-metrics.sh --all
set -e
. "$(dirname "$0")/_lib.sh"

usage() { echo 'Usage: '"$0"' <id> | --all' >&2; exit 1; }
[ $# -lt 1 ] && usage

DEPLOY_LOG="$WORKSPACE_ROOT/knowledge-repos/management/DEPLOY-LOG.md"

# count_deploy_30d <id> <display_name>
count_deploy_30d() {
    local id="$1" name="$2"
    [ -f "$DEPLOY_LOG" ] || { echo 0; return; }
    local cutoff
    cutoff=$(TZ=Asia/Shanghai date -d '30 days ago' +'%Y-%m-%d' 2>/dev/null || echo "1970-01-01")
    awk -F'|' -v id="$id" -v name="$name" -v cutoff="$cutoff" '
        /^\| *[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            gsub(/^[ \t]+|[ \t]+$/, "", $3)
            if ($2 < cutoff) next
            line = $0
            if (index(line, id) > 0 || (length(name) > 0 && index(line, name) > 0)) c++
        }
        END { print c+0 }
    ' "$DEPLOY_LOG"
}

# count_commits_30d <code_dir>
count_commits_30d() {
    local dir="$1"
    [ -z "$dir" ] && { echo 0; return; }
    local full="$WORKSPACE_ROOT/$dir"
    [ -d "$full/.git" ] || [ -d "$full" ] || { echo 0; return; }
    if [ -d "$full/.git" ]; then
        (cd "$full" && git log --since="30 days ago" --oneline 2>/dev/null | wc -l)
    else
        echo 0
    fi
}

sync_one() {
    local id="$1"
    require_project_exists "$id"
    local profile="$PROJECTS_ROOT/$id/profile.json"
    local metrics="$PROJECTS_ROOT/$id/metrics.json"

    local name docs code req_dir proto_dir sol_dir
    name=$(jq -r '.display_name // ""' "$profile")
    docs=$(jq -r '.github_repos.docs // ""' "$profile")
    code=$(jq -r '.github_repos.code // ""' "$profile")
    req_dir=$(jq -r '.key_dirs.requirements // ""' "$profile")
    proto_dir=$(jq -r '.key_dirs.prototype // ""' "$profile")
    sol_dir=$(jq -r '.key_dirs.solution // ""' "$profile")

    # requirements
    local req_total=0 req_active=0 req_done=0 req_dep=0
    local req_map=""
    if [ -n "$req_dir" ] && [ -f "$WORKSPACE_ROOT/$req_dir/requirements-map.json" ]; then
        req_map="$WORKSPACE_ROOT/$req_dir/requirements-map.json"
    elif [ -n "$docs" ] && [ -f "$WORKSPACE_ROOT/$docs/requirements/requirements-map.json" ]; then
        req_map="$WORKSPACE_ROOT/$docs/requirements/requirements-map.json"
    fi
    if [ -n "$req_map" ]; then
        req_total=$(jq '.requirements | length' "$req_map" 2>/dev/null || echo 0)
        req_dep=$(jq '[.requirements | to_entries[] | select(.value.status=="deprecated")] | length' "$req_map" 2>/dev/null || echo 0)
        req_done=$(jq '[.requirements | to_entries[] | select(.value.status=="done")] | length' "$req_map" 2>/dev/null || echo 0)
        req_active=$((req_total - req_dep))
    fi

    # prototypes
    local proto_total=0
    local proto_map=""
    if [ -n "$proto_dir" ] && [ -f "$WORKSPACE_ROOT/$proto_dir/meta/requirements-map.json" ]; then
        proto_map="$WORKSPACE_ROOT/$proto_dir/meta/requirements-map.json"
    elif [ -n "$docs" ] && [ -f "$WORKSPACE_ROOT/$docs/prototype/meta/requirements-map.json" ]; then
        proto_map="$WORKSPACE_ROOT/$docs/prototype/meta/requirements-map.json"
    fi
    if [ -n "$proto_map" ]; then
        proto_total=$(jq '[.mappings[]?.files[]?] | length' "$proto_map" 2>/dev/null || echo 0)
    fi

    # adr count
    local adr_count=0
    local adr_dir=""
    if [ -n "$sol_dir" ]; then adr_dir="$WORKSPACE_ROOT/$sol_dir"
    elif [ -n "$docs" ] && [ -d "$WORKSPACE_ROOT/$docs/solution" ]; then adr_dir="$WORKSPACE_ROOT/$docs/solution"
    fi
    if [ -n "$adr_dir" ] && [ -d "$adr_dir" ]; then
        adr_count=$(find "$adr_dir" -type f -iname 'ADR-*' 2>/dev/null | wc -l)
    fi

    # deploys / commits
    local deploys commits
    deploys=$(count_deploy_30d "$id" "$name")
    commits=$(count_commits_30d "$code")

    local now
    now=$(now_iso)

    # write profile.metrics
    jq_inplace "$profile" \
        --argjson rt "$req_total" --argjson ra "$req_active" --argjson pt "$proto_total" \
        --argjson adr "$adr_count" --argjson dp "$deploys" --argjson cm "$commits" --arg t "$now" \
        '.metrics.requirements_total=$rt
         | .metrics.requirements_active=$ra
         | .metrics.prototypes_total=$pt
         | .metrics.adr_count=$adr
         | .metrics.deploy_count_30d=$dp
         | .metrics.commits_30d=$cm
         | .metrics.last_synced_at=$t
         | .updated_at=$t'

    # write metrics.json snapshot
    jq_inplace "$metrics" \
        --arg id "$id" --arg t "$now" \
        --argjson rt "$req_total" --argjson ra "$req_active" --argjson rd "$req_done" --argjson rdep "$req_dep" \
        --argjson pt "$proto_total" --argjson adr "$adr_count" \
        --argjson dp "$deploys" --argjson cm "$commits" \
        '.project=$id | .snapshot_at=$t
         | .requirements_total=$rt | .requirements_active=$ra
         | .requirements_done=$rd | .requirements_deprecated=$rdep
         | .prototypes_total=$pt | .adr_count=$adr
         | .deploy_count_30d=$dp | .commits_30d=$cm'

    printf '✓ %-22s req=%d/%d  proto=%d  adr=%d  deploy30d=%d  commit30d=%d\n' \
        "$id" "$req_active" "$req_total" "$proto_total" "$adr_count" "$deploys" "$commits"
}

if [ "$1" = "--all" ]; then
    ensure_registry
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        sync_one "$pid"
    done < <(jq -r '.projects | keys[]?' "$REGISTRY" | sort)
else
    sync_one "$1"
fi
