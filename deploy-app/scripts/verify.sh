#!/bin/bash
# verify.sh - 健康检查脚本
# 用法: ./verify.sh <env> <app> [--strict]
# 退出: 0=HEALTHY  1=UNHEALTHY  2=参数错误
#
# 默认嬽松模式: HTTP 2xx/3xx/401/403 均视为 HEALTHY
#   (应用进程能响应请求即认为存活，401/403 = 服务活着只是需鉴权)
# --strict: 仅 2xx/3xx 视为 HEALTHY

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments.json"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'

usage() {
    echo "Usage: $(basename "$0") <env> <app> [--strict]" >&2
    exit 2
}

ENV_NAME="${1:-}"
APP_KEY="${2:-}"
STRICT="false"
[ "${3:-}" = "--strict" ] && STRICT="true"
[ -z "$ENV_NAME" ] || [ -z "$APP_KEY" ] && usage

# 读配置
APP_HEALTH="$(jq -r --arg k "$APP_KEY" '.apps[$k].health_path // empty' "$APPS_JSON")"
[ -n "$APP_HEALTH" ] || { echo "UNHEALTHY: apps.json[$APP_KEY].health_path 未配置" >&2; exit 1; }

PORT="$(jq -r --arg e "$ENV_NAME" --arg a "$APP_KEY" \
    '.environments[$e].apps[$a].port // empty' "$ENVS_JSON")"
[ -n "$PORT" ] || { echo "UNHEALTHY: 环境 $ENV_NAME 未声明 app=$APP_KEY" >&2; exit 1; }

# host: envapp 级 > env 级 > env.default_host
HOST="$(jq -r --arg e "$ENV_NAME" --arg a "$APP_KEY" \
    '.environments[$e].apps[$a].host // empty' "$ENVS_JSON")"
[ -n "$HOST" ] || HOST="$(jq -r --arg e "$ENV_NAME" '.environments[$e].host // empty' "$ENVS_JSON")"
[ -n "$HOST" ] || HOST="$(jq -r --arg e "$ENV_NAME" '.environments[$e].default_host // empty' "$ENVS_JSON")"
[ -n "$HOST" ] || { echo "UNHEALTHY: 环境 $ENV_NAME 无 host" >&2; exit 1; }

# 健康检查时本机用 127.0.0.1（host=localhost 时）
PROBE_HOST="$HOST"
[ "$PROBE_HOST" = "localhost" ] && PROBE_HOST="127.0.0.1"

URL="http://${PROBE_HOST}:${PORT}${APP_HEALTH}"
printf "${C_B}▶ probing %s${C_N}\n" "$URL"

MAX_RETRY=10
SLEEP_SEC=3
LAST_ERR=""

for i in $(seq 1 "$MAX_RETRY"); do
    # 拿 HTTP 状态码，最多 5s 超时
    CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 3 --max-time 5 \
        "$URL" 2>/dev/null)" || CODE=""
    [ -z "$CODE" ] && CODE="000"

    if [ "$STRICT" = "true" ]; then
        case "$CODE" in
            2??|3??)
                printf "${C_G}✓ attempt %s/%s: HTTP %s${C_N}\n" "$i" "$MAX_RETRY" "$CODE"
                echo "HEALTHY"
                exit 0
                ;;
        esac
    else
        case "$CODE" in
            2??|3??|401|403)
                printf "${C_G}✓ attempt %s/%s: HTTP %s (alive)${C_N}\n" "$i" "$MAX_RETRY" "$CODE"
                echo "HEALTHY"
                exit 0
                ;;
        esac
    fi

    LAST_ERR="HTTP $CODE"
    printf "${C_Y}⚠ attempt %s/%s: %s (retry in ${SLEEP_SEC}s)${C_N}\n" "$i" "$MAX_RETRY" "$LAST_ERR"
    [ "$i" -lt "$MAX_RETRY" ] && sleep "$SLEEP_SEC"
done

printf "${C_R}✗ all %s attempts failed${C_N}\n" "$MAX_RETRY" >&2
echo "UNHEALTHY: $LAST_ERR"
exit 1
