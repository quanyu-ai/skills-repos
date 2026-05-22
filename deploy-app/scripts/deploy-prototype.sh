#!/bin/bash
# deploy-prototype.sh - 原型部署专门化脚本
# 用法: ./deploy-prototype.sh <app> [--skip-build] [--dry-run]
# 特点: 专门为原型部署优化，快速响应，轻量级部署

set -euo pipefail

# ============================================================
# 0. 基础变量
# ============================================================
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments-prototype.json"
DEPLOY_LOG="$SKILL_DIR/../../knowledge-repos/management/DEPLOY-LOG.md"

# 颜色
C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'

log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }
die()     { log_err "$*"; exit 1; }

# ============================================================
# 1. 参数解析
# ============================================================
usage() {
    cat <<USAGE
Usage: $(basename "$0") <app> [--skip-build] [--dry-run]
  <app>             应用 key (apps.json 中定义)
  --skip-build      跳过构建步骤
  --dry-run         只打印操作，不实际执行
USAGE
    exit 1
}

APP_KEY="${1:-}"
[ -z "$APP_KEY" ] && usage
shift 1 || true

SKIP_BUILD="false"
DRY_RUN="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build)   SKIP_BUILD="true"; shift ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        -h|--help)      usage ;;
        *)              die "未知参数: $1" ;;
    esac
done

ENV_NAME="proto"

# ============================================================
# 1.2 工具函数
# ============================================================
_app_get() {
    local key="$1"; local path="$2"
    # 先尝试读取环境特定的配置（env_config.<ENV_NAME>）
    local env_val=$(jq -r --arg k "$key" --arg e "$ENV_NAME" ".apps[\$k].env_config[\$e]${path} // empty" "$APPS_JSON")
    if [ -n "$env_val" ] && [ "$env_val" != "null" ]; then
        echo "$env_val"
    else
        # 如果环境特定配置不存在，则返回全局配置
        jq -r --arg k "$key" ".apps[\$k]${path} // empty" "$APPS_JSON"
    fi
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

# ============================================================
# 1.5 D1: 配置分层 - 加载 environments.local.json 覆盖
# ============================================================
LOCAL_ENVS_JSON="$CONFIG_DIR/environments.local.json"
if [ -f "$LOCAL_ENVS_JSON" ]; then
    log "Step 0.5: 检测到 environments.local.json, deep merge 覆盖"
    MERGED_JSON="$(jq -s '.[0] * .[1]' "$ENVS_JSON" "$LOCAL_ENVS_JSON")" \
        || die "environments.local.json merge 失败，请检查 JSON 格式"
    ENVS_JSON_MERGED="$(mktemp -t envs-merged-XXXXXX.json)"
    echo "$MERGED_JSON" > "$ENVS_JSON_MERGED"
    ENVS_JSON="$ENVS_JSON_MERGED"
    log_ok "配置合并完成 (local override applied)"
fi

# ============================================================
# 2. D1: 部署锁 (flock)
# ============================================================
LOCK_DIR="/var/lib/openclaw/deploy-locks"
LOCK_FILE="$LOCK_DIR/$APP_KEY.lock"
mkdir -p "$LOCK_DIR"

exec 9<> "$LOCK_FILE"
if ! flock -n 9; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | head -1 || echo "unknown")
    die "部署锁冲突: app=$APP_KEY 已被 PID=$LOCK_PID 持有锁（$LOCK_FILE）"
fi
echo "$$" > "$LOCK_FILE"
log_ok "部署锁已获取: $LOCK_FILE (PID=$$)"

cleanup_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}
trap cleanup_lock EXIT

# ============================================================
# 3. 自检兜底
# ============================================================
log "Step 1/8: 跑 doctor.sh 自检"
if ! bash "$SCRIPTS_DIR/doctor.sh" > /tmp/deploy-doctor.log 2>&1; then
    cat /tmp/deploy-doctor.log
    die "doctor 未 READY，停止部署。请按 setup.md 处理。"
fi
log_ok "doctor READY"

# ============================================================
# 3. 工具函数 (_ssh / _local)
# ============================================================
_ssh() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] ssh -i $SSH_KEY_EXPANDED $SSH_USER@$HOST '$*'"
        return 0
    fi
    ssh -i "$SSH_KEY_EXPANDED" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "$SSH_USER@$HOST" "$@"
}

_local() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] (local) $*"
        return 0
    fi
    bash -c "$*"
}

# ============================================================
# 4. 读 apps.json
# ============================================================
log "Step 2/8: 读 apps.json -> app=$APP_KEY"
APP_EXISTS="$(jq -r --arg k "$APP_KEY" '.apps | has($k)' "$APPS_JSON")"
[ "$APP_EXISTS" = "true" ] || die "apps.json 里没有 app=$APP_KEY"

