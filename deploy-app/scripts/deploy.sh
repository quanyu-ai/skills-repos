#!/bin/bash
# deploy.sh - Phase 2 主部署脚本
# 用法: ./deploy.sh <env> <app> [--version <git_sha_or_tag>] [--approved-by <user>] [--skip-build] [--skip-db] [--db-only] [--dry-run]
#
# 严格按 deployment-standard.md §2.0.1-§2.0.4 执行:
#   * Next.js 必须 -H 0.0.0.0
#   * Cookie Secure 标志走 USE_HTTPS_COOKIES，禁止用 NODE_ENV 判断
#   * PM2 使用 next start，不要 standalone/server.js
#   * 演示环境 单实例 256M / 生产 max + 512M
#
# D1 增强: 配置分层 (environments.local.json deep merge) + 部署锁 (flock)
# D2 增强: prod 环境门禁 L3 (--version / 语义化 tag / tag 存在 / --approved-by / demo 先行)

set -euo pipefail

# ============================================================
# 0. 基础变量
# ============================================================
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"
ENVS_JSON="$CONFIG_DIR/environments.json"
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
Usage: $(basename "$0") <env> <app> [--version <ref>] [--approved-by <user>] [--skip-build] [--skip-db] [--db-only] [--dry-run] [--allow-localhost]
  <env>             环境名: proto | test | demo | prod
  <app>             应用 key (apps.json 中定义)
  --version <ref>   指定 git tag/sha (默认: 当前默认分支 HEAD)
  --approved-by <user>  审批人 (prod 必需)
  --skip-build      跳过构建步骤
  --skip-db         跳过 DB 联动（应急逃生口；将在 DEPLOY-LOG.md notes 标注）
  --db-only         只跑 DB 联动，不部署代码（调试用）
  --dry-run         只打印操作，不实际执行
  --allow-localhost 显式允许 host=localhost/127.0.0.1（只用于应急，违反 AGENTS.md 铁律 6）
USAGE
    exit 1
}

ENV_NAME="${1:-}"
APP_KEY="${2:-}"
[ -z "$ENV_NAME" ] || [ -z "$APP_KEY" ] && usage
shift 2 || true

VERSION_REF=""
APPROVED_BY=""
SKIP_BUILD="false"
SKIP_DB="false"
DB_ONLY="false"
DRY_RUN="false"
ALLOW_LOCALHOST="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)         VERSION_REF="${2:-}"; shift 2 ;;
        --approved-by)     APPROVED_BY="${2:-}"; shift 2 ;;
        --skip-build)      SKIP_BUILD="true"; shift ;;
        --skip-db)         SKIP_DB="true"; shift ;;
        --db-only)         DB_ONLY="true"; shift ;;
        --dry-run)         DRY_RUN="true"; shift ;;
        --allow-localhost) ALLOW_LOCALHOST="true"; shift ;;
        -h|--help)         usage ;;
        *)                 die "未知参数: $1" ;;
    esac
done

if [ "$SKIP_DB" = "true" ] && [ "$DB_ONLY" = "true" ]; then
    die "--skip-db 与 --db-only 互斥"
fi

# ============================================================
# 1.2 工具函数（提前到 D1/D2 之前，供门禁/锁使用）
# ============================================================
_app_get() {
    local key="$1"; local path="$2"
    # 先尝试读取环境特定的配置（env_config.<ENV_NAME>）
    local env_val=$(jq -r --arg k "$key" --arg e "$ENV_NAME" ".apps[\$k].env_config[\$e]${path} // empty" "$APPS_JSON")
    if [ -n "$env_val" ] && [ "$env_val" != "null" ]; then
        echo "$env_val"
        return
    fi

    # 仅当请求 .project_path 时，才尝试从 project_proto_path / project_code_path fallback。
    # 注意：project_proto_path / project_code_path 在 apps.json 里是字符串，对它再做 .build_cmd / .monorepo
    # 这类索引会产生 jq stderr 噪音；因此用 path == ".project_path" 作为前置门禁。
    if [ "$path" = ".project_path" ]; then
        if [ "$ENV_NAME" = "proto" ]; then
            local proto_path=$(jq -r --arg k "$key" ".apps[\$k].project_proto_path // empty" "$APPS_JSON")
            if [ -n "$proto_path" ] && [ "$proto_path" != "null" ]; then
                echo "$proto_path"
                return
            fi
        else
            local code_path=$(jq -r --arg k "$key" ".apps[\$k].project_code_path // empty" "$APPS_JSON")
            if [ -n "$code_path" ] && [ "$code_path" != "null" ]; then
                echo "$code_path"
                return
            fi
        fi
    fi

    # 兜底：直接从 app 顶层取（如 build_cmd / start_cmd / monorepo 等都在顶层）
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

# ============================================================
# 1.5 D1: 配置分层 - 加载 environments.local.json 覆盖
# ============================================================
LOCAL_ENVS_JSON="$CONFIG_DIR/environments.local.json"
if [ -f "$LOCAL_ENVS_JSON" ]; then
    log "Step 0.5: 检测到 environments.local.json, deep merge 覆盖"
    # deep merge: local 覆盖 base（jq 'deep merge' 语义：右覆盖左）
    MERGED_JSON="$(jq -s '.[0] * .[1]' "$ENVS_JSON" "$LOCAL_ENVS_JSON")" \
        || die "environments.local.json merge 失败，请检查 JSON 格式"
    # 写入临时文件让后续 _env_get 等函数照常读
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

# 获取 fd 9 用于 flock
exec 9<>"$LOCK_FILE"

if ! flock -n 9; then
    # 读取锁持有者的 PID（写锁时记录）
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | head -1 || echo "unknown")
    die "部署锁冲突: app=$APP_KEY 已被 PID=$LOCK_PID 持有锁（$LOCK_FILE），请等待或清理僵尸锁"
fi
# 记录当前 PID 到锁文件内容
echo "$$" > "$LOCK_FILE"
log_ok "部署锁已获取: $LOCK_FILE (PID=$$)"

# 退出时自动释放锁
cleanup_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}
trap cleanup_lock EXIT

