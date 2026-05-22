#!/bin/bash
# rollback.sh - 版本回滚脚本 (Phase 3)
# 用法: ./rollback.sh <env> <app>
#
# 核心逻辑：
#   1. 读取 current symlink 指向的当前版本 sha
#   2. 在 releases/ 下找到上一个版本
#   3. 原子切换 current symlink
#   4. 重新生成 ecosystem.config.cjs（cwd 指向 current）
#   5. PM2 reload
#   6. 健康检查
#
# 如果环境未配置 deploy_root（版本化部署），回退到 Phase 2 行为：
#   直接 pm2 reload（无法真正回滚代码版本）

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments.json"
DEPLOY_LOG="$SKILL_DIR/../../knowledge-repos/management/DEPLOY-LOG.md"

C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'

log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }

usage() {
    echo "Usage: $(basename "$0") <env> <app>" >&2
    exit 2
}

ENV_NAME="${1:-}"
APP_KEY="${2:-}"
[ -z "$ENV_NAME" ] || [ -z "$APP_KEY" ] && usage

log "rollback: env=$ENV_NAME app=$APP_KEY"

# ============================================================
# 1. 读配置（复用 deploy.sh 的 _app_get / _env_get / _envapp_get 模式）
# ============================================================
_app_get() {
    local key="$1"; local path="$2"
    jq -r --arg k "$key" ".apps[\$k]${path} // empty" "$APPS_JSON"
}
_env_get() {
    local env="$1"; local path="$2"
    jq -r --arg e "$env" ".environments[\$e]${path} // empty" "$ENVS_JSON"
}
_envapp_get() {
    local env="$1"; local app="$2"; local path="$3"
    jq -r --arg e "$env" --arg a "$app" \
        ".environments[\$e].apps[\$a]${path} // empty" "$ENVS_JSON"
}

# App 配置
APP_FRAMEWORK="$(_app_get "$APP_KEY" ".framework")"
APP_PATH="$(_app_get "$APP_KEY" ".project_path")"
APP_START="$(_app_get "$APP_KEY" ".start_cmd")"
APP_HEALTH="$(_app_get "$APP_KEY" ".health_path")"
APP_MONO_ROOT="$(_app_get "$APP_KEY" ".monorepo.root")"

# 环境配置
ENVAPP_PORT="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".port")"
ENVAPP_PM2_NAME="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".pm2_name")"
[ -n "$ENVAPP_PM2_NAME" ] || { log_err "找不到 pm2_name"; echo "ROLLBACK_FAILED"; exit 1; }

HOST="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".host")"
[ -n "$HOST" ] || HOST="$(_env_get "$ENV_NAME" ".host")"
[ -n "$HOST" ] || HOST="$(_env_get "$ENV_NAME" ".default_host")"
[ -n "$HOST" ] || { log_err "找不到 host"; echo "ROLLBACK_FAILED"; exit 1; }

SSH_USER="$(_env_get "$ENV_NAME" ".ssh_user")"
SSH_KEY_RAW="$(_env_get "$ENV_NAME" ".ssh_key")"
SSH_KEY_EXPANDED="${SSH_KEY_RAW/#\~/$HOME}"
DEPLOY_ROOT="$(_env_get "$ENV_NAME" ".deploy_root")"
USE_HTTPS_COOKIES="$(_env_get "$ENV_NAME" ".use_https_cookies")"
NODE_ENV_VAL="$(_env_get "$ENV_NAME" ".node_env")"
[ -n "$NODE_ENV_VAL" ] || NODE_ENV_VAL="production"
[ -n "$USE_HTTPS_COOKIES" ] || USE_HTTPS_COOKIES="false"

_ssh() {
    ssh -i "$SSH_KEY_EXPANDED" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "$SSH_USER@$HOST" "$@"
}

# ============================================================
# 2. 分支：是否有版本化部署
# ============================================================
if [ -z "$DEPLOY_ROOT" ]; then
    # Phase 2 回退：只能 pm2 reload，无法回滚代码
    log_warn "未配置 deploy_root，无法版本化回滚"
    log_warn "执行 Phase 2 兼容回滚: pm2 reload $ENVAPP_PM2_NAME"
    _ssh "pm2 reload '$ENVAPP_PM2_NAME'" \
        || { log_err "pm2 reload 失败"; echo "ROLLBACK_FAILED"; exit 1; }

    sleep 5
    if bash "$SCRIPTS_DIR/verify.sh" "$ENV_NAME" "$APP_KEY"; then
        log_ok "rollback (兼容模式) 成功"
        echo "ROLLED_BACK"
        exit 0
    else
        log_err "rollback 后仍 unhealthy"
        echo "ROLLBACK_FAILED"
        exit 1
    fi