APP_DISPLAY="$(_app_get "$APP_KEY" ".display_name")"
APP_PATH="$(_app_get "$APP_KEY" ".project_path")"
APP_BUILD="$(_app_get "$APP_KEY" ".build_cmd")"
APP_START="$(_app_get "$APP_KEY" ".start_cmd")"
APP_HEALTH="$(_app_get "$APP_KEY" ".health_path")"
APP_FRAMEWORK="$(_app_get "$APP_KEY" ".framework")"
APP_MONO_ROOT="$(_app_get "$APP_KEY" ".monorepo.root")"
APP_MONO_WS="$(_app_get "$APP_KEY" ".monorepo.workspace")"

[ -n "$APP_PATH" ] || die "apps.json[$APP_KEY].project_path 为空"
log_ok "app: $APP_DISPLAY ($APP_FRAMEWORK)"

# ============================================================
# 5. 读 environments-prototype.json
# ============================================================
log "Step 3/8: 读 environments-prototype.json -> env=$ENV_NAME"
ENV_EXISTS="$(jq -r --arg e "$ENV_NAME" '.environments | has($e)' "$ENVS_JSON")"
[ "$ENV_EXISTS" = "true" ] || die "environments-prototype.json 里没有 env=$ENV_NAME"

ENVAPP_PORT="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".port")"
ENVAPP_PM2_NAME="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".pm2_name")"
[ -n "$ENVAPP_PORT" ] || die "环境 $ENV_NAME 未声明 app=$APP_KEY"

HOST="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".host")"
[ -n "$HOST" ] || HOST="$(_env_get "$ENV_NAME" ".host")"
[ -n "$HOST" ] || HOST="$(_env_get "$ENV_NAME" ".default_host")"
[ -n "$HOST" ] || die "环境 $ENV_NAME 无 host 配置"

SSH_USER="$(_env_get "$ENV_NAME" ".ssh_user")"
SSH_KEY_RAW="$(_env_get "$ENV_NAME" ".ssh_key")"
DEPLOY_MODE="$(_env_get "$ENV_NAME" ".deploy_mode")"
DEPLOY_ROOT="$(_env_get "$ENV_NAME" ".deploy_root")"
RELEASES_TO_KEEP="$(_env_get "$ENV_NAME" ".releases_to_keep")"
USE_HTTPS_COOKIES="$(_env_get "$ENV_NAME" ".use_https_cookies")"
NODE_ENV_VAL="$(_env_get "$ENV_NAME" ".node_env")"
[ -n "$NODE_ENV_VAL" ] || NODE_ENV_VAL="development"
[ -n "$USE_HTTPS_COOKIES" ] || USE_HTTPS_COOKIES="false"
[ -n "$RELEASES_TO_KEEP" ] || RELEASES_TO_KEEP="3"

USE_RELEASES="false"
if [ -n "$DEPLOY_ROOT" ]; then
    USE_RELEASES="true"
    log_ok "版本化部署: deploy_root=$DEPLOY_ROOT, releases_to_keep=$RELEASES_TO_KEEP"
fi

SSH_KEY_EXPANDED="${SSH_KEY_RAW/#\~/$HOME}"

log_ok "env: host=$HOST user=$SSH_USER mode=$DEPLOY_MODE port=$ENVAPP_PORT"
log_ok "cookie: USE_HTTPS_COOKIES=$USE_HTTPS_COOKIES, NODE_ENV=$NODE_ENV_VAL"

# ============================================================
# 6. 预检查
# ============================================================
log "Step 4/8: 预检查 SSH / 项目路径"

if [ "$DRY_RUN" != "true" ]; then
    ssh -i "$SSH_KEY_EXPANDED" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$SSH_USER@$HOST" true 2>/dev/null \
        || die "SSH 连通失败: $SSH_USER@$HOST (key=$SSH_KEY_EXPANDED)"
    log_ok "SSH ok"

    [ -d "$APP_PATH" ] || die "项目路径不存在: $APP_PATH"
    log_ok "项目路径存在: $APP_PATH"
else
    log_warn "dry-run: 跳过 SSH 实际握手与目录检查"
fi

# ============================================================
# 7. 拉代码 (针对原型项目简化)
# ============================================================
log "Step 5/8: git 拉代码"

if [ -n "$APP_MONO_ROOT" ]; then
    GIT_DIR="$APP_MONO_ROOT"
else
    GIT_DIR="$APP_PATH"
fi

GIT_SHA="nogit-$(date +%Y%m%d%H%M%S)"
if [ -d "$GIT_DIR/.git" ]; then
    (cd "$GIT_DIR" && git fetch --all --tags --quiet)
    (cd "$GIT_DIR" && git pull --ff-only)
    GIT_SHA="$(cd "$GIT_DIR" && git rev-parse --short HEAD)"
    log_ok "代码版本: $GIT_SHA"
else
    log_warn "$APP_PATH 不是 git 仓库，跳过 git 操作"
fi

