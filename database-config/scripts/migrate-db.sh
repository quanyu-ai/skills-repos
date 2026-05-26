#!/usr/bin/env bash
# migrate-db.sh — 数据库迁移路由器（D 阶段重构）
#
# 设计：本脚本仅做"识别 + 派发 + 收集结果"，绝不直接执行 migrate。
#       真正的迁移由 migrators/<tool>.sh 完成。
#
# 用法:
#   ./migrate-db.sh <env> <app>                          兼容
#   ./migrate-db.sh <env> --app <key> [--non-interactive] 推荐
#
# 参考: knowledge-repos/management/PRINCIPLES/MIGRATION-ARCHITECTURE.md
#       knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATORS_DIR="$PROJECT_DIR/migrators"
CONFIG_DIR="/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config"

source "$PROJECT_DIR/utils/config-utils.sh"
source "$PROJECT_DIR/utils/db-utils.sh"

# ============================================================
# 配置读取
# ============================================================
_app_get() {
    local app="$1" path="$2"
    jq -r --arg a "$app" \
        ".apps[\$a] | $path // empty" \
        "$CONFIG_DIR/apps.json"
}

_app_env_get() {
    local app="$1" env="$2" path="$3"
    jq -r --arg a "$app" --arg e "$env" \
        ".apps[\$a].env_config[\$e] | $path // empty" \
        "$CONFIG_DIR/apps.json"
}

_app_db_field() {
    local app="$1" env="$2" field="$3"
    _app_env_get "$app" "$env" ".database.\"$field\""
}

_app_mig_field() {
    # 优先 env_config.<env>.migration.<field>，回退 app 根 migration.<field>
    local app="$1" env="$2" field="$3"
    local v
    v=$(_app_env_get "$app" "$env" ".migration.$field")
    if [ -n "$v" ] && [ "$v" != "null" ]; then
        echo "$v"; return
    fi
    _app_get "$app" ".migration.$field"
}

_app_mig_cmd() {
    local app="$1" env="$2" key="$3"
    local v
    v=$(_app_env_get "$app" "$env" ".migration.commands.\"$key\"")
    if [ -n "$v" ] && [ "$v" != "null" ]; then
        echo "$v"; return
    fi
    _app_get "$app" ".migration.commands.\"$key\""
}

_app_project_path() {
    local app="$1" env="$2"
    local p
    p=$(_app_env_get "$app" "$env" ".project_path")
    [ -n "$p" ] && [ "$p" != "null" ] && { echo "$p"; return; }
    _app_get "$app" '.project_code_path // .project_path'
}

