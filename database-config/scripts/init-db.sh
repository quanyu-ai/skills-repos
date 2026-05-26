#!/usr/bin/env bash
# init-db.sh - 数据库初始化脚本
#
# 用法:
#   ./init-db.sh <env>                              旧行为：env-level database 配置初始化
#   ./init-db.sh <env> --app <key> [--non-interactive]
#                                                   新行为：从 apps.json.env_config 取库配置创建
#
# 参考: knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config"

source "$PROJECT_DIR/utils/config-utils.sh"
source "$PROJECT_DIR/utils/db-utils.sh"

# ----------------------------------------------------------------
# 从 apps.json 读 app 在 env 下的 database 字段
# ----------------------------------------------------------------
_app_db_get() {
    local app="$1" env="$2" field="$3"
    jq -r --arg a "$app" --arg e "$env" --arg f "$field" \
        ".apps[\$a].env_config[\$e].database[\$f] // empty" \
        "$CONFIG_DIR/apps.json"
}

# ----------------------------------------------------------------
# 旧 env-level 初始化（保留兼容）
# ----------------------------------------------------------------
init_postgres_env() {
    local env="$1"
    local host=$(read_db_config "$env" "host")
    local port=$(read_db_config "$env" "port")
    local db_name=$(read_db_config "$env" "database")
    local username=$(read_db_config "$env" "username")
    local password=$(read_db_config "$env" "password")
    _init_postgres "$host" "$port" "$db_name" "$username" "$password"
}

init_mysql_env() {
    local env="$1"
    local host=$(read_db_config "$env" "host")
    local port=$(read_db_config "$env" "port")
    local db_name=$(read_db_config "$env" "database")
    local username=$(read_db_config "$env" "username")
    local password=$(read_db_config "$env" "password")
    _init_mysql "$host" "$port" "$db_name" "$username" "$password"
}

# ----------------------------------------------------------------
# 通用核心实现
# ----------------------------------------------------------------
# PostgreSQL: 注意 CREATE DATABASE 不支持 IF NOT EXISTS，需先查 pg_database
_init_postgres() {
    local host="$1" port="$2" db_name="$3" username="$4" password="$5"
    log_info "初始化 PostgreSQL 数据库 $db_name@$host:$port (user=$username)"

    # 1. 检查数据库是否已存在
    local exists
    exists=$(PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null || true)
    if [ "$exists" = "1" ]; then
        log_warn "数据库 $db_name 已存在，跳过 CREATE"
    else
        log_info "创建数据库 $db_name..."
        if ! PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d postgres \
            -c "CREATE DATABASE \"${db_name}\";" >/dev/null 2>&1; then
            log_error "无法创建数据库 $db_name"
            return 1
        fi
        log_ok "数据库 $db_name 已创建"
    fi

    # 2. 创建扩展
    log_info "创建数据库扩展 uuid-ossp..."
    PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$username" -d "$db_name" \
        -c "CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";" >/dev/null 2>&1 \
        || log_warn "无法创建 uuid-ossp 扩展（可忽略）"

    log_ok "PostgreSQL 初始化完成: $db_name"
}

_init_mysql() {
    local host="$1" port="$2" db_name="$3" username="$4" password="$5"
    log_info "初始化 MySQL 数据库 $db_name@$host:$port (user=$username)"

    if ! mysql -h "$host" -P "$port" -u "$username" -p"$password" \
        -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        >/dev/null 2>&1; then
        log_error "无法创建数据库 $db_name"
        return 1
    fi
    log_ok "MySQL 数据库 $db_name 创建完成"
}

# ----------------------------------------------------------------
# 新接口：按 app 初始化
# ----------------------------------------------------------------
init_app_database() {
    local env="$1" app="$2"
    log_info "按 app 初始化数据库 ($env / $app)..."

    local type=$(_app_db_get "$app" "$env" "type")
    local host=$(_app_db_get "$app" "$env" "host")
    local port=$(_app_db_get "$app" "$env" "port")
    local db_name=$(_app_db_get "$app" "$env" "database")
    local username=$(_app_db_get "$app" "$env" "username")
    local password=$(_app_db_get "$app" "$env" "password")

    [ -z "$type" ] && { log_error "apps.json[$app].env_config[$env].database 缺失"; return 1; }

    case "$type" in
        postgresql) _init_postgres "$host" "$port" "$db_name" "$username" "$password" ;;
        mysql)      _init_mysql    "$host" "$port" "$db_name" "$username" "$password" ;;
        redis)      log_warn "Redis 无需 init"; return 0 ;;
        *) log_error "不支持的 db type: $type"; return 1 ;;
    esac
}

# ----------------------------------------------------------------
# 旧入口：按 env-level
# ----------------------------------------------------------------
init_database_env_legacy() {
    local env="$1"
    log_info "[legacy] 按 env-level 初始化数据库 ($env)..."
    check_config_files
    validate_env "$env"
    check_db_client "$env"
    local db_type=$(read_db_config "$env" "type")
    case "$db_type" in
        postgresql) init_postgres_env "$env" ;;
        mysql)      init_mysql_env "$env" ;;
        redis)      log_info "Redis 无需 init"; return 0 ;;
        *) log_error "不支持的 db type: $db_type"; return 1 ;;
    esac
}

# ----------------------------------------------------------------
# CLI
# ----------------------------------------------------------------
print_help() {
    cat <<EOF
用法:
  $0 <env>                              旧行为：env-level database 初始化
  $0 <env> --app <key> [--non-interactive]
                                        新行为：从 apps.json.env_config 读配置

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
        *) echo "无效参数: $1" >&2; print_help; exit 1 ;;
    esac
done

[ -z "$ENV" ] && { echo "未指定环境" >&2; print_help; exit 1; }

if [ -n "$APP" ]; then
    init_app_database "$ENV" "$APP"
    exit $?
else
    init_database_env_legacy "$ENV"
    exit $?
fi
