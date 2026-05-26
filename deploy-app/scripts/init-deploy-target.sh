#!/bin/bash
# init-deploy-target.sh - 新应用首次在某环境部署的引导脚本
# 用法: init-deploy-target.sh <app_id> <env>
# 作用:
#   1. 校验项目已在 _registry.json 注册（拿 code）
#   2. 按 PORT-ALLOCATION.md 公式算端口（env_base + code）
#   3. 询问目标服务器（默认本机，可选 8.138.118.28 / 43.139.53.121 / 其他）
#   4. prod 自动建库（建议名 <app>_<env>，自动生成强密码）
#   5. 写入三处：
#      - skills/deploy-app/config/apps.json (env_config.<env>)
#      - skills/deploy-app/config/environments.json (apps.<app_id>)
#      - knowledge-repos/projects/<app>/profile.json (deployment.<env>)
#   6. 追加 INFRA-LEDGER（保留历史，新增条目）

set -euo pipefail

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'
log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }
die()     { log_err "$*"; exit 1; }

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments.json"
WS_ROOT="/var/lib/openclaw/.openclaw/workspace"
REGISTRY="$WS_ROOT/knowledge-repos/projects/_registry.json"
INFRA_LEDGER="$WS_ROOT/knowledge-repos/management/INFRA-LEDGER.md"

usage() {
    cat <<USAGE
Usage: $(basename "$0") <app_id> <env>
  <app_id>  必须已在 _registry.json 注册
  <env>     proto | test | demo | prod

举例: $(basename "$0") smartops prod
USAGE
    exit 1
}

APP_ID="${1:-}"; ENV_NAME="${2:-}"
[ -z "$APP_ID" ] || [ -z "$ENV_NAME" ] && usage

case "$ENV_NAME" in
    proto|test|demo|prod) ;;
    *) die "非法环境: $ENV_NAME（合法: proto|test|demo|prod）" ;;
esac

# 1. 取 project code
[ -f "$REGISTRY" ] || die "_registry.json 不存在: $REGISTRY"
PROJ_CODE="$(jq -r --arg k "$APP_ID" '.projects[$k].code // empty' "$REGISTRY")"
if [ -z "$PROJ_CODE" ]; then
    log_err "项目 '$APP_ID' 未在 _registry.json 注册"
    log_err "先跑: bash $WS_ROOT/skills/project-mgmt/scripts/new-project.sh $APP_ID <显示名>"
    exit 1
fi
log_ok "$APP_ID 已注册，code=$PROJ_CODE"

# 2. 按公式算端口
case "$ENV_NAME" in
    proto) ENV_BASE=3000 ;;
    test)  ENV_BASE=3100 ;;
    demo)  ENV_BASE=3200 ;;
    prod)  ENV_BASE=3900 ;;
esac
PORT=$((ENV_BASE + 10#$PROJ_CODE))
log_ok "依公式 PORT-ALLOCATION.md: $ENV_BASE + $PROJ_CODE = $PORT"

# 3. 询问服务器
echo
echo "目标服务器候选:"
echo "  1) localhost (本机)"
echo "  2) 8.138.118.28 (阿里云)"
echo "  3) 43.139.53.121 (腾讯云)"
echo "  4) 自定义"
read -p "选择 [1-4, 默认 1]: " -r SRV_CHOICE
SRV_CHOICE="${SRV_CHOICE:-1}"
case "$SRV_CHOICE" in
    1) HOST="localhost" ;;
    2) HOST="8.138.118.28" ;;
    3) HOST="43.139.53.121" ;;
    4) read -p "输入主机名/IP: " -r HOST ;;
    *) die "非法选择" ;;
esac
log_ok "目标主机: $HOST"

# 4. prod 自动建库
DB_BLOCK=""
if [ "$ENV_NAME" = "prod" ]; then
    DB_NAME="${APP_ID//-/_}_${ENV_NAME}"
    DB_USER="$DB_NAME"
    DB_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*_+=' </dev/urandom 2>/dev/null | head -c 24 || echo "auto_$(date +%s)")"
    log_warn "prod 部署建议自动建库:"
    echo "  数据库名: $DB_NAME"
    echo "  用户名:   $DB_USER"
    echo "  密码:     $DB_PASS"
    read -p "是否在写入 env_config 时记录该数据库块？(Y/n): " -r
    if [[ -z "$REPLY" ]] || [[ "$REPLY" =~ ^[Yy]$ ]]; then
        DB_BLOCK="{
          \"type\": \"postgresql\",
          \"host\": \"localhost\",
          \"port\": 5432,
          \"database\": \"$DB_NAME\",
          \"username\": \"$DB_USER\",
          \"password\": \"$DB_PASS\"
        }"
        log_warn "⚠️ 仅记录到 env_config.prod.database；建库 SQL 由部署 Agent 自行执行（避免本脚本越权写 DB）"
    fi
