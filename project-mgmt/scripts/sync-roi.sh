#!/bin/bash
# sync-roi.sh - per-project ROI snapshot
# Usage: sync-roi.sh <project-id> [--since YYYY-MM-DD]
#        sync-roi.sh --all [--since YYYY-MM-DD]
set -e
. "$(dirname "$0")/_lib.sh"

usage() {
    echo "Usage: $0 <project-id> [--since YYYY-MM-DD]" >&2
    echo "       $0 --all [--since YYYY-MM-DD]" >&2
    exit 1
}

[ $# -lt 1 ] && usage

TASK_TRACKER="$WORKSPACE_ROOT/knowledge-repos/management/TASK-TRACKER.json"
DEPLOY_LOG="$WORKSPACE_ROOT/knowledge-repos/management/DEPLOY-LOG.md"

# to_minutes <iso_start> <iso_end> -> integer minutes (end-start)
to_minutes_diff() {
    local a="$1" b="$2"
    local sa sb
    sa=$(date -d "$a" +%s 2>/dev/null || echo 0)
    sb=$(date -d "$b" +%s 2>/dev/null || echo 0)
    if [ "$sa" -eq 0 ] || [ "$sb" -eq 0 ]; then
        echo 0
        return
    fi
    local diff=$((sb - sa))
    [ $diff -lt 0 ] && diff=0
    echo $((diff / 60))
}

# build keyword regex from id+display_name+tags (jq output)
build_keywords() {
    local profile="$1"
    jq -r '[.id, .display_name, (.tags // [])[]] | map(select(. != null and . != "")) | unique | .[]' "$profile"
}

# match_task <task_json> <keyword_file>  -> 0 if match
task_matches() {
    local task_json="$1" kwfile="$2"
    local hay
    hay=$(echo "$task_json" | jq -r '[(.title // ""), (.description // ""), ((.tags // []) | join(" "))] | join(" ")')
    while IFS= read -r kw; do
        [ -z "$kw" ] && continue
        if echo "$hay" | grep -qF "$kw"; then
            return 0
        fi
    done < "$kwfile"
    return 1
}

sync_one() {
    local id="$1"
    local since="$2"
    require_project_exists "$id"
    local profile="$PROJECTS_ROOT/$id/profile.json"
    local roi_snap="$PROJECTS_ROOT/$id/roi.json"

    local name docs code
    name=$(jq -r '.display_name // ""' "$profile")
    docs=$(jq -r '.github_repos.docs // ""' "$profile")
    code=$(jq -r '.github_repos.code // ""' "$profile")

    # keywords
    local kwfile
    kwfile=$(mktemp)
    build_keywords "$profile" > "$kwfile"

    # iterate tasks
    local tasks_total=0 tasks_completed=0
    local est_min_total=0 act_min_total=0
    local matched_ids_file
    matched_ids_file=$(mktemp)
    : > "$matched_ids_file"

    if [ -f "$TASK_TRACKER" ]; then
        # task ids
        local task_ids
        task_ids=$(jq -r '.tasks[]?.id' "$TASK_TRACKER")
        while IFS= read -r tid; do
            [ -z "$tid" ] && continue
            local task_json
            task_json=$(jq -c --arg id "$tid" '.tasks[] | select(.id==$id)' "$TASK_TRACKER")
            # since filter on createdAt
            if [ -n "$since" ]; then
                local created
                created=$(echo "$task_json" | jq -r '.createdAt // ""')
                if [ -n "$created" ]; then
                    local cd
                    cd=$(echo "$created" | cut -c1-10)
                    if [[ "$cd" < "$since" ]]; then
                        continue
                    fi
                fi
            fi
            if task_matches "$task_json" "$kwfile"; then
                tasks_total=$((tasks_total + 1))
                echo "$tid" >> "$matched_ids_file"
                local status estm createdAt completedAt
                status=$(echo "$task_json" | jq -r '.status // ""')
                if [ "$status" = "completed" ]; then
                    tasks_completed=$((tasks_completed + 1))
                    estm=$(echo "$task_json" | jq -r '.estimatedMinutes // 0')
                    createdAt=$(echo "$task_json" | jq -r '.createdAt // ""')
                    completedAt=$(echo "$task_json" | jq -r '.completedAt // ""')
                    est_min_total=$((est_min_total + estm))
                    if [ -n "$createdAt" ] && [ -n "$completedAt" ]; then
                        local m
                        m=$(to_minutes_diff "$createdAt" "$completedAt")
                        act_min_total=$((act_min_total + m))
                    fi
                fi
            fi
        done <<< "$task_ids"
    fi

    local saved_min=$((est_min_total - act_min_total))
    local save_ratio
    if [ "$est_min_total" -gt 0 ]; then
        save_ratio=$(awk -v s="$saved_min" -v e="$est_min_total" 'BEGIN{printf "%.2f", s/e}')
    else
        save_ratio="0.00"
    fi

    # git commits
    local since_arg
    if [ -n "$since" ]; then
        since_arg="$since"
    else
        since_arg="1970-01-01"
    fi
    local commits_count=0
    # case 1: per-project git repo (e.g. code-repos/<id>/.git)
    for d in "$code" "code-repos/$id"; do
        [ -z "$d" ] && continue
        local full="$WORKSPACE_ROOT/$d"
        [ -d "$full/.git" ] || continue
        local c
        c=$(cd "$full" && git log --since="$since_arg" --oneline 2>/dev/null | wc -l)
        commits_count=$((commits_count + c))
        break
    done
    # case 2: monorepo with project subdir (docs-repos/<id>, code-repos/<id>)
    for mono in docs-repos code-repos; do
        local mono_full="$WORKSPACE_ROOT/$mono"
        [ -d "$mono_full/.git" ] || continue
        [ -d "$mono_full/$id" ] || continue
        local c
        c=$(cd "$mono_full" && git log --since="$since_arg" --oneline -- "$id" 2>/dev/null | wc -l)
        commits_count=$((commits_count + c))
    done

    # deploys
    local deploys_count=0
    if [ -f "$DEPLOY_LOG" ]; then
        local cutoff
        if [ -n "$since" ]; then
            cutoff="$since"
        else
            cutoff=$(TZ=Asia/Shanghai date -d '30 days ago' +'%Y-%m-%d' 2>/dev/null || echo "1970-01-01")
        fi
        deploys_count=$(awk -F'|' -v id="$id" -v name="$name" -v cutoff="$cutoff" '
            /^\| *[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                if ($2 < cutoff) next
                line=$0
                if (index(line, id) > 0 || (length(name) > 0 && index(line, name) > 0)) c++
            }
            END { print c+0 }
        ' "$DEPLOY_LOG")
    fi

    local now
    now=$(now_iso)

    # write profile.roi
    jq_inplace "$profile" \
        --argjson tt "$tasks_total" --argjson tc "$tasks_completed" \
        --argjson em "$est_min_total" --argjson am "$act_min_total" \
        --argjson sm "$saved_min" --argjson sr "$save_ratio" \
        --argjson cc "$commits_count" --argjson dp "$deploys_count" \
        --arg t "$now" \
        '.roi = (.roi // {})
         | .roi.tasks_total=$tt
         | .roi.tasks_completed=$tc
         | .roi.estimated_minutes=$em
         | .roi.actual_minutes=$am
         | .roi.saved_minutes=$sm
         | .roi.save_ratio=$sr
         | .roi.commits_count=$cc
         | .roi.deploys_count=$dp
         | .roi.last_calculated_at=$t'

    # snapshot roi.json
    local matched_json
    matched_json=$(jq -R . "$matched_ids_file" | jq -s .)
    local since_for_json
    if [ -n "$since" ]; then
        since_for_json="\"$since\""
    else
        since_for_json="null"
    fi
    cat > "$roi_snap" <<JSON
{
  "project": "$id",
  "calculated_at": "$now",
  "since": $since_for_json,
  "data_sources": {
    "task_tracker": "knowledge-repos/management/TASK-TRACKER.json",
    "deploy_log": "knowledge-repos/management/DEPLOY-LOG.md",
    "git_repos": ["$docs", "$code"]
  },
  "tasks_total": $tasks_total,
  "tasks_completed": $tasks_completed,
  "estimated_minutes": $est_min_total,
  "actual_minutes": $act_min_total,
  "saved_minutes": $saved_min,
  "save_ratio": $save_ratio,
  "commits_count": $commits_count,
  "deploys_count": $deploys_count,
  "matched_task_ids": $matched_json
}
JSON

    rm -f "$kwfile" "$matched_ids_file"

    # echo result for --all aggregation
    printf '%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\n' \
        "$id" "$tasks_completed" "$tasks_total" \
        "$est_min_total" "$act_min_total" "$saved_min" \
        "$save_ratio" "$commits_count" "$deploys_count"
}

# Argument parsing
SINCE=""
MODE_ALL=0
PROJECT_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --all) MODE_ALL=1; shift ;;
        --since) SINCE="$2"; shift 2 ;;
        --since=*) SINCE="${1#--since=}"; shift ;;
        -h|--help) usage ;;
        *) PROJECT_ID="$1"; shift ;;
    esac
