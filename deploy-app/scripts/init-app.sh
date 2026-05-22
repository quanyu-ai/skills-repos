#!/bin/bash
# init-app.sh - 智能应用初始化脚本（方案一简化版）
# 用法: ./init-app.sh [--dry-run] [--no-interactive] [app_key|project_path]
# 目标: 大幅降低门槛，智能推荐配置，直接写入 apps.json

set -euo pipefail

# 颜色
C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;36m'; C_N='\033[0m'

log()     { printf "${C_B}▶ %s${C_N}\n" "$*"; }
log_ok()  { printf "${C_G}✓ %s${C_N}\n" "$*"; }
log_warn(){ printf "${C_Y}⚠ %s${C_N}\n" "$*"; }
log_err() { printf "${C_R}✗ %s${C_N}\n" "$*" >&2; }
die()     { log_err "$*"; exit 1; }

# 项目路径
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"
APPS_JSON="$CONFIG_DIR/apps.json"

# 选项
DRY_RUN="false"
NO_INTERACTIVE="false"

# ============================================================
# 1. 参数解析
# ============================================================
while true; do
    case "${1:-}" in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --no-interactive)
            NO_INTERACTIVE="true"
            shift
            ;;
        --help|-h)
            cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--no-interactive] <app_key|project_path>

智能应用初始化脚本（方案一简化版）

示例:
  ./init-app.sh quanyu-platform              # 从 apps.json 中查找
  ./init-app.sh /path/to/project             # 从项目路径初始化
  ./init-app.sh --dry-run quanyu-platform    # 预览配置
  ./init-app.sh --no-interactive quanyu-platform  # 自动执行

功能:
  ✓ 自动识别框架类型
  ✓ 智能推荐构建/启动命令
  ✓ 自动验证 Git 仓库地址
  ✓ 直接写入 apps.json

USAGE
            exit 0
            ;;
        "")
            cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--no-interactive] <app_key|project_path>
使用 --help 查看详细帮助。
USAGE
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

TARGET="$1"
PROJECT_PATH=""
APP_KEY=""

if [ -d "$TARGET" ]; then
    # 如果是目录，直接使用
    PROJECT_PATH="$(cd "$TARGET" && pwd)"
    APP_KEY="$(basename "$PROJECT_PATH" | tr -cd 'a-z0-9-')"
    log "从项目路径初始化: $PROJECT_PATH"
    log "自动生成 app_key: $APP_KEY"
else
    # 如果是 app_key，检查是否已配置
    APP_KEY="$TARGET"
    if jq -e ".apps[\"$APP_KEY\"]" "$APPS_JSON" >/dev/null 2>&1; then
        log_warn "应用 $APP_KEY 已在 apps.json 中配置"
        if [ "$NO_INTERACTIVE" = "false" ]; then
            read -p "是否覆盖配置？(y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "取消操作"
                exit 0
            fi
        fi
    fi
    # 尝试从 apps.json 中获取项目路径
    PROJECT_PATH="$(jq -r ".apps[\"$APP_KEY\"].project_path // empty" "$APPS_JSON")"
    if [ -z "$PROJECT_PATH" ] || [ ! -d "$PROJECT_PATH" ]; then
        log_warn "未找到项目路径，默认使用 code-repos 目录"
        PROJECT_PATH="/var/lib/openclaw/.openclaw/workspace/code-repos/$APP_KEY"
    fi
    log "从 app_key 初始化: $APP_KEY"
    log "项目路径: $PROJECT_PATH"
fi

# ============================================================
# 2. 智能识别项目信息
# ============================================================
DISPLAY_NAME=""
GIT_URL=""
BUILD_CMD=""
START_CMD=""
HEALTH_PATH=""
FRAMEWORK=""

