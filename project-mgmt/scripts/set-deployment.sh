#!/bin/bash
# set-deployment.sh - 结构化登记项目某环境的部署信息
# 用法:
#   set-deployment.sh <project_id> <env> [--port N] [--status live|planned|deprecated]
#                     [--url URL] [--commit SHA] [--version vX.Y.Z]
#                     [--planned true|false] [--reason "..."]
#
# 强制: --port 必须 == env_base + project_code（与 PORT-ALLOCATION.md 一致），否则拒绝。
set -e
. "$(dirname "$0")/_lib.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 <project_id> <env> [options]

  <env>: proto | test | demo | prod

Options:
  --port N             端口号（必须 = env_base + project_code）
  --status STATUS      live | planned | deprecated  (默认 planned)
  --url URL            访问 URL（不填则用 http://localhost:<port>）
  --commit SHA         commit hash
  --version vX.Y.Z     版本号 tag
  --planned true|false 是否为计划态（默认按 status 推导）
  --reason "..."       变更原因（建议 ≥ 5 字符）
EOF
    exit 1
}

[ $# -lt 2 ] && usage
PROJECT_ID="$1"; ENV_NAME="$2"; shift 2

PORT=""; STATUS="planned"; URL=""; COMMIT=""; VERSION=""; PLANNED=""; REASON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --port)    PORT="$2"; shift 2 ;;
        --status)  STATUS="$2"; shift 2 ;;
        --url)     URL="$2"; shift 2 ;;
        --commit)  COMMIT="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --planned) PLANNED="$2"; shift 2 ;;
        --reason)  REASON="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

case "$ENV_NAME" in proto|test|demo|prod) ;; *) echo "✗ 非法 env '$ENV_NAME'" >&2; exit 1 ;; esac
case "$STATUS"   in live|planned|deprecated) ;; *) echo "✗ 非法 status '$STATUS'" >&2; exit 1 ;; esac

require_project_exists "$PROJECT_ID"
PROFILE="$PROJECTS_ROOT/$PROJECT_ID/profile.json"
PROJ_CODE="$(jq -r --arg k "$PROJECT_ID" '.projects[$k].code // empty' "$REGISTRY")"
[ -n "$PROJ_CODE" ] || { echo "✗ $PROJECT_ID 在 _registry.json 中无 code 字段（请补）" >&2; exit 1; }

case "$ENV_NAME" in
    proto) ENV_BASE=3000 ;;
    test)  ENV_BASE=3100 ;;
    demo)  ENV_BASE=3200 ;;
    prod)  ENV_BASE=3900 ;;
esac
EXPECTED_PORT=$((ENV_BASE + 10#$PROJ_CODE))

# 校验端口（如未指定，自动填）
if [ -z "$PORT" ]; then
    PORT="$EXPECTED_PORT"
    echo "ℹ 端口未指定，按公式自动设为 $PORT (= $ENV_BASE + $PROJ_CODE)"
elif [ "$PORT" != "$EXPECTED_PORT" ]; then
    echo "✗ 端口 $PORT 不符合 PORT-ALLOCATION.md 公式" >&2
    echo "  正确端口: $EXPECTED_PORT (= $ENV_BASE + $PROJ_CODE)" >&2
    echo "  如确需历史误用迁移，请先更新 PORT-ALLOCATION.md 的迁移段落再操作" >&2
    exit 1
fi

# planned 默认值
if [ -z "$PLANNED" ]; then
    [ "$STATUS" = "live" ] && PLANNED="false" || PLANNED="true"
fi

# URL 默认
[ -z "$URL" ] && URL="http://localhost:$PORT"

# 写入 profile.json
TMP="$(mktemp)"
NOW="$(now_iso)"

if [ "$STATUS" = "live" ]; then
    jq --arg env "$ENV_NAME" \
       --argjson port "$PORT" \
       --arg status "$STATUS" \
       --argjson planned "$PLANNED" \
       --arg url "$URL" \
       --arg now "$NOW" \
       --arg commit "$COMMIT" \
       --arg version "$VERSION" \
       '.deployment[$env] = {
            port: $port,
            status: $status,
            planned: $planned,
            url: $url,
            last_deployed_at: $now,
            commit_hash: (if $commit == "" then null else $commit end),
            version: (if $version == "" then null else $version end)
        } | .updated_at = $now' \
       "$PROFILE" > "$TMP" && mv "$TMP" "$PROFILE"
else
    jq --arg env "$ENV_NAME" \
       --argjson port "$PORT" \
       --arg status "$STATUS" \
       --argjson planned "$PLANNED" \
       --arg url "$URL" \
       --arg now "$NOW" \
       --arg commit "$COMMIT" \
       --arg version "$VERSION" \
       '.deployment[$env] = {
            port: $port,
            status: $status,
            planned: $planned,
            url: $url,
            last_deployed_at: null,
            commit_hash: (if $commit == "" then null else $commit end),
            version: (if $version == "" then null else $version end)
        } | .updated_at = $now' \
       "$PROFILE" > "$TMP" && mv "$TMP" "$PROFILE"
fi

echo "✓ $PROJECT_ID.deployment.$ENV_NAME = {port:$PORT, status:$STATUS, planned:$PLANNED}"
[ -n "$REASON" ] && echo "  reason: $REASON"