fi

# ============================================================
# 3. Phase 3：真正的版本回滚
# ============================================================
APP_DEPLOY_DIR="$DEPLOY_ROOT/$APP_KEY"
CURRENT_LINK="$APP_DEPLOY_DIR/current"
RELEASES_DIR="$APP_DEPLOY_DIR/releases"

# 3.1 获取当前版本
if [ ! -L "$CURRENT_LINK" ]; then
    log_err "current symlink 不存在，无法确定当前版本"
    echo "ROLLBACK_FAILED"
    exit 1
fi
CURRENT_SHA="$(basename "$(readlink "$CURRENT_LINK")")"
log "当前版本: $CURRENT_SHA"

# 3.2 找上一个版本（按 mtime 倒序，排除当前）
if [ ! -d "$RELEASES_DIR" ]; then
    log_err "releases 目录不存在: $RELEASES_DIR"
    echo "ROLLBACK_FAILED"
    exit 1
fi

PREV_SHA=""
while IFS= read -r rel; do
    if [ "$rel" != "$CURRENT_SHA" ]; then
        PREV_SHA="$rel"
        break
    fi
done < <(ls -1t "$RELEASES_DIR" 2>/dev/null)

if [ -z "$PREV_SHA" ]; then
    log_err "没有可回滚的旧版本（releases/ 下只有当前版本或为空）"
    echo "ROLLBACK_FAILED"
    exit 1
fi

log_ok "回滚目标: $CURRENT_SHA → $PREV_SHA"

# 3.3 验证目标版本目录完整性
TARGET_DIR="$RELEASES_DIR/$PREV_SHA"
if [ ! -d "$TARGET_DIR" ]; then
    log_err "目标版本目录不存在: $TARGET_DIR"
    echo "ROLLBACK_FAILED"
    exit 1
fi
case "$APP_FRAMEWORK" in
    nextjs)
        if [ ! -d "$TARGET_DIR/.next" ]; then
            log_err "目标版本缺少 .next 目录: $TARGET_DIR"
            echo "ROLLBACK_FAILED"
            exit 1
        fi
        ;;
esac
log_ok "目标版本目录完整: $TARGET_DIR"

# 3.4 生成新的 ecosystem.config.cjs（cwd 指向 current）
case "$APP_FRAMEWORK" in
    nextjs)
        PM2_SCRIPT="node_modules/next/dist/bin/next"
        PM2_ARGS="start -H 0.0.0.0 -p $ENVAPP_PORT"
        ;;
    express|nestjs|node)
        PM2_SCRIPT="$(echo "$APP_START" | awk '{print $1}')"
        PM2_ARGS="$(echo "$APP_START" | cut -d' ' -f2-)"
        [ "$PM2_SCRIPT" = "$PM2_ARGS" ] && PM2_ARGS=""
        ;;
    *)
        log_err "未支持的 framework=$APP_FRAMEWORK"
        echo "ROLLBACK_FAILED"
        exit 1
        ;;
esac

case "$ENV_NAME" in
    prod) PM2_INSTANCES="max"; PM2_MEM="512M" ;;
    *)    PM2_INSTANCES="1";   PM2_MEM="256M" ;;
esac

ECO_TMP="$(mktemp -t ecosystem-rollback-${ENVAPP_PM2_NAME}-XXXXXX.config.cjs)"
cat > "$ECO_TMP" <<ECO
// AUTO-GENERATED by rollback.sh, DO NOT EDIT
// app=$APP_KEY env=$ENV_NAME pm2_name=$ENVAPP_PM2_NAME port=$ENVAPP_PORT
module.exports = {
  apps: [{
    name: '$ENVAPP_PM2_NAME',
    script: '$PM2_SCRIPT',
    args: '$PM2_ARGS',
    cwd: '$CURRENT_LINK',
    instances: '$PM2_INSTANCES' === 'max' ? 'max' : 1,
    exec_mode: '$PM2_INSTANCES' === 'max' ? 'cluster' : 'fork',
    max_memory_restart: '$PM2_MEM',
    autorestart: true,
    watch: false,
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    env: {
      NODE_ENV: '$NODE_ENV_VAL',
      USE_HTTPS_COOKIES: '$USE_HTTPS_COOKIES',
      HOST: '0.0.0.0',
      PORT: '$ENVAPP_PORT',
    },
  }]
};
ECO