# 2.1 尝试获取 package.json
if [ -f "$PROJECT_PATH/package.json" ]; then
    log_ok "找到 package.json"
    
    # 获取项目名称
    NAME="$(jq -r '.name // empty' "$PROJECT_PATH/package.json")"
    if [ -n "$NAME" ] && [ "$NAME" != "null" ]; then
        DISPLAY_NAME="$(echo "$NAME" | sed 's/^@.*\///' | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')"
    fi
    
    # 智能识别框架类型
    if grep -q '"next"' "$PROJECT_PATH/package.json"; then
        FRAMEWORK="nextjs"
        log_ok "识别到框架: Next.js"
        BUILD_CMD="pnpm install --frozen-lockfile && pnpm build"
        START_CMD="pnpm start"
        HEALTH_PATH="/api/health"
    elif grep -q '"@nestjs"' "$PROJECT_PATH/package.json"; then
        FRAMEWORK="nestjs"
        log_ok "识别到框架: NestJS"
        BUILD_CMD="npm run build"
        START_CMD="npm run start:prod"
        HEALTH_PATH="/api/health"
    elif grep -q '"express"' "$PROJECT_PATH/package.json"; then
        FRAMEWORK="express"
        log_ok "识别到框架: Express"
        BUILD_CMD="npm run build"
        START_CMD="npm start"
        HEALTH_PATH="/api/health"
    elif [ -f "$PROJECT_PATH/index.html" ] || [ -d "$PROJECT_PATH/public" ]; then
        FRAMEWORK="static"
        log_ok "识别到框架: Static"
        BUILD_CMD=""
        START_CMD=""
        HEALTH_PATH="/"
    else
        FRAMEWORK="node"
        log_warn "识别到框架: Node.js 原生"
        BUILD_CMD="npm install"
        START_CMD="node index.js"
        HEALTH_PATH="/"
    fi
    
    # 尝试获取 scripts
    if [ -z "$BUILD_CMD" ]; then
        BUILD_CMD="$(jq -r '.scripts.build // empty' "$PROJECT_PATH/package.json")"
    fi
    if [ -z "$START_CMD" ]; then
        START_CMD="$(jq -r '.scripts.start // empty' "$PROJECT_PATH/package.json")"
    fi
else
    log_warn "未找到 package.json，使用默认配置"
    FRAMEWORK="node"
    BUILD_CMD="npm install"
    START_CMD="node server.js"
    HEALTH_PATH="/"
fi

# 2.2 Git 地址
if [ -d "$PROJECT_PATH/.git" ]; then
    GIT_URL="$(cd "$PROJECT_PATH" && git config --get remote.origin.url || true)"
    if [ -z "$GIT_URL" ]; then
        log_warn "未找到 git remote，尝试从 GitHub 推断"
        # 简单的 GitHub 地址推断
        GIT_URL="git@github.com:quanyu-ai/$APP_KEY.git"
    fi
fi

# ============================================================
# 3. 交互式确认（大幅简化版）
# ============================================================
cat <<BANNER
═══════════════════════════════════════════════════════
                   配置预览
═══════════════════════════════════════════════════════

  Key:          $APP_KEY
  Display Name: ${DISPLAY_NAME:-"权舆${APP_KEY}"}
  Project Path: $PROJECT_PATH
  Git URL:      ${GIT_URL:-"未配置"}
  Framework:    $FRAMEWORK
  Build Cmd:    ${BUILD_CMD:-"无"}
  Start Cmd:    ${START_CMD:-"无"}
  Health Path:  $HEALTH_PATH

═══════════════════════════════════════════════════════

BANNER

# 3.1 只问必要的问题（非交互模式跳过）
if [ "$NO_INTERACTIVE" = "false" ]; then
    read -p "显示名称 [${DISPLAY_NAME:-"权舆${APP_KEY}"}]: " -r
    if [ -n "$REPLY" ]; then
        DISPLAY_NAME="$REPLY"
    elif [ -z "$DISPLAY_NAME" ]; then
        DISPLAY_NAME="权舆${APP_KEY}"
    fi
    
    read -p "Git 仓库地址 [${GIT_URL:-"留空"}]: " -r
    if [ -n "$REPLY" ]; then
        GIT_URL="$REPLY"
    elif [ -z "$GIT_URL" ]; then
        log_warn "Git 仓库地址未配置，部分功能将不可用"
    fi
else
    # 非交互模式使用默认值
    if [ -z "$DISPLAY_NAME" ]; then
        DISPLAY_NAME="权舆${APP_KEY}"
    fi
    log_ok "使用默认显示名称: $DISPLAY_NAME"
    if [ -z "$GIT_URL" ]; then
        log_warn "Git 仓库地址未配置"
    fi
fi

# ============================================================
# 4. 写入 apps.json（直接写入，无需手贴）
# ============================================================
if [ "$DRY_RUN" = "true" ]; then
    log_warn "dry-run: 不实际写入配置"
