#!/usr/bin/env bash
# migrate-db.sh - 数据库迁移脚本
#
# 用法:
#   ./migrate-db.sh <env> <app>                    旧行为（兼容）
#   ./migrate-db.sh <env> --app <key> [--non-interactive]
#                                                  新行为：明确从 apps.json.env_config 读配置
#
# 参考: knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config"

source "$PROJECT_DIR/utils/config-utils.sh"
source "$PROJECT_DIR/utils/db-utils.sh"

# ----------------------------------------------------------------
# 从 apps.json 读 app+env database 字段
# ----------------------------------------------------------------
_app_db_get() {
    local app="$1" env="$2" field="$3"
    jq -r --arg a "$app" --arg e "$env" --arg f "$field" \
        ".apps[\$a].env_config[\$e].database[\$f] // empty" \
        "$CONFIG_DIR/apps.json"
}

_app_project_path() {
    local app="$1" env="$2"
    local p
    p=$(jq -r --arg a "$app" --arg e "$env" \
        ".apps[\$a].env_config[\$e].project_path // empty" \
        "$CONFIG_DIR/apps.json")
    [ -n "$p" ] && { echo "$p"; return; }
    jq -r --arg a "$app" \
        ".apps[\$a].project_code_path // .apps[\$a].project_path // empty" \
        "$CONFIG_DIR/apps.json"
}

# 从 app+env 生成 DATABASE_URL
_app_connection_string() {
    local env="$1" app="$2"
    local type=$(_app_db_get "$app" "$env" "type")
    local host=$(_app_db_get "$app" "$env" "host")
    local port=$(_app_db_get "$app" "$env" "port")
    local db=$(_app_db_get "$app" "$env" "database")
    local user=$(_app_db_get "$app" "$env" "username")
    local pass=$(_app_db_get "$app" "$env" "password")
    case "$type" in
        postgresql) echo "postgresql://${user}:${pass}@${host}:${port}/${db}" ;;
        mysql)      echo "mysql://${user}:${pass}@${host}:${port}/${db}" ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------
# 新接口：按 app 迁移
# ----------------------------------------------------------------
migrate_app_database() {
    local env="$1" app="$2"
    log_info "按 app 迁移数据库 ($env / $app)..."

    local proj_path; proj_path=$(_app_project_path "$app" "$env")
    [ -z "$proj_path" ] && { log_error "找不到 app 项目路径: $app"; return 1; }
    [ -d "$proj_path" ] || { log_error "项目路径不存在: $proj_path"; return 1; }
    log_info "项目路径: $proj_path"

    # 找 prisma schema
    local prisma_schema=""
    for cand in "$proj_path/prisma/schema.prisma" "$proj_path/../prisma/schema.prisma" "$proj_path/../../prisma/schema.prisma"; do
        if [ -f "$cand" ]; then prisma_schema="$cand"; break; fi
    done

    local conn_str
    conn_str=$(_app_connection_string "$env" "$app") || {
        log_error "无法生成 DATABASE_URL ($env / $app)"; return 1
    }

    if [ -n "$prisma_schema" ]; then
        log_info "发现 Prisma schema: $prisma_schema"
        local prisma_root; prisma_root="$(dirname "$(dirname "$prisma_schema")")"
        log_info "执行 prisma migrate deploy..."
        if (cd "$prisma_root" && DATABASE_URL="$conn_str" \
                npx --yes prisma migrate deploy --schema "$prisma_schema"); then
            log_ok "Prisma 迁移成功"
        else
            log_error "Prisma 迁移失败"
            return 1
        fi
        # seed (可选, 失败仅 warn)
        if [ -f "$proj_path/prisma/seed.ts" ] || [ -f "$prisma_root/prisma/seed.ts" ]; then
            local seed_file
            [ -f "$proj_path/prisma/seed.ts" ] && seed_file="$proj_path/prisma/seed.ts" || seed_file="$prisma_root/prisma/seed.ts"
            log_info "执行 seed: $seed_file"
            (cd "$prisma_root" && DATABASE_URL="$conn_str" npx --yes tsx "$seed_file") \
                && log_ok "seed 完成" || log_warn "seed 失败（已忽略）"
        fi
        return 0
    fi

    log_warn "未找到 Prisma schema，跳过迁移（仅 Prisma 自动迁移已实装）"
    return 0
}

# ----------------------------------------------------------------
# 旧接口（兼容）
# ----------------------------------------------------------------
migrate_database_legacy() {
    local env="$1" app="$2"
    log_info "[legacy] 数据库迁移 ($env: $app)..."
    check_config_files
    validate_env "$env"
    validate_app "$app"
    local project_path=$(read_app_config "$app" "project_path")
    [ -z "$project_path" ] || [ ! -d "$project_path" ] && {
        log_error "应用路径不存在: $project_path"; return 1
    }
    if [ -f "$project_path/prisma/schema.prisma" ]; then
        log_info "Prisma 检测到，走新接口"
        migrate_app_database "$env" "$app"
        return $?
    fi
    log_warn "[legacy] 非 Prisma 项目，已退役（TypeORM/Sequelize 接口暂不实装）"
    return 0
}

# ----------------------------------------------------------------
# CLI
# ----------------------------------------------------------------
print_help() {
    cat <<EOF
用法:
  $0 <env> <app>                          旧形参（兼容）
  $0 <env> --app <key> [--non-interactive]
                                          推荐形参

环境: proto | test | demo | prod

参见: knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md
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
            # 兼容旧形参：第二个 positional 当作 app
            if [ -z "$APP" ] && [ -n "$ENV" ]; then APP="$1"; shift; continue; fi
            echo "无效参数: $1" >&2; print_help; exit 1
            ;;
    esac
done

[ -z "$ENV" ] && { echo "未指定环境" >&2; print_help; exit 1; }
[ -z "$APP" ] && { echo "未指定 app" >&2; print_help; exit 1; }

migrate_app_database "$ENV" "$APP"
exit $?