# ============================================================
# 2.5 D2: prod 环境门禁 L3
# ============================================================
if [ "$ENV_NAME" = "prod" ]; then
    log "Step 0.75: prod 环境门禁 L3 检查"

    GATE_FAIL="false"

    # 门禁1: 必须传 --version
    if [ -z "$VERSION_REF" ]; then
        log_err "门禁1 失败: prod 部署必须指定 --version <tag>"
        GATE_FAIL="true"
    fi

    # 门禁2: 必须是 v*.*.* 语义化格式
    if [ -n "$VERSION_REF" ]; then
        if ! echo "$VERSION_REF" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+'; then
            log_err "门禁2 失败: --version 必须是语义化 tag (v*.*.*), 当前: $VERSION_REF"
            GATE_FAIL="true"
        fi
    fi

    # 门禁3: tag 必须真实存在 (git rev-parse)
    if [ -n "$VERSION_REF" ]; then
        APP_PATH_CHECK="$(_app_get "$APP_KEY" ".project_path")"
        # 确定 git 目录
        MONO_ROOT_CHECK="$(_app_get "$APP_KEY" ".monorepo.root")"
        if [ -n "$MONO_ROOT_CHECK" ]; then
            GIT_DIR_CHECK="$MONO_ROOT_CHECK"
        else
            GIT_DIR_CHECK="$APP_PATH_CHECK"
        fi

        if [ -d "$GIT_DIR_CHECK" ]; then
            if ! (cd "$GIT_DIR_CHECK" && git rev-parse "$VERSION_REF" >/dev/null 2>&1); then
                log_err "门禁3 失败: tag '$VERSION_REF' 在 git 仓库中不存在"
                GATE_FAIL="true"
            else
                log_ok "门禁3 通过: tag '$VERSION_REF' 存在"
            fi
        else
            log_warn "门禁3 跳过: 项目路径 $GIT_DIR_CHECK 不存在（无法验证 tag）"
        fi
    fi

    # 门禁4: 必须传 --approved-by
    if [ -z "$APPROVED_BY" ]; then
        log_err "门禁4 失败: prod 部署必须指定 --approved-by <user_id>"
        GATE_FAIL="true"
    else
        # 验证审批人身份
        case "$APPROVED_BY" in
            longge|龙哥|dengyunlong|ou_1acdf6c410088eb61c9a9c27b5102824)
                log_ok "门禁4 通过: 审批人=$APPROVED_BY"
                ;;
            *)
                log_err "门禁4 失败: --approved-by '$APPROVED_BY' 不是授权审批人 (允许: longge/龙哥/dengyunlong)"
                GATE_FAIL="true"
                ;;
        esac
    fi

    # 门禁5: 该版本必须在 demo 环境部署过 (grep DEPLOY-LOG.md)
    if [ -n "$VERSION_REF" ]; then
        if [ -f "$DEPLOY_LOG" ]; then
            # 匹配: | demo | <app_key> | <version> | 行的 status 为 SUCCESS
            if grep -qE "\| demo \| $APP_KEY \| ${VERSION_REF} \|.*\| SUCCESS \|" "$DEPLOY_LOG" 2>/dev/null; then
                log_ok "门禁5 通过: $VERSION_REF 已在 demo 环境成功部署"
            else
                log_err "门禁5 失败: $VERSION_REF 未在 demo 环境部署过（DEPLOY-LOG.md 无记录）"
                GATE_FAIL="true"
            fi
        else
            log_err "门禁5 失败: DEPLOY-LOG.md 不存在，无法验证 demo 先行部署"
            GATE_FAIL="true"
        fi
    fi

    if [ "$GATE_FAIL" = "true" ]; then
        log_err "prod 门禁未通过，部署被拒绝 (exit 2)"
        exit 2
    fi

    log_ok "prod 门禁 L3 全部通过 ✓"

    # 门禁6（VERSIONING.md）: package.json.version 必须 == tag（去 v 前缀）
    # 仅 prod 强制，与 D2 门禁 1~5 叠加
    if [ -n "$VERSION_REF" ]; then
        APP_PATH_PKG="$(_app_get "$APP_KEY" ".project_path")"
        # 优先查 project_path/package.json，再查 monorepo root
        PKG_FILE=""
        if [ -f "$APP_PATH_PKG/package.json" ]; then
            PKG_FILE="$APP_PATH_PKG/package.json"
        else
            MONO_ROOT_PKG="$(_app_get "$APP_KEY" ".monorepo.root")"
            [ -n "$MONO_ROOT_PKG" ] && [ -f "$MONO_ROOT_PKG/package.json" ] && PKG_FILE="$MONO_ROOT_PKG/package.json"
        fi
        if [ -z "$PKG_FILE" ]; then
            log_warn "门禁6 跳过：未找到 package.json (路径: $APP_PATH_PKG)"
        else
            PKG_VER="$(jq -r '.version // empty' "$PKG_FILE")"
            TAG_VER="${VERSION_REF#v}"
            if [ "$PKG_VER" != "$TAG_VER" ]; then
                log_err "门禁6 失败：package.json.version=$PKG_VER 与 tag=$VERSION_REF 不一致"
                log_err "请先跑：bash $SCRIPTS_DIR/release.sh $APP_KEY --explicit $VERSION_REF"
                log_err "参见：knowledge-repos/management/PRINCIPLES/VERSIONING.md"
                exit 2
            fi
            log_ok "门禁6 通过：package.json.version=$PKG_VER == tag=$VERSION_REF"
        fi
    fi
fi

# ============================================================
# 3. 自检兜底
# ============================================================
log "Step 1/10: 跑 doctor.sh 自检"
if ! bash "$SCRIPTS_DIR/doctor.sh" > /tmp/deploy-doctor.log 2>&1; then
    cat /tmp/deploy-doctor.log
    die "doctor 未 READY，停止部署。请按 setup.md 处理。"
fi
log_ok "doctor READY"

# ============================================================
# 3. 工具函数 (_ssh / _local) — 公用 _app_get/_env_get 已在 1.2 定义
# ============================================================
# 统一 SSH 封装
_ssh() {
    # 用法: _ssh "<cmd string>"
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] ssh -i $SSH_KEY_EXPANDED $SSH_USER@$HOST '$*'"
        return 0
    fi
    ssh -i "$SSH_KEY_EXPANDED" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "$SSH_USER@$HOST" "$@"
}

