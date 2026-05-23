#!/bin/bash
# Shared helpers for project-mgmt scripts
# source it: . "$(dirname "$0")/_lib.sh"

set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
PROJECTS_ROOT="$WORKSPACE_ROOT/knowledge-repos/projects"
REGISTRY="$PROJECTS_ROOT/_registry.json"
TEMPLATES_DIR="$SKILL_DIR/templates"

LEGAL_STAGES="planning requirement design develop test live deprecated"

now_iso() {
    TZ=Asia/Shanghai date +'%Y-%m-%dT%H:%M:%S+08:00'
}
today() {
    TZ=Asia/Shanghai date +'%Y-%m-%d'
}

ensure_registry() {
    mkdir -p "$PROJECTS_ROOT"
    [ -f "$REGISTRY" ] || echo '{"version":"1.0","updated_at":null,"projects":{}}' > "$REGISTRY"
}

is_legal_stage() {
    local s="$1"
    for v in $LEGAL_STAGES; do [ "$v" = "$s" ] && return 0; done
    return 1
}

# is_legal_transition <from> <to>
is_legal_transition() {
    local f="$1" t="$2"
    [ "$f" = "$t" ] && return 0
    # any → deprecated
    [ "$t" = "deprecated" ] && return 0
    # live → develop
    [ "$f" = "live" ] && [ "$t" = "develop" ] && return 0
    # forward chain
    case "$f→$t" in
        "planning→requirement"|"requirement→design"|"design→develop"|"develop→test"|"test→live") return 0 ;;
    esac
    return 1
}

# require_project_exists <id>
require_project_exists() {
    local id="$1"
    [ -d "$PROJECTS_ROOT/$id" ] || { echo "✗ project '$id' 不存在，先跑 new-project.sh" >&2; exit 1; }
    [ -f "$PROJECTS_ROOT/$id/profile.json" ] || { echo "✗ project '$id' profile.json 缺失" >&2; exit 1; }
}

# validate_id <id>
validate_id() {
    local id="$1"
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "✗ id '$id' 必须是 kebab-case (小写+数字+-)" >&2; exit 1; }
}

# jq_inplace <file> <filter>
jq_inplace() {
    local f="$1"; shift
    local tmp
    tmp=$(mktemp)
    jq "$@" "$f" > "$tmp" && mv "$tmp" "$f"
}

# registry_upsert <id> <stage> <display_name> <priority>
registry_upsert() {
    ensure_registry
    local id="$1" stage="$2" name="$3" prio="$4"
    local now
    now=$(now_iso)
    jq_inplace "$REGISTRY" \
        --arg id "$id" --arg stage "$stage" --arg name "$name" --arg prio "$prio" --arg now "$now" \
        '.projects[$id] = {stage:$stage, display_name:$name, priority:$prio, updated_at:$now}
         | .updated_at = $now'
}

# stage color (ANSI)
stage_color() {
    case "$1" in
        planning)    echo $'\033[90m' ;;  # gray
        requirement) echo $'\033[36m' ;;  # cyan
        design)      echo $'\033[34m' ;;  # blue
        develop)     echo $'\033[33m' ;;  # yellow
        test)        echo $'\033[35m' ;;  # magenta
        live)        echo $'\033[32m' ;;  # green
        deprecated)  echo $'\033[31m' ;;  # red
        *)           echo $'\033[0m' ;;
    esac
}
RESET=$'\033[0m'

# auto_refresh_context — 由 add-*/update-status 等脚本在成功后调用。
# 失败不阻塞主流程；可用 PROJECT_MGMT_AUTO_REFRESH=0 关闭（批量场景）。
auto_refresh_context() {
    [ "${PROJECT_MGMT_AUTO_REFRESH:-1}" = "0" ] && return 0
    bash "$SKILL_DIR/scripts/refresh-context.sh" >/dev/null 2>&1 || true
}