else
    TEMP_FILE="$(mktemp -t apps-merged-XXXXXX.json)"
    CURRENT_DATA="$(cat "$APPS_JSON")"
    
    if jq -e ".apps[\"$APP_KEY\"]" "$APPS_JSON" >/dev/null 2>&1; then
        log_warn "应用 $APP_KEY 已存在，将进行更新"
        # 更新现有配置
        NEW_CONFIG="$(jq ".apps[\"$APP_KEY\"] |= \
            .display_name = \"$DISPLAY_NAME\" | \
            .project_path = \"$PROJECT_PATH\" | \
            .repo_url = \"$GIT_URL\" | \
            .build_cmd = \"$BUILD_CMD\" | \
            .start_cmd = \"$START_CMD\" | \
            .health_path = \"$HEALTH_PATH\" | \
            .framework = \"$FRAMEWORK\"" <<<"$CURRENT_DATA")"
    else
        log_ok "新增应用 $APP_KEY"
        # 新增配置
        NEW_CONFIG="$(jq ".apps += { \"$APP_KEY\": {
            \"display_name\": \"$DISPLAY_NAME\",
            \"project_path\": \"$PROJECT_PATH\",
            \"repo_url\": \"$GIT_URL\",
            \"build_cmd\": \"$BUILD_CMD\",
            \"start_cmd\": \"$START_CMD\",
            \"health_path\": \"$HEALTH_PATH\",
            \"framework\": \"$FRAMEWORK\"
        }}" <<<"$CURRENT_DATA")"
    fi
    
    # 格式化输出
    echo "$NEW_CONFIG" | jq '.' > "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$APPS_JSON"
    log_ok "配置已写入 apps.json"
fi

# ============================================================
# 5. 自动添加到 environments.json（可选）
# ============================================================
ENV_FILE="$CONFIG_DIR/environments.json"

# 检查 environments.json 中是否已包含该应用
if ! jq -e ".environments.demo.apps[\"$APP_KEY\"]" "$ENV_FILE" >/dev/null 2>&1; then
    log_warn "未在 environments.json 中找到 $APP_KEY 的配置"
    if [ "$DRY_RUN" = "true" ]; then
        log_warn "dry-run: 不添加到 environments.json"
    else
        if [ "$NO_INTERACTIVE" = "false" ]; then
            read -p "是否自动添加到 demo 环境？(Y/n): " -r
        fi
        if [ "$NO_INTERACTIVE" = "true" ] || [[ $REPLY =~ ^[Yy]$ ]] || [ -z "$REPLY" ]; then
            # 自动分配端口
            # 查找最大端口号
            MAX_PORT="$(jq -r '.environments.demo.apps | to_entries | map(.value.port) | max' "$ENV_FILE" 2>/dev/null || echo 3100)"
            NEW_PORT="$((MAX_PORT + 1))"
            
            TEMP_ENV="$(mktemp -t envs-merged-XXXXXX.json)"
            ENV_DATA="$(cat "$ENV_FILE")"
            
            NEW_ENV="$(jq ".environments.demo.apps += { \"$APP_KEY\": {
                \"port\": $NEW_PORT,
                \"pm2_name\": \"$APP_KEY\"
            }}" <<<"$ENV_DATA")"
            
            echo "$NEW_ENV" | jq '.' > "$TEMP_ENV"
            mv -f "$TEMP_ENV" "$ENV_FILE"
            log_ok "已添加到 demo 环境，端口: $NEW_PORT"
        fi
    fi
else
    log_ok "应用已在 environments.json 中配置"
fi

# ============================================================
# 6. 验证配置
# ============================================================
if [ "$DRY_RUN" = "true" ]; then
    log_warn "dry-run: 不验证配置"
else
    log "正在验证配置..."
    bash "$SKILL_DIR/scripts/doctor.sh" >/dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log_ok "配置验证通过"
    else
        log_err "配置验证失败，可能需要手动检查"
    fi
fi

cat <<BANNER
═══════════════════════════════════════════════════════
                     完成！
═══════════════════════════════════════════════════════

应用 $APP_KEY 已成功初始化！

您可以：
1. 检查配置: cat $APPS_JSON
2. 测试部署: bash $SKILL_DIR/scripts/deploy.sh demo $APP_KEY
3. 查看帮助: bash $SKILL_DIR/scripts/deploy.sh --help

═══════════════════════════════════════════════════════
BANNER

exit 0