fi

# 5a. 写 environments.json：apps.<app_id> = {port, pm2_name}
log "写入 environments.json"
PM2_NAME="${ENV_NAME}-${APP_ID}"
TMP_ENV="$(mktemp)"
jq --arg env "$ENV_NAME" --arg app "$APP_ID" --argjson port "$PORT" --arg pm2 "$PM2_NAME" \
   '.environments[$env].apps[$app] = {port: $port, pm2_name: $pm2}' \
   "$ENVS_JSON" > "$TMP_ENV" && mv "$TMP_ENV" "$ENVS_JSON"
log_ok "environments.json: $ENV_NAME.apps.$APP_ID = {port:$PORT, pm2_name:$PM2_NAME}"

# 5b. 写 apps.json：env_config.<env>（仅 prod 写 database）
if [ -n "$DB_BLOCK" ]; then
    TMP_APPS="$(mktemp)"
    jq --arg app "$APP_ID" --arg env "$ENV_NAME" --argjson db "$DB_BLOCK" \
       '.apps[$app].env_config[$env].database = $db' \
       "$APPS_JSON" > "$TMP_APPS" && mv "$TMP_APPS" "$APPS_JSON"
    log_ok "apps.json: $APP_ID.env_config.$ENV_NAME.database 已写入"
fi

# 5c. 写 profile.json：deployment.<env>
PROFILE="$WS_ROOT/knowledge-repos/projects/$APP_ID/profile.json"
if [ -f "$PROFILE" ]; then
    TMP_PROF="$(mktemp)"
    URL="http://$HOST:$PORT"
    jq --arg env "$ENV_NAME" --argjson port "$PORT" --arg url "$URL" \
       '.deployment[$env] = {port: $port, status: "planned", planned: true, url: $url, last_deployed_at: null, commit_hash: null, version: null}' \
       "$PROFILE" > "$TMP_PROF" && mv "$TMP_PROF" "$PROFILE"
    log_ok "profile.json: deployment.$ENV_NAME 已写入 (status=planned)"
else
    log_warn "profile.json 不存在: $PROFILE（请先在 project-mgmt 中建档）"
fi

# 6. INFRA-LEDGER 追加
if [ -f "$INFRA_LEDGER" ]; then
    {
        echo ""
        echo "<!-- AUTO-APPEND by init-deploy-target.sh @ $(date '+%F %T') -->"
        echo "### $APP_ID @ $ENV_NAME"
        echo ""
        echo "| 字段 | 值 |"
        echo "|------|-----|"
        echo "| 项目 id | $APP_ID |"
        echo "| 环境 | $ENV_NAME |"
        echo "| code | $PROJ_CODE |"
        echo "| 端口 | $PORT (= $ENV_BASE + $PROJ_CODE) |"
        echo "| 主机 | $HOST |"
        echo "| pm2_name | $PM2_NAME |"
        echo "| 状态 | planned |"
        echo "| 公式来源 | knowledge-repos/management/PRINCIPLES/PORT-ALLOCATION.md |"
        echo ""
    } >> "$INFRA_LEDGER"
    log_ok "INFRA-LEDGER 已追加 $APP_ID@$ENV_NAME 条目"
fi

cat <<DONE

═══════════════════════════════════════════════════════
                  init-deploy-target 完成
═══════════════════════════════════════════════════════

  应用:     $APP_ID
  环境:     $ENV_NAME
  端口:     $PORT (公式: $ENV_BASE + $PROJ_CODE)
  主机:     $HOST
  PM2 名:   $PM2_NAME
  状态:     planned

下一步:
  1. 如果是 prod，请手动在数据库中执行：
       CREATE DATABASE ...; CREATE USER ...; GRANT ...;
  2. 推送代码到对应分支
  3. 跑部署: bash $SKILL_DIR/scripts/deploy.sh $ENV_NAME $APP_ID [--version vX.Y.Z]

═══════════════════════════════════════════════════════
DONE