# 同时更新目标版本目录里的 ecosystem
cp -a "$ECO_TMP" "$TARGET_DIR/ecosystem.config.cjs"

# scp 到远程
REMOTE_ECO="/tmp/ecosystem-rollback-${ENVAPP_PM2_NAME}.config.cjs"
scp -i "$SSH_KEY_EXPANDED" \
    -o StrictHostKeyChecking=no \
    "$ECO_TMP" "$SSH_USER@$HOST:$REMOTE_ECO" >/dev/null

rm -f "$ECO_TMP" 2>/dev/null || true

# 3.5 原子切换 current symlink
log "切换 current symlink: $CURRENT_SHA → $PREV_SHA"
ln -sfn "$TARGET_DIR" "$CURRENT_LINK"

# 验证切换成功
ACTUAL_SHA="$(basename "$(readlink "$CURRENT_LINK")")"
if [ "$ACTUAL_SHA" != "$PREV_SHA" ]; then
    log_err "symlink 切换失败: expected=$PREV_SHA actual=$ACTUAL_SHA"
    echo "ROLLBACK_FAILED"
    exit 1
fi
log_ok "current symlink 已切换: $PREV_SHA"

# 3.6 PM2 reload
log "PM2 reload: $ENVAPP_PM2_NAME (cwd=$CURRENT_LINK)"
PM2_SCRIPT_REMOTE=$(cat <<RSCRIPT
DESIRED_CWD='$CURRENT_LINK'
if pm2 describe '$ENVAPP_PM2_NAME' >/dev/null 2>&1; then
    CURRENT_CWD=\$(pm2 jlist 2>/dev/null | node -e "let d=JSON.parse(require('fs').readFileSync(0,'utf8'));let a=d.find(x=>x.name==='$ENVAPP_PM2_NAME');process.stdout.write((a&&a.pm2_env&&a.pm2_env.pm_cwd)||'')" 2>/dev/null || echo '')
    if [ "\$CURRENT_CWD" = "\$DESIRED_CWD" ]; then
        echo "[rollback] cwd unchanged (symlink target swapped), reloading"
        pm2 reload '$ENVAPP_PM2_NAME' --update-env
    else
        echo "[rollback] cwd changed: \$CURRENT_CWD -> \$DESIRED_CWD; recreating PM2 entry"
        pm2 delete '$ENVAPP_PM2_NAME' || true
        pm2 start '$REMOTE_ECO' --only '$ENVAPP_PM2_NAME'
    fi
else
    pm2 start '$REMOTE_ECO' --only '$ENVAPP_PM2_NAME'
fi
RSCRIPT
)
_ssh bash -s <<<"$PM2_SCRIPT_REMOTE"
_ssh "pm2 save >/dev/null 2>&1 || true"

# 3.7 等待 + 健康检查
log "等待 5 秒后健康检查"
sleep 5

if bash "$SCRIPTS_DIR/verify.sh" "$ENV_NAME" "$APP_KEY"; then
    log_ok "回滚成功: $CURRENT_SHA → $PREV_SHA"

    # 写回滚日志
    NOW_STR="$(date '+%Y-%m-%d %H:%M:%S')"
    LOG_LINE="| $NOW_STR | $ENV_NAME | $APP_KEY | rollback | $CURRENT_SHA→$PREV_SHA | ROLLED_BACK | - |"
    if [ -s "$DEPLOY_LOG" ]; then
        echo "$LOG_LINE" >> "$DEPLOY_LOG"
    fi

    echo "ROLLED_BACK"
    exit 0
else
    log_err "回滚失败: $PREV_SHA 也不健康"

    # 写失败日志
    NOW_STR="$(date '+%Y-%m-%d %H:%M:%S')"
    LOG_LINE="| $NOW_STR | $ENV_NAME | $APP_KEY | rollback | $CURRENT_SHA→$PREV_SHA | ROLLBACK_FAILED | - |"
    if [ -s "$DEPLOY_LOG" ]; then
        echo "$LOG_LINE" >> "$DEPLOY_LOG"
    fi

    echo "ROLLBACK_FAILED"
    exit 1
fi