# ============================================================
# 8. 构建 (根据框架类型)
# ============================================================
if [ "$SKIP_BUILD" != "true" ] && [ -n "$APP_BUILD" ]; then
    log "Step 6/8: 构建 ($APP_BUILD)"

    if [ -n "$APP_MONO_ROOT" ]; then
        BUILD_DIR="$APP_MONO_ROOT"
        if [ -n "$APP_MONO_WS" ]; then
            _local "cd \"$BUILD_DIR\" && $APP_BUILD --filter \"${APP_MONO_WS}\""
        else
            _local "cd \"$BUILD_DIR\" && $APP_BUILD"
        fi
    else
        _local "cd \"$APP_PATH\" && $APP_BUILD"
    fi

    log_ok "构建完成"
elif [ "$APP_FRAMEWORK" = "static" ]; then
    log_warn "Step 6/8: framework=static, 跳过构建"
else
    log_warn "Step 6/8: 未配置 build_cmd 或 --skip-build，跳过构建"
fi

# ============================================================
# 9. 版本化部署 (Phase 3)
# ============================================================
if [ "$USE_RELEASES" = "true" ]; then
    log "Step 7/8: 版本管理 (releases/<sha>)"
    DEPLOY_BASE="$DEPLOY_ROOT/$APP_KEY"
    mkdir -p "$DEPLOY_BASE/releases" "$DEPLOY_BASE/../shared/node_modules"

    RELEASE_DIR="$DEPLOY_BASE/releases/$GIT_SHA"
    [ -d "$RELEASE_DIR" ] || mkdir -p "$RELEASE_DIR"

    # 复制项目文件到 release 目录，排除不需要的
    EXCLUDE_PATTERNS=(".git" "node_modules" "*.log" "server.js" ".DS_Store")
    EXCLUDE_ARGS=""
    for pat in "${EXCLUDE_PATTERNS[@]}"; do
        EXCLUDE_ARGS+="--exclude '$pat' "
    done

    # 处理静态站点和其他项目
    if [ "$APP_FRAMEWORK" = "static" ]; then
        log "复制静态站点 -> $RELEASE_DIR"
        _local "rsync -avz $EXCLUDE_ARGS '$APP_PATH/' '$RELEASE_DIR/' || true"
        # 静态站点不需要 node_modules，但需要创建符号链接
        if [ -d "$APP_PATH/node_modules" ]; then
            ln -sfn "$APP_PATH/node_modules" "$RELEASE_DIR/node_modules"
            ln -sfn "$APP_PATH/node_modules" "$DEPLOY_BASE/../shared/node_modules/$APP_KEY"
        fi
    else
        log "复制项目 -> $RELEASE_DIR"
        _local "rsync -avz $EXCLUDE_ARGS '$APP_PATH/' '$RELEASE_DIR/' || true"
        if [ -d "$APP_PATH/node_modules" ]; then
            ln -sfn "$APP_PATH/node_modules" "$RELEASE_DIR/node_modules"
            ln -sfn "$APP_PATH/node_modules" "$DEPLOY_BASE/../shared/node_modules/$APP_KEY"
        fi
    fi

    # 处理 monorepo
    if [ -n "$APP_MONO_WS" ]; then
        log "处理 monorepo: $APP_MONO_WS -> $RELEASE_DIR"
        if [ -d "$APP_PATH/.next" ]; then
            _local "cp -a '$APP_PATH/.next' '$RELEASE_DIR/.next' || true"
        fi
    fi

    # 确定当前运行的版本 (用于判断是否需要 reload)
    PREVIOUS_SHA=""
    if [ -L "$DEPLOY_BASE/current" ] && [ -d "$DEPLOY_BASE/current" ]; then
        PREVIOUS_SHA=$(basename "$(readlink "$DEPLOY_BASE/current")")
        log_ok "上一个版本: $PREVIOUS_SHA"
    fi

    # 原子切换 symlink
    ln -sfn "$RELEASE_DIR" "$DEPLOY_BASE/current"
    log_ok "本次版本: $GIT_SHA -> $RELEASE_DIR"
else
    log_warn "Step 7/8: 未配置 deploy_root，跳过版本化部署"
    DEPLOY_BASE="$APP_PATH"
fi

# ============================================================
# 10. 部署 (mode=pm2)
# ============================================================
log "Step 8/8: 部署 (mode=pm2, cwd=$DEPLOY_BASE/current)"

# 生成 PM2 配置文件
ECO_TMP="$(mktemp -t ecosystem-${ENV_NAME}-${APP_KEY}-XXXXXX.config.cjs)"
cat > "$ECO_TMP" <<EOF
// AUTO-GENERATED by deploy-app skill, DO NOT EDIT
// app=${APP_KEY} env=${ENV_NAME} pm2_name=${ENVAPP_PM2_NAME} port=${ENVAPP_PORT}
module.exports = {
  apps: [{
    name: '${ENVAPP_PM2_NAME}',
    script: '/usr/bin/npx',
    args: '-y serve@14 -l tcp://0.0.0.0:${ENVAPP_PORT} -s .',
    cwd: '${DEPLOY_BASE}/