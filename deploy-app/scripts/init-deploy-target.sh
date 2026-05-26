#!/bin/bash
# init-deploy-target.sh - 新应用首次在某环境部署的引导脚本
# 用法: init-deploy-target.sh <app_id> <env>
# 作用:
#   1. 校验项目已在 _registry.json 注册（拿 code）
#   2. 按 PORT-ALLOCATION.md 公式算端口（env_base + code）
#   3. 询问目标服务器（默认本机，可选 8.138.118.28 / 43.139.53.121 / 其他）
#   4. 询问 DB 服务器（C 阶段：environments.<env>.database_host 默认 / 可覆盖为远程）
#   5. DB 命名硬约束：强制 <app>_<env>；同名库已存在时：
#        - prod: 询问是否复用现有库【红线，不准重建】
#        - proto/test/demo: 直接报错，要求先手工 drop
#   6. 写入三处：
#      - skills/deploy-app/config/apps.json (env_config.<env>，含完整 db block 含 host/port)
#      - skills/deploy-app/config/environments.json (apps.<app_id>)
#      - knowledge-reps/projects/<app>/profile.json (deployment.<env>)
#   7. 追加 INFRA-LEDGER（保留历史，新增条目）
#
# 参见: PRINCIPLES/DB-DEPLOY-INTEGRATION.md §十「环境隔离与服务器分离」

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

# ----------------------------------------------------------------
# DB 命名硬约束（C 阶段新增）
# 强制 <app_id>_<env> 格式，禁止跨环境复用
# ----------------------------------------------------------------
EXPECTED_DB_NAME="${APP_ID//-/_}_${ENV_NAME}"
log "DB 命名硬约束: 预期 DB 名 = $EXPECTED_DB_NAME (格式: <app>_<env>)"

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

# 3. 询问服务器（E 阶段：拒绝 localhost）
validate_host_not_local_init() {
    case "$1" in
        localhost|127.0.0.1|::1|0.0.0.0|"") return 1 ;;
        *) return 0 ;;
    esac
}
# 从 baseline 读默认值（如不存在则用预设拓扑）
BASELINE_JSON="$CONFIG_DIR/environments.json.baseline"
DEFAULT_HOST=""
if [ -f "$BASELINE_JSON" ]; then
    DEFAULT_HOST="$(jq -r --arg e "$ENV_NAME" '.environments[$e].host // empty' "$BASELINE_JSON")"
fi
[ -n "$DEFAULT_HOST" ] || case "$ENV_NAME" in
    prod) DEFAULT_HOST="43.139.53.121" ;;
    *)    DEFAULT_HOST="8.138.118.28" ;;
esac

echo
echo "目标服务器候选（禁止 localhost，AGENTS.md 铁律 6）:"
echo "  1) 8.138.118.28 (阿里云)"
echo "  2) 43.139.53.121 (腾讯云)"
echo "  3) 自定义（公网 IP 或域名）"
read -p "选择 [1-3, 默认从 baseline=$DEFAULT_HOST]: " -r SRV_CHOICE
SRV_CHOICE="${SRV_CHOICE:-}"
case "$SRV_CHOICE" in
    "")  HOST="$DEFAULT_HOST" ;;
    1)   HOST="8.138.118.28" ;;
    2)   HOST="43.139.53.121" ;;
    3)   read -p "输入主机名/IP（禁 localhost）: " -r HOST ;;
    *)   die "非法选择" ;;
esac

if ! validate_host_not_local_init "$HOST"; then
    die "host='$HOST' 是本地地址，被拒绝。请填公网 IP 或域名（SERVER-CONFIG.md）。"
fi
log_ok "目标主机: $HOST"

# 4. DB 块构造（C 阶段：所有环境都规范化，不仅 prod；DB 服务器分离）
# ----------------------------------------------------------------
# 4.1 询问 DB 服务器位置
#     - local: 用 environments.<env>.database_host 默认值（通常 localhost）
#     - remote: 用户输入 host:port，覆盖到 apps.json.env_config.<env>.database
# ----------------------------------------------------------------
DB_BLOCK=""
DEFAULT_DB_HOST="$(jq -r --arg e "$ENV_NAME" '.environments[$e].database_host // "localhost"' "$ENVS_JSON")"
DEFAULT_DB_PORT="$(jq -r --arg e "$ENV_NAME" '.environments[$e].database_port // 5432' "$ENVS_JSON")"

echo
echo "DB 服务器候选 ($APP_ID@$ENV_NAME):"
echo "  1) local (environments.$ENV_NAME 默认 $DEFAULT_DB_HOST:$DEFAULT_DB_PORT)"
echo "  2) 自定义远程 (输入 host:port)"
read -p "选择 DB 服务器 [1-2, 默认 1]: " -r DB_SRV_CHOICE
DB_SRV_CHOICE="${DB_SRV_CHOICE:-1}"
case "$DB_SRV_CHOICE" in
    1) DB_HOST="$DEFAULT_DB_HOST"; DB_PORT="$DEFAULT_DB_PORT" ;;
    2)
        read -p "输入 DB host（禁 localhost）: " -r DB_HOST
        read -p "输入 DB port [5432]: " -r DB_PORT
        DB_PORT="${DB_PORT:-5432}"
        ;;
    *) die "非法选择" ;;
