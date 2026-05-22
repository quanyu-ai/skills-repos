#!/bin/bash
# deploy.sh - Phase 2 主部署脚本
# 用法: ./deploy.sh <env> <app> [--version <git_sha_or_tag>] [--approved-by <user>] [--skip-build] [--dry-run]
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
Usage: $(basename "$0") <env> <app> [--version <ref>] [--approved-by <user>] [--skip-build] [--dry-run]
  <env>             环境名: test | demo | prod
  <app>             应用 key (apps.json 中定义)
  --version <ref>   指定 git tag/sha (默认: 当前默认分支 HEAD)
  --approved-by <user>  审批人 (prod 必需)
  --skip-build      跳过构建步骤
  --dry-run         只打印操作，不实际执行
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
DRY_RUN="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --version)      VERSION_REF="${2:-}"; shift 2 ;;
        --approved-by)  APPROVED_BY="${2:-}"; shift 2 ;;
        --skip-build)   SKIP_BUILD="true"; shift ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        -h|--help)      usage ;;
        *)              die "未知参数: $1" ;;
    esac
done

# ============================================================
# 1.2 工具函数（提前到 D1/D2 之前，供门禁/锁使用）
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
# 5. 读 environments.json
# ============================================================
log "Step 3/10: 读 environments.json -> env=$ENV_NAME"
ENV_EXISTS="$(jq -r --arg e "$ENV_NAME" '.environments | has($e)' "$ENVS_JSON")"
[ "$ENV_EXISTS" = "true" ] || die "environments.json 里没有 env=$ENV_NAME"

ENVAPP_PORT="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".port")"
ENVAPP_PM2_NAME="$(_envapp_get "$ENV_NAME" "$APP_KEY" ".pm2_name")"
[ -n "$ENVAPP_PORT" ] || die "环境 $ENV_NAME 未声明 app=$APP_KEY (检查 environments.json)"

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

    [ -d "$APP_PATH" ] || die "项目路径不存在: $APP_PATH"
    log_ok "项目路径存在: $APP_PATH"
else
    log_warn "dry-run: 跳过 SSH 实际握手与目录检查"
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
            log "复制静态站点 (排除 .git/node_modules/server.js/*.log) -> $RELEASE_DIR"
            if [ "$DRY_RUN" != "true" ]; then
                [ -d "$APP_PATH" ] || die "static 源目录不存在: $APP_PATH"
                rsync -a --delete \
                    --exclude='.git' --exclude='node_modules' \
                    --exclude='*.log' --exclude='server.js' \
                    --exclude='_archive' \
                    "$APP_PATH/" "$RELEASE_DIR/"
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
                # 使用相对路径：next 通过 node_modules symlink 找到
                PM2_SCRIPT="node_modules/next/dist/bin/next"
                PM2_ARGS="start -H 0.0.0.0 -p $ENVAPP_PORT"
                ;;
            static)
                # 静态站点：用 npx serve -l <port> . 跑（PM2 守护进程）
                # serve 全局或临时安装均可；npx 第一次会自动下载到缓存
                PM2_SCRIPT="$(command -v npx 2>/dev/null || echo /usr/bin/npx)"
                PM2_ARGS="-y serve@14 -l tcp://0.0.0.0:$ENVAPP_PORT -s ."
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
if pm2 describe '$ENVAPP_PM2_NAME' >/dev/null 2>&1; then
    CURRENT_CWD=\$(pm2 jlist 2>/dev/null | node -e "let d=JSON.parse(require('fs').readFileSync(0,'utf8'));let a=d.find(x=>x.name==='$ENVAPP_PM2_NAME');process.stdout.write((a&&a.pm2_env&&a.pm2_env.pm_cwd)||'')" 2>/dev/null || echo '')
    if [ "\$CURRENT_CWD" = "\$DESIRED_CWD" ]; then
        echo "[deploy] cwd unchanged (\$DESIRED_CWD), reloading"
        pm2 reload '$ENVAPP_PM2_NAME' --update-env
    else
        echo "[deploy] cwd changed: \$CURRENT_CWD -> \$DESIRED_CWD; recreating PM2 entry"
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