done

if [ "$MODE_ALL" -eq 1 ]; then
    ensure_registry
    out_tsv=$(mktemp)
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        sync_one "$pid" "$SINCE" >> "$out_tsv"
    done < <(jq -r '.projects | keys[]?' "$REGISTRY" | sort)

    # render markdown summary
    echo "# 全项目 ROI 汇总（$(now_iso)）"
    echo
    if [ -n "$SINCE" ]; then
        echo "> since=$SINCE"
    else
        echo "> since=（全部历史，commits 全部 / deploys 默认 30d）"
    fi
    echo
    echo "| 项目 | 完成/总 | 预估min | 实际min | 节约min | 节约率 | commits | deploys |"
    echo "|------|---------|---------|---------|---------|--------|---------|---------|"
    sum_est=0; sum_act=0; sum_saved=0
    while IFS=$'\t' read -r id tc tt em am sm sr cc dp; do
        printf "| %s | %d/%d | %d | %d | %d | %s%% | %d | %d |\n" \
            "$id" "$tc" "$tt" "$em" "$am" "$sm" "$(awk -v r="$sr" 'BEGIN{printf "%d", r*100}')" "$cc" "$dp"
        sum_est=$((sum_est + em))
        sum_act=$((sum_act + am))
        sum_saved=$((sum_saved + sm))
    done < "$out_tsv"
    if [ "$sum_est" -gt 0 ]; then
        total_ratio=$(awk -v s="$sum_saved" -v e="$sum_est" 'BEGIN{printf "%.0f", (s/e)*100}')
    else
        total_ratio=0
    fi
    echo
    echo "**合计**：预估 ${sum_est}min / 实际 ${sum_act}min / 节约 ${sum_saved}min / 节约率 ${total_ratio}%"
    rm -f "$out_tsv"
else
    [ -z "$PROJECT_ID" ] && usage
    out=$(sync_one "$PROJECT_ID" "$SINCE")
    IFS=$'\t' read -r id tc tt em am sm sr cc dp <<< "$out"
    printf '✓ %-22s tasks=%d/%d  est=%dmin  act=%dmin  saved=%dmin (%s%%)  commits=%d  deploys=%d\n' \
        "$id" "$tc" "$tt" "$em" "$am" "$sm" "$(awk -v r=$sr 'BEGIN{printf "%d", r*100}')" "$cc" "$dp"
fi