# 在本机执行命令（即"主控机"侧动作：git pull / pnpm build）
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
log "Step 2/10: 读 apps.json -> app=$APP_KEY"
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
# 2.5/10. Layer 1: 项目路径前置校验（强制，dry-run 也跑）
# ============================================================
log "Step 2.5/10: Layer 1 - 项目路径前置校验"
if [ ! -d "$APP_PATH" ]; then
    log_err "部署中止: $APP_DISPLAY 在 $ENV_NAME 环境的项目路径不存在"
    cat >&2 <<EOM
   期望路径: $APP_PATH
   配置位置: apps.json → ${APP_KEY}.env_config.${ENV_NAME}.project_path
            或 apps.json → ${APP_KEY}.project_code_path / project_proto_path
   可能原因:
     1. 原型/代码尚未创建（需要先生成）
     2. 路径配置错误（请检查 apps.json）
     3. 仓库未 clone（需要先 git clone）
   修复建议:
     - 检查 apps.json 中该 app 的路径配置
     - 或运行 \`bash skills/deploy-app/scripts/doctor.sh --check-apps\` 查看全局
EOM
    exit 1
fi
log_ok "项目路径存在: $APP_PATH"

# Layer 2: framework 与路径一致性校验（warn 不中止）
case "$APP_FRAMEWORK" in
    static)
        [ -f "$APP_PATH/index.html" ] || log_warn "framework=static 但目录无 index.html ($APP_PATH)"
        ;;
    nextjs)
        [ -f "$APP_PATH/package.json" ] || log_warn "framework=nextjs 但目录无 package.json ($APP_PATH)"
        ;;
    nestjs)
        [ -f "$APP_PATH/package.json" ] || log_warn "framework=nestjs 但目录无 package.json ($APP_PATH)"
        ;;
    express|node)
        [ -f "$APP_PATH/package.json" ] || log_warn "framework=$APP_FRAMEWORK 但目录无 package.json ($APP_PATH)"
        ;;
esac

# ============================================================
# 5. 读 environments.json
# ============================================================
log "Step 3/10: 读 environments.json -> env=$ENV_NAME"
ENV_EXISTS="$(jq -r --arg e "$ENV_NAME" '.environments | has($e)' "$ENVS_JSON")"
[ "$ENV_EXISTS" = "true" ] || die "environments.json 里没有 env=$ENV_NAME"

ENVAPP_PORT="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".port")"
ENVAPP_PM2_NAME="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".pm2_name")"
if [ -z "$ENVAPP_PORT" ]; then
    log_err "环境 $ENV_NAME 未声明 app=$APP_KEY"
    log_err "请先跑引导脚本初始化此应用的 $ENV_NAME 环境："
    log_err "  bash $SCRIPTS_DIR/init-deploy-target.sh $APP_KEY $ENV_NAME"
    log_err "会自动按公式 端口=env_base+code 分配端口并写入各项配置。参见："
    log_err "  knowledge-repos/management/PRINCIPLES/PORT-ALLOCATION.md"
    exit 1
fi

# 优先 envapp 级覆盖，否则取 env 级默认
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
[ -n "$NODE_ENV_VAL" ] || NODE_ENV_VAL="production"
[ -n "$USE_HTTPS_COOKIES" ] || USE_HTTPS_COOKIES="false"
[ -n "$RELEASES_TO_KEEP" ] || RELEASES_TO_KEEP="3"

# 版本化部署标志
USE_RELEASES="false"
if [ -n "$DEPLOY_ROOT" ]; then
    USE_RELEASES="true"
    log_ok "版本化部署: deploy_root=$DEPLOY_ROOT, releases_to_keep=$RELEASES_TO_KEEP"
fi

# 展开 ~
SSH_KEY_EXPANDED="${SSH_KEY_RAW/#\~/$HOME}"

log_ok "env: host=$HOST user=$SSH_USER mode=$DEPLOY_MODE port=$ENVAPP_PORT"
log_ok "cookie: USE_HTTPS_COOKIES=$USE_HTTPS_COOKIES, NODE_ENV=$NODE_ENV_VAL"

# ============================================================
# 5.1 E 阶段：host 公网校验（AGENTS.md 铁律 6）
# ============================================================
validate_host_not_local() {
    local h="$1"
    case "$h" in
        localhost|127.0.0.1|::1|0.0.0.0|"")
            return 1 ;;
        *)
            return 0 ;;
    esac
}

log "Step 3.5: host 公网校验 (validate_host_not_local)"
if ! validate_host_not_local "$HOST"; then
    if [ "$ALLOW_LOCALHOST" = "true" ]; then
        log_warn "host='$HOST' 是本地地址，但 --allow-localhost 显式豁免，继续"
    else
        log_err "host='$HOST' 是本地地址，违反 AGENTS.md 铁律 6（公网 IP 必用）"
        log_err "处理方式："
        log_err "  1) 改 environments.json: .environments.${ENV_NAME}.host = \"<公网 IP 或域名>\""
        log_err "     推荐值：demo/test=8.138.118.28、prod=43.139.53.121"
        log_err "  2) 或加 --allow-localhost flag（仅限应急/本地调试）"
        log_err "  3) 参见 knowledge-repos/management/PRINCIPLES/SERVER-CONFIG.md"
        exit 2
    fi
else
    log_ok "host 校验通过: $HOST"
fi

# database_host 同步校验（警告不中断）
DB_HOST_DEFAULT="$(_env_get "$ENV_NAME" ".database_host")"
if [ -n "$DB_HOST_DEFAULT" ] && ! validate_host_not_local "$DB_HOST_DEFAULT"; then
    if [ "$ALLOW_LOCALHOST" = "true" ]; then
        log_warn "database_host='$DB_HOST_DEFAULT' 是本地地址，--allow-localhost 豁免"
    else
        log_warn "database_host='$DB_HOST_DEFAULT' 是本地地址（environments.${ENV_NAME}.database_host）"
        log_warn "  仅警告：apps.json.env_config.${ENV_NAME}.database.host 可能覆盖。建议同步改为公网 IP。"
    fi
fi

# ============================================================
# 6. 预检查
# ============================================================
log "Step 4/10: 预检查 SSH / 项目路径"

if [ "$DRY_RUN" != "true" ]; then
    ssh -i "$SSH_KEY_EXPANDED" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "$SSH_USER@$HOST" true 2>/dev/null \
        || die "SSH 连通失败: $SSH_USER@$HOST (key=$SSH_KEY_EXPANDED)"
    log_ok "SSH ok"
else
    log_warn "dry-run: 跳过 SSH 实际握手"
fi

# ============================================================
# 7. 拉代码
# ============================================================
log "Step 5/10: git 拉代码"

# monorepo 在 root 拉代码，单仓项目在 project_path 拉
if [ -n "$APP_MONO_ROOT" ]; then
    GIT_DIR="$APP_MONO_ROOT"
else
    GIT_DIR="$APP_PATH"
fi

GIT_SHA="(skipped)"
IS_GIT="false"
if [ -d "$GIT_DIR/.git" ] || (cd "$GIT_DIR" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1); then
    IS_GIT="true"
fi
if [ "$IS_GIT" = "true" ]; then
    _local "cd '$GIT_DIR' && git fetch --all --tags --quiet"
    if [ -n "$VERSION_REF" ]; then
        log "checkout 指定版本: $VERSION_REF"
        _local "cd '$GIT_DIR' && git checkout '$VERSION_REF'"
    else
        log "pull 默认分支"
        _local "cd '$GIT_DIR' && git pull --ff-only"
    fi
    if [ "$DRY_RUN" != "true" ]; then
        GIT_SHA="$(cd "$GIT_DIR" && git rev-parse --short HEAD)"
    else
        # dry-run 下也读一下 sha，便于预览版本化路径
        GIT_SHA="$(cd "$GIT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo '(skipped)')"
    fi
    log_ok "代码版本: $GIT_SHA"
else
    log_warn "$GIT_DIR 不是 git 仓库，跳过 git 操作"
fi

# ============================================================
# 8. 构建
# ============================================================
if [ "$SKIP_BUILD" = "true" ]; then
    log_warn "Step 6/10: --skip-build, 跳过构建"
elif [ "$APP_FRAMEWORK" = "static" ]; then
    log_warn "Step 6/10: framework=static, 跳过构建"
else
    log "Step 6/10: 构建 ($APP_BUILD)"
    if [ -n "$APP_MONO_ROOT" ] && [ -n "$APP_MONO_WS" ]; then
        # monorepo: 先在 root 跑 install，然后 --filter ./apps/xxx build
        _local "cd '$APP_MONO_ROOT' && pnpm install --frozen-lockfile"
        _local "cd '$APP_MONO_ROOT' && pnpm --filter './$APP_MONO_WS' build"
    else
        # 单仓: 在项目目录跑 build_cmd
        [ -n "$APP_BUILD" ] && _local "cd '$APP_PATH' && $APP_BUILD" \
            || log_warn "build_cmd 为空，跳过构建"
    fi
    log_ok "构建完成"
fi

# ============================================================
# 6.4 数据库联动 (PRINCIPLE: DB-DEPLOY-INTEGRATION.md)
#     仅当 apps.json[$APP_KEY].env_config[$ENV_NAME].database 存在时触发
# ============================================================
DB_SKILL_DIR="$SKILL_DIR/../database-config"
DB_STATE=""          # missing / up_to_date / behind:N:list / skipped

step_db_check_and_apply() {
    if [ "$SKIP_DB" = "true" ]; then
        log_warn "--skip-db 启用，跳过数据库联动（应急逃生口，请在 DEPLOY-LOG.md notes 标注）"
        DB_STATE="skipped"
        return 0
    fi

    local db_type
    db_type=$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" \
        '.apps[$a].env_config[$e].database.type // empty' "$APPS_JSON")
    if [ -z "$db_type" ]; then
        log "[db] apps.json[$APP_KEY].env_config[$ENV_NAME].database 未配置，跳过"
        DB_STATE="none"
        return 0
    fi

    if [ ! -d "$DB_SKILL_DIR" ]; then
        log_warn "database-config skill 不在 ($DB_SKILL_DIR)，跳过 DB 联动"
        DB_STATE="skill_missing"
        return 0
    fi

    log "Step 6.4: DB 三态探测 (probe)"
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "[dry-run] 会调 check-db.sh $ENV_NAME --app $APP_KEY --mode probe"
        DB_STATE="dry-run"
        return 0
    fi

    DB_STATE="$(bash "$DB_SKILL_DIR/scripts/check-db.sh" "$ENV_NAME" --app "$APP_KEY" --mode probe 2>/dev/null | tail -1)" \
        || die "check-db.sh probe 执行失败。请检查数据库连接或用 --skip-db 临时绕过"
    log_ok "[db] probe 返回: $DB_STATE"

    case "$DB_STATE" in
        missing)
            log "[db] 状态一：数据库不存在，自动建库 + migrate"
            bash "$DB_SKILL_DIR/scripts/init-db.sh" "$ENV_NAME" --app "$APP_KEY" --non-interactive \
                || die "[db] init-db.sh 失败，部署中止"
            bash "$DB_SKILL_DIR/scripts/migrate-db.sh" "$ENV_NAME" --app "$APP_KEY" --non-interactive \
                || die "[db] migrate-db.sh 失败，部署中止，请 DBA 介入"
            log_ok "[db] 建库 + 迁移完成"
            ;;
        up_to_date|none|skill_missing)
            log_ok "[db] schema 最新或无 schema 概念，跳过"
            ;;
        behind:*)
            local detail="${DB_STATE#behind:}"
            if [ "$ENV_NAME" = "prod" ]; then
                log_warn "[db] 🔴 RED LINE: prod 数据库存在 schema 落后 ($detail)"
                log_warn "[db] deploy-app 不会自动 migrate；请走人工 DBA 流程"
                log_warn "[db] 参见 PRINCIPLES/DB-DEPLOY-INTEGRATION.md §四"
                # 不中断部署（仅警告，代码可先上）
            else
                log_warn "[db] schema 落后 ($detail)"
                if [ -t 0 ]; then
                    read -r -t 5 -p "是否执行 migrate? (y/N) " answer || answer="N"
                else
                    answer="N"
                fi
                case "${answer:-N}" in
                    y|Y|yes|YES)
                        bash "$DB_SKILL_DIR/scripts/migrate-db.sh" "$ENV_NAME" --app "$APP_KEY" --non-interactive \
                            || die "[db] migrate-db.sh 失败，部署中止"
                        log_ok "[db] 迁移完成"
                        ;;
                    *)
                        log_warn "[db] 用户选择跳过 migrate，继续部署代码（可能运行时报字段缺失）"
                        ;;
                esac
            fi
            ;;
        *)
            die "[db] check-db.sh 返回未知状态: $DB_STATE"
            ;;
    esac
}

step_db_check_and_apply

# --db-only 提前退出（调试用）
if [ "$DB_ONLY" = "true" ]; then
    log_ok "--db-only 模式完成，跳过后续部署步骤"
    exit 0
fi

# ============================================================
# 8.5 版本管理 (Phase 3)
#     仅在 deploy_root 已配置时启用；否则保持旧行为（PM2 cwd=源码目录）。
# ============================================================
RELEASE_DIR=""
PREV_SHA=""
RELEASE_SHA=""
PM2_CWD="$APP_PATH"   # 兼容默认值：未启用版本化时仍指向源码目录

if [ "$USE_RELEASES" = "true" ]; then
    log "Step 6.5/10: 版本管理 (releases/<sha>)"

    # 1) 计算 release sha
    if [ "$GIT_SHA" != "(skipped)" ] && [ -n "$GIT_SHA" ]; then
        RELEASE_SHA="$GIT_SHA"
    else
        RELEASE_SHA="nogit-$(date +%Y%m%d%H%M%S)"
    fi

    APP_DEPLOY_DIR="$DEPLOY_ROOT/$APP_KEY"
    RELEASES_DIR="$APP_DEPLOY_DIR/releases"
    RELEASE_DIR="$RELEASES_DIR/$RELEASE_SHA"
    CURRENT_LINK="$APP_DEPLOY_DIR/current"
    SHARED_NM_DIR="$DEPLOY_ROOT/shared/node_modules"

    # 2) 准备目录
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] mkdir -p $RELEASES_DIR $SHARED_NM_DIR"
        echo "  [dry-run] RELEASE_DIR=$RELEASE_DIR"
    else
        mkdir -p "$RELEASES_DIR" "$SHARED_NM_DIR"
        # 若同 sha 目录已存在（如重复部署），清空重建以保证一致
        if [ -d "$RELEASE_DIR" ]; then
            log_warn "release 目录已存在，重置: $RELEASE_DIR"
            rm -rf "$RELEASE_DIR"
        fi
        mkdir -p "$RELEASE_DIR"
    fi

    # 3) 复制 build 产物到 release 目录
    case "$APP_FRAMEWORK" in
        nextjs)
            log "复制 .next / public / package.json -> $RELEASE_DIR"
            if [ "$DRY_RUN" != "true" ]; then
                [ -d "$APP_PATH/.next" ] || die "build 产物缺失: $APP_PATH/.next"
                # 用 cp -a 保留权限；.next 比较大，但单应用通常 <200MB，可接受
                cp -a "$APP_PATH/.next" "$RELEASE_DIR/"
                [ -d "$APP_PATH/public" ] && cp -a "$APP_PATH/public" "$RELEASE_DIR/" || true
                [ -f "$APP_PATH/package.json" ] && cp -a "$APP_PATH/package.json" "$RELEASE_DIR/" || true
                [ -f "$APP_PATH/next.config.js" ]  && cp -a "$APP_PATH/next.config.js"  "$RELEASE_DIR/" || true
                [ -f "$APP_PATH/next.config.mjs" ] && cp -a "$APP_PATH/next.config.mjs" "$RELEASE_DIR/" || true
                [ -f "$APP_PATH/next.config.ts" ]  && cp -a "$APP_PATH/next.config.ts"  "$RELEASE_DIR/" || true
            fi
            ;;
        static)
            log "复制静态站点 (排除 .git/node_modules/server.js/*.log/_archive，保留 archive/) -> $RELEASE_DIR"
            if [ "$DRY_RUN" != "true" ]; then
                [ -d "$APP_PATH" ] || die "static 源目录不存在: $APP_PATH"
                rsync -a --delete \
                    --exclude='.git' --exclude='node_modules' \
                    --exclude='*.log' --exclude='server.js' \
                    --exclude='_archive' \
                    "$APP_PATH/" "$RELEASE_DIR/"
                # 多版本原型：archive/ 子目录不排除，与当前版同站点并存
                if [ -d "$APP_PATH/archive" ]; then
                    ARCHIVE_VER_COUNT=$(find "$APP_PATH/archive" -mindepth 1 -maxdepth 1 -type d | wc -l)
                    DEPLOYED_VER_COUNT=$(find "$RELEASE_DIR/archive" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
                    log_ok "历史版本: src=$ARCHIVE_VER_COUNT 个 / deployed=$DEPLOYED_VER_COUNT 个"
                    if [ "$ARCHIVE_VER_COUNT" -ne "$DEPLOYED_VER_COUNT" ]; then
                        die "archive/ 版本数不一致 src=$ARCHIVE_VER_COUNT deployed=$DEPLOYED_VER_COUNT"
                    fi
                fi
                # 生成 serve.json：禁用 cleanUrls / trailingSlash，避免 .html 被 301 去后缀导致路径 fallback 问题
                # （serve@14 默认 cleanUrls=true 会将 /xxx.html 301 到 /xxx）
                if [ ! -f "$RELEASE_DIR/serve.json" ]; then
                    cat > "$RELEASE_DIR/serve.json" <<'SERVE_JSON'
{
  "cleanUrls": false,
  "trailingSlash": false,
  "renderSingle": false,
  "directoryListing": false
}
SERVE_JSON
                    log_ok "生成 serve.json (cleanUrls=false)"
                fi
            fi
            ;;
        express|nestjs|node)
            log "复制项目目录到 $RELEASE_DIR (排除 node_modules/.git)"
            if [ "$DRY_RUN" != "true" ]; then
                # 简单实现：rsync 排除大目录
                rsync -a --delete \
                    --exclude='node_modules' --exclude='.git' --exclude='.next/cache' \
                    "$APP_PATH/" "$RELEASE_DIR/"
            fi
            ;;
        *)
            die "未支持的 framework=$APP_FRAMEWORK 版本化复制"
            ;;
    esac

    # 4) 共享 node_modules：把 release/node_modules symlink 到源码目录
    NM_TARGET=""
    if [ -n "$APP_MONO_ROOT" ] && [ -d "$APP_MONO_ROOT/node_modules" ]; then
        # monorepo 一般共用 root/node_modules；workspace 子项目自身也可能有
        # 优先 app 自身（pnpm workspace 软链会挂在子项目下）
        if [ -d "$APP_PATH/node_modules" ]; then
            NM_TARGET="$APP_PATH/node_modules"
        else
            NM_TARGET="$APP_MONO_ROOT/node_modules"
        fi
    else
        NM_TARGET="$APP_PATH/node_modules"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] ln -sfn $NM_TARGET $RELEASE_DIR/node_modules"
        echo "  [dry-run] ln -sfn $NM_TARGET $SHARED_NM_DIR/$APP_KEY"
    else
        if [ -d "$NM_TARGET" ]; then
            ln -sfn "$NM_TARGET" "$RELEASE_DIR/node_modules"
            ln -sfn "$NM_TARGET" "$SHARED_NM_DIR/$APP_KEY"
        else
            log_warn "node_modules 不存在，跳过 symlink: $NM_TARGET"
        fi
    fi

    # 5) 记录上一个版本（用于回滚参考）
    if [ -L "$CURRENT_LINK" ]; then
        PREV_SHA="$(basename "$(readlink "$CURRENT_LINK")")"
    fi
    [ -n "$PREV_SHA" ] && log_ok "上一个版本: $PREV_SHA" || log_warn "无上一个版本（首次版本化部署）"
    log_ok "本次版本: $RELEASE_SHA -> $RELEASE_DIR"

    # 6) 切换 current symlink（原子）
    if [ "$DRY_RUN" = "true" ]; then
        echo "  [dry-run] ln -sfn $RELEASE_DIR $CURRENT_LINK"
    else
        ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"
    fi
    PM2_CWD="$CURRENT_LINK"
fi

# ============================================================
# 9. 部署 (按 deploy_mode 分支)
# ============================================================
log "Step 7/10: 部署 (mode=$DEPLOY_MODE, cwd=$PM2_CWD)"

case "$DEPLOY_MODE" in
    pm2)
        # 9.1 框架决定启动命令
        # 默认走 deployment-standard §2.0.3 推荐的 next start 方式
        case "$APP_FRAMEWORK" in
            nextjs)
                # 支持 monorepo 结构：先在 project_path 找，没找到就在父目录找
                if [ -f "$PM2_CWD/node_modules/next/dist/bin/next" ]; then
                    PM2_SCRIPT="node_modules/next/dist/bin/next"
                elif [ -f "$(dirname $PM2_CWD)/node_modules/next/dist/bin/next" ]; then
                    PM2_SCRIPT="$(dirname $PM2_CWD)/node_modules/next/dist/bin/next"
                elif [ -f "$(dirname $(dirname $PM2_CWD))/node_modules/next/dist/bin/next" ]; then
                    PM2_SCRIPT="$(dirname $(dirname $PM2_CWD))/node_modules/next/dist/bin/next"
                else
                    die "未找到 next 命令，请检查项目依赖是否正确安装"
                fi
                # 注意：next start 不支持 --prefix（这是 pnpm/npm 的选项）。
                # 旧逻辑曾在 apps/web 结构下注入 --prefix 导致 PM2 启动失败，已移除。
                # next 会以 PM2 的 cwd 作为工作目录读取 .next/。如果版本化部署使 cwd 指向
                # /<deploy_root>/<app>/current，那么 .next 必须存在于 current/.next/。
                PM2_ARGS="start -H 0.0.0.0 -p $ENVAPP_PORT"
                ;;
            static)
                # 静态站点：用 npx serve -l <port> . 跑（PM2 守护进程）
                # serve 全局或临时安装均可；npx 第一次会自动下载到缓存
                PM2_SCRIPT="$(command -v npx 2>/dev/null || echo /usr/bin/npx)"
                # 多页面静态站点：不要加 -s (SPA fallback)，否则所有非根路径都会被路由到 index.html
                # 导致 .html 资源拿到 HTML 内容（MIME 错误）、子页面 301 去后缀等问题
                PM2_ARGS="-y serve@14 -l tcp://0.0.0.0:$ENVAPP_PORT ."
                ;;
            express|nestjs|node)
                # 这些直接用 app 的 start_cmd（拆为 script + 空 args）
                PM2_SCRIPT="$(echo "$APP_START" | awk '{print $1}')"
                PM2_ARGS="$(echo "$APP_START" | cut -d' ' -f2-)"
                [ "$PM2_SCRIPT" = "$PM2_ARGS" ] && PM2_ARGS=""
                ;;
            *)
                die "未支持的 framework=$APP_FRAMEWORK (当前仅支持 nextjs/static/express/nestjs/node)"
                ;;
        esac

        # 9.2 资源参数（按 §2.0.4）
        case "$ENV_NAME" in
            prod) PM2_INSTANCES="max"; PM2_MEM="512M" ;;
            *)    PM2_INSTANCES="1";   PM2_MEM="256M" ;;
        esac

        # 9.3 ecosystem 临时文件（生成到本地，scp 到目标）
        # 自动注入 DATABASE_URL（从 apps.json[$APP_KEY].env_config[$ENV_NAME].database 拼）
        DB_URL_INJECT=""
        DB_T="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.type // empty' "$APPS_JSON")"
        if [ -n "$DB_T" ]; then
            DB_H="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.host // "localhost"' "$APPS_JSON")"
            DB_P="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.port // 5432' "$APPS_JSON")"
            DB_N="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.database // empty' "$APPS_JSON")"
            DB_U="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.username // empty' "$APPS_JSON")"
            DB_PW="$(jq -r --arg a "$APP_KEY" --arg e "$ENV_NAME" '.apps[$a].env_config[$e].database.password // empty' "$APPS_JSON")"
            # URL encode 密码里的特殊字符（仅最常见的 @ : / ? # & % 等）
            DB_PW_ENC="$(printf '%s' "$DB_PW" | jq -sRr @uri)"
            case "$DB_T" in
                postgresql|postgres) DB_URL_INJECT="postgresql://${DB_U}:${DB_PW_ENC}@${DB_H}:${DB_P}/${DB_N}" ;;
                mysql)               DB_URL_INJECT="mysql://${DB_U}:${DB_PW_ENC}@${DB_H}:${DB_P}/${DB_N}" ;;
            esac
            [ -n "$DB_URL_INJECT" ] && log_ok "DB URL 已注入 PM2 env（DATABASE_URL）"
        fi

        ECO_TMP="$(mktemp -t ecosystem-${ENVAPP_PM2_NAME}-XXXXXX.config.cjs)"
        cat > "$ECO_TMP" <<ECO
// AUTO-GENERATED by deploy-app skill, DO NOT EDIT
// app=$APP_KEY env=$ENV_NAME pm2_name=$ENVAPP_PM2_NAME port=$ENVAPP_PORT
module.exports = {
  apps: [{
    name: '$ENVAPP_PM2_NAME',
    script: '$PM2_SCRIPT',
    args: '$PM2_ARGS',
    cwd: '$PM2_CWD',
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
      DATABASE_URL: '$DB_URL_INJECT',
    },
  }]
};
ECO

        REMOTE_ECO="/tmp/ecosystem-${ENVAPP_PM2_NAME}.config.cjs"
        log "scp ecosystem -> $SSH_USER@$HOST:$REMOTE_ECO"
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [dry-run] scp -i $SSH_KEY_EXPANDED $ECO_TMP $SSH_USER@$HOST:$REMOTE_ECO"
            echo "  [dry-run] ecosystem 内容预览:"
            sed 's/^/    | /' "$ECO_TMP"
        else
            scp -i "$SSH_KEY_EXPANDED" \
                -o StrictHostKeyChecking=no \
                "$ECO_TMP" "$SSH_USER@$HOST:$REMOTE_ECO" >/dev/null
        fi

        # 9.4 启动 / reload
        # 关键修复（v1.1）:
        # - pm2 reload 只接 <id|name|namespace|all>，**不能接 ecosystem 文件路径**
        # - 首次启动用 pm2 start <ecosystem> --only <name>，锁定 ecosystem 里的 app name
        # - 已存在则 pm2 reload <name> --update-env（按名字 reload，不传 ecosystem）
        # - 用 heredoc 通过 stdin 把脚本喂给远端 bash，彻底避免 ssh 双引号 + 内嵌单引号嵌套陷阱
        log "pm2 reload-or-start: $ENVAPP_PM2_NAME (cwd=$PM2_CWD)"
        PM2_SCRIPT_REMOTE=$(cat <<RSCRIPT
DESIRED_CWD='$PM2_CWD'
DESIRED_PORT='$ENVAPP_PORT'
if pm2 describe '$ENVAPP_PM2_NAME' >/dev/null 2>&1; then
    CURRENT_CWD=\$(pm2 jlist 2>/dev/null | node -e "let d=JSON.parse(require('fs').readFileSync(0,'utf8'));let a=d.find(x=>x.name==='$ENVAPP_PM2_NAME');process.stdout.write((a&&a.pm2_env&&a.pm2_env.pm_cwd)||'')" 2>/dev/null || echo '')
    CURRENT_PORT=\$(pm2 jlist 2>/dev/null | node -e "let d=JSON.parse(require('fs').readFileSync(0,'utf8'));let a=d.find(x=>x.name==='$ENVAPP_PM2_NAME');let args=a&&a.pm2_env&&a.pm2_env.args? a.pm2_env.args.join(' '):'';let m=args.match(/\\-l\\s+tcp:\\/\\/0\\.0\\.0\\.0:(\\d+)/);process.stdout.write(m? m[1]:(a&&a.pm2_env&&a.pm2_env.env&&a.pm2_env.env.PORT)||'')" 2>/dev/null || echo '')
    if [ "\$CURRENT_CWD" = "\$DESIRED_CWD" ] && [ "\$CURRENT_PORT" = "\$DESIRED_PORT" ]; then
        echo "[deploy] cwd and port unchanged (\$DESIRED_CWD:\$DESIRED_PORT), reloading"
        pm2 reload '$ENVAPP_PM2_NAME' --update-env
    else
        echo "[deploy] config changed: cwd=\$CURRENT_CWD->\$DESIRED_CWD, port=\$CURRENT_PORT->\$DESIRED_PORT; recreating PM2 entry"
        pm2 delete '$ENVAPP_PM2_NAME' || true
        pm2 start '$REMOTE_ECO' --only '$ENVAPP_PM2_NAME'
    fi
else
    pm2 start '$REMOTE_ECO' --only '$ENVAPP_PM2_NAME'
fi
RSCRIPT
)
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [dry-run] ssh -i $SSH_KEY_EXPANDED $SSH_USER@$HOST bash -s <<'EOF'"
            echo "$PM2_SCRIPT_REMOTE" | sed 's/^/    | /'
            echo "  [dry-run] EOF"
        else
            ssh -i "$SSH_KEY_EXPANDED" \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                "$SSH_USER@$HOST" bash -s <<<"$PM2_SCRIPT_REMOTE"
        fi
        _ssh "pm2 save >/dev/null 2>&1 || true"

        # 把 ecosystem 也保留一份到 release 目录（便于回滚时复用）
        if [ "$USE_RELEASES" = "true" ] && [ "$DRY_RUN" != "true" ] && [ -n "$RELEASE_DIR" ]; then
            cp -a "$ECO_TMP" "$RELEASE_DIR/ecosystem.config.cjs"
        fi
        rm -f "$ECO_TMP" 2>/dev/null || true
        ;;
    docker)
        log_warn "TODO(Phase 2.5): docker 部署模式尚未实现"
        die "deploy_mode=docker 暂未实现"
        ;;
    nginx-static)
        log_warn "TODO(Phase 2.5): nginx-static 部署模式尚未实现"
        die "deploy_mode=nginx-static 暂未实现"
        ;;
    *)
        die "未知 deploy_mode=$DEPLOY_MODE"
        ;;
esac

log_ok "部署指令已下发"

# ============================================================
# 10. 等服务起来 + 健康检查
# ============================================================
log "Step 8/10: 等待 5 秒让服务启动"
[ "$DRY_RUN" = "true" ] || sleep 5

log "Step 9/10: 健康检查 (verify.sh)"
START_EPOCH="${START_EPOCH:-$(date +%s)}"

if [ "$DRY_RUN" = "true" ]; then
    log_warn "dry-run: 跳过真实 verify"
    HEALTH_OK="true"
else
    if bash "$SCRIPTS_DIR/verify.sh" "$ENV_NAME" "$APP_KEY"; then
        HEALTH_OK="true"
    else
        HEALTH_OK="false"
    fi
fi

# ============================================================
# 11. 失败自动 rollback
# ============================================================
if [ "$HEALTH_OK" = "false" ]; then
    log_err "健康检查失败，触发自动 rollback"
    bash "$SCRIPTS_DIR/rollback.sh" "$ENV_NAME" "$APP_KEY" || true
    STATUS="FAILED"
else
    STATUS="SUCCESS"

    # prod 额外检查（VERSIONING.md）: /api/health 返回的 version 必须 == tag
    if [ "$ENV_NAME" = "prod" ] && [ -n "$VERSION_REF" ] && [ "$DRY_RUN" != "true" ]; then
        log "prod 附加检查：/api/health version == $VERSION_REF"
        APP_HEALTH_PATH="$(_app_get "$APP_KEY" ".health_path")"
        [ -n "$APP_HEALTH_PATH" ] || APP_HEALTH_PATH="/api/health"
        HEALTH_URL="http://$HOST:$ENVAPP_PORT$APP_HEALTH_PATH"
        HEALTH_JSON="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null || echo '')"
        if [ -z "$HEALTH_JSON" ]; then
            log_err "prod 附加检查失败：$HEALTH_URL 不可达"
            STATUS="FAILED"
            bash "$SCRIPTS_DIR/rollback.sh" "$ENV_NAME" "$APP_KEY" || true
        else
            HEALTH_VER="$(echo "$HEALTH_JSON" | jq -r '.version // empty' 2>/dev/null || echo '')"
            TAG_VER_BARE="${VERSION_REF#v}"
            # 接受 v前缀或不带前缀两种返回
            if [ "$HEALTH_VER" = "$VERSION_REF" ] || [ "$HEALTH_VER" = "$TAG_VER_BARE" ]; then
                log_ok "prod 附加检查通过：health.version=$HEALTH_VER == tag=$VERSION_REF"
            else
                log_err "prod 附加检查失败：health.version='$HEALTH_VER' 不等于 tag=$VERSION_REF"
                log_err "请确认 /api/health 已正确暴露 version 字段。参见："
                log_err "  knowledge-repos/management/PRINCIPLES/VERSIONING.md"
                STATUS="FAILED"
                bash "$SCRIPTS_DIR/rollback.sh" "$ENV_NAME" "$APP_KEY" || true
            fi
        fi
    fi
fi

# ============================================================
# 11.5 清理旧版本（仅在版本化部署 + 健康成功时）
# ============================================================
if [ "$USE_RELEASES" = "true" ] && [ "$HEALTH_OK" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    log "Step 10/10a: 清理旧版本 (保留 $RELEASES_TO_KEEP 个)"
    CURRENT_REL_SHA="$(basename "$(readlink "$DEPLOY_ROOT/$APP_KEY/current")")"
    cd "$DEPLOY_ROOT/$APP_KEY/releases"
    # 按 mtime 倒序，保留前 N 个；其余删除（但绝不删 current 指向的那个）
    ALL_RELEASES=$(ls -1t 2>/dev/null || true)
    KEEP=0
    for r in $ALL_RELEASES; do
        if [ "$r" = "$CURRENT_REL_SHA" ]; then
            continue
        fi
        KEEP=$((KEEP + 1))
        # 当前指向的算 1 个，再保留 (N-1) 个其他
        if [ "$KEEP" -ge "$RELEASES_TO_KEEP" ]; then
            log "  删除旧版本: $r"
            rm -rf "./$r"
        fi
    done
    cd - >/dev/null
fi

# ============================================================
# 12. 写部署日志
# ============================================================
log "Step 10/10: 写部署日志 -> $DEPLOY_LOG"
END_EPOCH="$(date +%s)"
DURATION="$(( END_EPOCH - START_EPOCH ))s"
NOW_STR="$(date '+%Y-%m-%d %H:%M:%S')"

if [ "$DRY_RUN" = "true" ]; then
    LOG_LINE="| $NOW_STR | $ENV_NAME | $APP_KEY | ${VERSION_REF:-HEAD} | ${RELEASE_SHA:-$GIT_SHA} | DRY_RUN | $DURATION |"
    log_warn "dry-run: 不写日志，仅预览:"
    echo "    $LOG_LINE"
else
    LOG_LINE="| $NOW_STR | $ENV_NAME | $APP_KEY | ${VERSION_REF:-HEAD} | ${RELEASE_SHA:-$GIT_SHA} | $STATUS | $DURATION |"
    # 初始化表头（仅当文件不存在或为空时）
    if [ ! -s "$DEPLOY_LOG" ]; then
        mkdir -p "$(dirname "$DEPLOY_LOG")"
        cat > "$DEPLOY_LOG" <<HDR
# DEPLOY-LOG

部署历史记录，由 deploy-app skill 自动追加。

| 时间 | env | app | version | git_sha | status | duration |
|------|-----|-----|---------|---------|--------|----------|
HDR
    fi
    echo "$LOG_LINE" >> "$DEPLOY_LOG"
fi

# ============================================================
# 13. 终态
# ============================================================
echo
if [ "$DRY_RUN" = "true" ]; then
    log_warn "dry-run 结束（未实际部署）- $APP_DISPLAY ($ENV_NAME)"
    exit 0
elif [ "$STATUS" = "SUCCESS" ]; then
    log_ok "部署完成: $APP_DISPLAY ($ENV_NAME) -> $STATUS [$DURATION]"
    exit 0
else
    log_err "部署失败: $APP_DISPLAY ($ENV_NAME) -> $STATUS [$DURATION]"
    exit 1
fi