esac
if ! validate_host_not_local_init "$DB_HOST"; then
    die "DB host='$DB_HOST' 是本地地址，被拒绝。请填公网 IP / 内网业务地址。"
fi
log_ok "DB 服务器: $DB_HOST:$DB_PORT"

# 4.2 DB 名/用户名硬约束: <app_id>_<env>
# 检测同名 DB 是否已存在（仅 local 时能查）
DB_NAME="$EXPECTED_DB_NAME"
DB_USER="$DB_NAME"
DB_EXISTS="unknown"
if [ "$DB_HOST" = "localhost" ] || [ "$DB_HOST" = "127.0.0.1" ]; then
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q '^1$'; then
        DB_EXISTS="yes"
    else
        DB_EXISTS="no"
    fi
fi

if [ "$DB_EXISTS" = "yes" ]; then
    if [ "$ENV_NAME" = "prod" ]; then
        log_warn "prod 数据库 $DB_NAME 已存在（红线：禁止 drop / 重建）"
        read -p "使用现有库？(Y/n): " -r
        if [[ -n "$REPLY" ]] && [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            die "用户取消"
        fi
        log_warn "使用现有 prod 库: $DB_NAME（密码字段需用户手工填到 apps.json）"
    else
        log_err "$ENV_NAME 数据库 $DB_NAME 已存在！"
        log_err "按 DB-DEPLOY-INTEGRATION.md 规范，非 prod 环境禁止复用同名库"
        log_err "请先手工 drop: sudo -u postgres psql -c \"DROP DATABASE $DB_NAME; DROP USER IF EXISTS $DB_USER;\""
        log_err "或将该 $ENV_NAME 配到其他 app/code"
        exit 1
    fi
fi

# 4.3 询问 DB 管理员账号（用于 CREATE DATABASE / USER）
DB_ADMIN="postgres"
if [ "$DB_HOST" != "localhost" ] && [ "$DB_HOST" != "127.0.0.1" ]; then
    read -p "远程 DB 管理员账号 [postgres]: " -r DB_ADMIN_IN
    DB_ADMIN="${DB_ADMIN_IN:-postgres}"
fi

# 4.4 生成强密码
DB_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 || echo "auto_$(date +%s)")"

log_warn "数据库配置:"
echo "  type:     postgresql"
echo "  host:     $DB_HOST"
echo "  port:     $DB_PORT"
echo "  database: $DB_NAME"
echo "  username: $DB_USER"
echo "  password: $DB_PASS"
echo "  admin:    $DB_ADMIN（用于建库；不写入 apps.json）"

read -p "是否写入 apps.json.env_config.$ENV_NAME.database？(Y/n): " -r
if [[ -z "$REPLY" ]] || [[ "$REPLY" =~ ^[Yy]$ ]]; then
    DB_BLOCK="{
      \"type\": \"postgresql\",
      \"host\": \"$DB_HOST\",
      \"port\": $DB_PORT,
      \"database\": \"$DB_NAME\",
      \"username\": \"$DB_USER\",
      \"password\": \"$DB_PASS\"
    }"
    log_ok "DB block 已构造"
fi

# 5a. 写 environments.json：apps.<app_id> = {port, pm2_name}
log "写入 environments.json"
PM2_NAME="${ENV_NAME}-${APP_ID}"
TMP_ENV="$(mktemp)"
jq --arg env "$ENV_NAME" --arg app "$APP_ID" --argjson port "$PORT" --arg pm2 "$PM2_NAME" \
   '.environments[$env].apps[$app] = {port: $port, pm2_name: $pm2}' \
   "$ENVS_JSON" > "$TMP_ENV" && mv "$TMP_ENV" "$ENVS_JSON"
log_ok "environments.json: $ENV_NAME.apps.$APP_ID = {port:$PORT, pm2_name:$PM2_NAME}"

# 5b. 写 apps.json：env_config.<env>（C 阶段：所有环境都写 database）
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
  1. 数据库会在首次 deploy.sh 探测到 missing 时自动建库 + migrate + 种子
     （要求 admin 账号 $DB_ADMIN 在 $DB_HOST 有 CREATE DATABASE/USER 权限）
     如想提前手工建：
       sudo -u postgres psql -c "CREATE USER $DB_USER WITH ENCRYPTED PASSWORD '<见 apps.json>';"
       sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
  2. 推送代码到对应分支
  3. 跑部署: bash $SKILL_DIR/scripts/deploy.sh $ENV_NAME $APP_ID [--version vX.Y.Z]

═══════════════════════════════════════════════════════
DONE
