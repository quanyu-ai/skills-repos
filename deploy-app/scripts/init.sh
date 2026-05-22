#!/bin/bash
# init.sh - deploy-app skill 初始化向导（交互式骨架）
# 引导用户从模板生成 apps.json / environments.json 草稿

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

cat <<'BANNER'
═══════════════════════════════════════════════════════
  deploy-app skill — Init Wizard (Phase 1)
═══════════════════════════════════════════════════════
本向导帮你从模板创建 apps.json / environments.json 草稿。
真正的部署逻辑（deploy.sh）将在 Phase 2 实装。
BANNER

# 1. apps.json
if [ -f "$CONFIG_DIR/apps.json" ]; then
    echo "✅ apps.json 已存在，跳过"
else
    echo ""
    echo "▶ 复制 apps.json 模板"
    cp "$CONFIG_DIR/apps.json.template" "$CONFIG_DIR/apps.json"
    echo "  已创建：$CONFIG_DIR/apps.json"
fi

# 2. environments.json
if [ -f "$CONFIG_DIR/environments.json" ]; then
    echo "✅ environments.json 已存在，跳过"
else
    echo ""
    echo "▶ 复制 environments.json 模板"
    cp "$CONFIG_DIR/environments.json.template" "$CONFIG_DIR/environments.json"
    echo "  已创建：$CONFIG_DIR/environments.json"
fi

# 3. 智能识别项目框架并推荐命令
detect_framework() {
    local project_path="$1"
    if [ -f "$project_path/package.json" ]; then
        local pkg_json=$(cat "$project_path/package.json")
        if echo "$pkg_json" | grep -q "next"; then
            echo "nextjs"
        elif echo "$pkg_json" | grep -q "nest"; then
            echo "nestjs"
        elif echo "$pkg_json" | grep -q "vue"; then
            echo "vue"
        elif echo "$pkg_json" | grep -q "react"; then
            echo "react"
        else
            echo "static"
        fi
    else
        echo "static"
    fi
}

get_default_build_cmd() {
    local framework="$1"
    case "$framework" in
        "nextjs") echo "pnpm install --frozen-lockfile && pnpm build" ;;
        "nestjs") echo "pnpm install --frozen-lockfile && pnpm build" ;;
        "vue") echo "pnpm install --frozen-lockfile && pnpm build" ;;
        "react") echo "pnpm install --frozen-lockfile && pnpm build" ;;
        "static") echo "echo 'No build needed for static site'" ;;
        *) echo "pnpm install --frozen-lockfile && pnpm build" ;;
    esac
}

get_default_start_cmd() {
    local framework="$1"
    case "$framework" in
        "nextjs") echo "pnpm start" ;;
        "nestjs") echo "pnpm start:prod" ;;
        "vue") echo "pnpm serve" ;;
        "react") echo "pnpm start" ;;
        "static") echo "python3 -m http.server 8080" ;;
        *) echo "pnpm start" ;;
    esac
}

# 4. Git 仓库地址验证
validate_git_url() {
    local git_url="$1"
    # 允许留空
    if [ -z "$git_url" ]; then
        return 0
    fi
    # 验证 Git URL 格式
    if echo "$git_url" | grep -q -E "(git@|https?://).*\.git$"; then
        return 0
    else
        return 1
    fi
}

# 5. 简化的交互式流程
echo ""
echo "▶ 现在请补充第一个应用信息"
read -rp "  应用 key（如 console）: " APP_KEY
read -rp "  display_name（如 权舆系统展示控制台）: " APP_DISPLAY
read -rp "  project_path（绝对路径）: " APP_PATH

# 智能识别框架并推荐命令
APP_FW=$(detect_framework "$APP_PATH")
echo "  自动识别到框架: $APP_FW"

DEFAULT_BUILD=$(get_default_build_cmd "$APP_FW")
read -rp "  构建命令（默认: $DEFAULT_BUILD）: " BUILD_CMD
BUILD_CMD=${BUILD_CMD:-$DEFAULT_BUILD}

DEFAULT_START=$(get_default_start_cmd "$APP_FW")
read -rp "  启动命令（默认: $DEFAULT_START）: " START_CMD
START_CMD=${START_CMD:-$DEFAULT_START}

# Git 仓库地址（允许留空）
while true; do
    read -rp "  Git 仓库地址（可选，留空则后续补充）: " REPO_URL
    if validate_git_url "$REPO_URL"; then
        break
    else
        echo "  错误：Git 仓库地址格式无效，应为 git@github.com:user/repo.git 或 https://github.com/user/repo.git"
    fi
done

read -rp "  demo 环境端口（如 3101）: " DEMO_PORT

# 6. 自动写入配置文件
cat <<EOT

═══════════════════════════════════════════════════════
正在自动更新配置文件...
═══════════════════════════════════════════════════════

EOT

# 更新 apps.json
if [ -f "$CONFIG_DIR/apps.json" ]; then
    TMP_FILE=$(mktemp)
    jq '.apps += {
        "'"$APP_KEY"'": {
            "display_name": "'"$APP_DISPLAY"'",
            "repo_url": "'"${REPO_URL:-""}"'",
            "project_path": "'"$APP_PATH"'",
            "build_cmd": "'"$BUILD_CMD"'",
            "start_cmd": "'"$START_CMD"'",
            "health_path": "/api/health",
            "framework": "'"$APP_FW"'"
        }
    }' "$CONFIG_DIR/apps.json" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_DIR/apps.json"
    echo "✅ apps.json 已更新"
else
    echo "❌ apps.json 不存在"
    exit 1
fi

# 更新 environments.json
if [ -f "$CONFIG_DIR/environments.json" ]; then
    TMP_FILE=$(mktemp)
    jq '.environments.demo.apps += {
        "'"$APP_KEY"'": {
            "port": '"$DEMO_PORT"',
            "pm2_name": "demo-'"$APP_KEY"'"
        }
    }' "$CONFIG_DIR/environments.json" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_DIR/environments.json"
    echo "✅ environments.json 已更新"
else
    echo "❌ environments.json 不存在"
    exit 1
fi

cat <<EOT

═══════════════════════════════════════════════════════
✅ 配置文件更新完成！

完成后请跑：
  bash $SKILL_DIR/scripts/doctor.sh
EOT