# ============================================================
# 自动探测（fallback）
# 返回 stdout 两行： tool=<x>\nschema_path=<y>
# 失败返回退出码 1
# ============================================================
_probe_tool() {
    local proj="$1" db_type="$2"
    # 1~4: prisma 各种位置
    local candidates=(
        "$proj/prisma/schema.prisma"
        "$proj/packages/db/prisma/schema.prisma"
    )
    # 5: monorepo 通配
    for f in "$proj"/packages/*/prisma/schema.prisma "$proj"/apps/*/prisma/schema.prisma; do
        [ -f "$f" ] && candidates+=("$f")
    done

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            local prov
            prov=$(awk '/^[[:space:]]*datasource[[:space:]]/{flag=1;next} flag && /\}/{flag=0} flag && /provider[[:space:]]*=/{match($0,/"[^"]+"/); if(RSTART){print substr($0,RSTART+1,RLENGTH-2); exit}}' "$cand")
            case "$prov" in
                postgresql)
                    echo "tool=prisma-postgresql"
                    echo "schema_path=$(realpath --relative-to="$proj" "$cand")"
                    return 0 ;;
                mysql)
                    echo "tool=prisma-mysql"
                    echo "schema_path=$(realpath --relative-to="$proj" "$cand")"
                    return 0 ;;
                *) ;;
            esac
        fi
    done

    # raw-sql 探测：常见 sql 目录
    for d in db/migrations sql migrations chenxi-backend/sql; do
        if [ -d "$proj/$d" ] && ls "$proj/$d"/*.sql >/dev/null 2>&1; then
            echo "tool=raw-sql"
            echo "schema_path=$d"
            return 0
        fi
    done

    return 1
}

# ============================================================
# 主路由
# ============================================================
route_and_dispatch() {
    local env="$1" app="$2"
    log_info "=========================================="
    log_info "[migrate-db 路由器] env=$env app=$app"
    log_info "=========================================="

    # 1. 收集 DB 连接
    local db_type db_host db_port db_name db_user db_pass
    db_type=$(_app_db_field "$app" "$env" "type")
    db_host=$(_app_db_field "$app" "$env" "host")
    db_port=$(_app_db_field "$app" "$env" "port")
    db_name=$(_app_db_field "$app" "$env" "database")
    db_user=$(_app_db_field "$app" "$env" "username")
    db_pass=$(_app_db_field "$app" "$env" "password")

    [ -z "$db_type" ] && { log_error "apps.json[$app].env_config[$env].database 缺失"; return 1; }

    # 2. 收集项目路径
    local proj_path
    proj_path=$(_app_project_path "$app" "$env")
    [ -z "$proj_path" ] && { log_error "找不到项目路径"; return 1; }
    [ -d "$proj_path" ] || { log_error "项目路径不存在: $proj_path"; return 1; }

    # 3. 路由：显式 migration.tool 优先
    local tool schema_path cmd_deploy cmd_seed
    tool=$(_app_mig_field "$app" "$env" "tool")
    schema_path=$(_app_mig_field "$app" "$env" "schema_path")
    cmd_deploy=$(_app_mig_cmd "$app" "$env" "deploy")
    cmd_seed=$(_app_mig_cmd "$app" "$env" "seed")

    if [ -n "$tool" ]; then
        log_info "[路由] 显式声明: tool=$tool schema_path=$schema_path"
    else
        log_info "[路由] 未显式声明，自动探测..."
        local probe_out
        if ! probe_out=$(_probe_tool "$proj_path" "$db_type"); then
            log_error "无法自动探测迁移工具"
            log_error "请在 apps.json env_config.$env.migration 显式声明 tool 和 schema_path"
            log_error "参见: knowledge-repos/management/PRINCIPLES/MIGRATION-ARCHITECTURE.md"
            return 1
        fi
        tool=$(echo "$probe_out" | grep '^tool=' | cut -d= -f2)
        schema_path=$(echo "$probe_out" | grep '^schema_path=' | cut -d= -f2-)
        log_ok "[路由] 自动探测命中: tool=$tool schema_path=$schema_path"
    fi

    # 4. 检查 migrator 存在
    local migrator="$MIGRATORS_DIR/$tool.sh"
    if [ ! -f "$migrator" ]; then
        log_error "migrator 未实装: $tool"
        log_error "已可用: $(ls "$MIGRATORS_DIR" | grep '\.sh$' | tr '\n' ' ')"
        if [ -f "$migrator.template" ]; then
            log_error "存在 template，可参照实装: $migrator.template"
        fi
        return 1
    fi

    # 5. 派发
    log_info "[派发] $migrator"
    DB_HOST="$db_host" DB_PORT="$db_port" DB_NAME="$db_name" \
    DB_USER="$db_user" DB_PASSWORD="$db_pass" DB_TYPE="$db_type" \
    PROJECT_PATH="$proj_path" SCHEMA_PATH="$schema_path" \
    COMMAND_DEPLOY="${cmd_deploy:-}" COMMAND_SEED="${cmd_seed:-}" \
    ENV_NAME="$env" \
    bash "$migrator"
    local rc=$?
    log_info "[结果] migrator exit=$rc"
    return $rc
}

# ============================================================
# CLI
# ============================================================
print_help() {
    cat <<'EOF'
用法:
  migrate-db.sh <env> <app>                          兼容形参
  migrate-db.sh <env> --app <key> [--non-interactive] 推荐形参

环境: proto | test | demo | prod

本脚本是路由器，只识别和派发；实际迁移由 migrators/<tool>.sh 执行。

参见:
  knowledge-repos/management/PRINCIPLES/MIGRATION-ARCHITECTURE.md
  knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md
EOF
}

ENV=""; APP=""; NON_INTERACTIVE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        print_help; exit 0 ;;
        --app)            APP="$2"; shift 2 ;;
        --non-interactive|--auto-yes) NON_INTERACTIVE=1; shift ;;
        proto|test|demo|prod) ENV="$1"; shift ;;
        *)
            if [ -z "$APP" ] && [ -n "$ENV" ]; then APP="$1"; shift; continue; fi
            echo "无效参数: $1" >&2; print_help; exit 1
            ;;
    esac
done

[ -z "$ENV" ] && { echo "未指定环境" >&2; print_help; exit 1; }
[ -z "$APP" ] && { echo "未指定 app" >&2; print_help; exit 1; }

route_and_dispatch "$ENV" "$APP"
exit $?
