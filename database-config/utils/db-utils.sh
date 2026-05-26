#!/usr/bin/env bash

# db-utils.sh - 数据库工具函数

set -euo pipefail

# 加载配置工具函数【修修: 被 source 时 $0 不是 db-utils.sh、要用 BASH_SOURCE】
source "$(dirname "${BASH_SOURCE[0]}")/config-utils.sh"

# 数据库连接字符串生成函数
generate_connection_string() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    case "$type" in
        postgresql)
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            echo "postgresql://${user}:${pass}@${host}:${port}/${db}"
            ;;
        mysql)
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            echo "mysql://${user}:${pass}@${host}:${port}/${db}"
            ;;
        redis)
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local pass=$(read_db_config "$env" "password")
            if [ -z "$pass" ]; then
                echo "redis://${host}:${port}"
            else
                echo "redis://:${pass}@${host}:${port}"
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 检查数据库客户端是否可用
check_db_client() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    case "$type" in
        postgresql)
            if ! command -v psql &>/dev/null; then
                log_error "PostgreSQL 客户端未安装"
                return 1
            fi
            ;;
        mysql)
            if ! command -v mysql &>/dev/null; then
                log_error "MySQL 客户端未安装"
                return 1
            fi
            ;;
        redis)
            if ! command -v redis-cli &>/dev/null; then
                log_error "Redis 客户端未安装"
                return 1
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 检查数据库连接
check_connection() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    check_db_client "$env"
    
    log_info "检查 $type 数据库连接..."
    
    case "$type" in
        postgresql)
            local conn_str=$(generate_connection_string "$env")
            if psql "$conn_str" -c "SELECT 1;" &>/dev/null; then
                log_ok "$type 数据库连接成功"
                return 0
            else
                log_error "$type 数据库连接失败"
                return 1
            fi
            ;;
        mysql)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            
            if mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db" -e "SELECT 1;" &>/dev/null; then
                log_ok "$type 数据库连接成功"
                return 0
            else
                log_error "$type 数据库连接失败"
                return 1
            fi
            ;;
        redis)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local pass=$(read_db_config "$env" "password")
            
            if [ -z "$pass" ]; then
                if redis-cli -h "$host" -p "$port" ping &>/dev/null; then
                    log_ok "$type 数据库连接成功"
                    return 0
                else
                    log_error "$type 数据库连接失败"
                    return 1
                fi
            else
                if redis-cli -h "$host" -p "$port" -a "$pass" --no-auth-warning ping &>/dev/null; then
                    log_ok "$type 数据库连接成功"
                    return 0
                else
                    log_error "$type 数据库连接失败"
                    return 1
                fi
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 执行 SQL 文件
execute_sql_file() {
    local env="$1"
    local sql_file="$2"
    
    if [ ! -f "$sql_file" ]; then
        log_error "SQL 文件不存在: $sql_file"
        return 1
    fi
    
    local type=$(read_db_config "$env" "type")
    
    log_info "执行 SQL 文件: $sql_file"
    
    case "$type" in
        postgresql)
            local conn_str=$(generate_connection_string "$env")
            if psql "$conn_str" -f "$sql_file"; then
                log_ok "SQL 文件执行成功"
                return 0
            else
                log_error "SQL 文件执行失败"
                return 1
            fi
            ;;
        mysql)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            
            if mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db" < "$sql_file"; then
                log_ok "SQL 文件执行成功"
                return 0
            else
                log_error "SQL 文件执行失败"
                return 1
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 获取数据库版本
get_db_version() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    check_db_client "$env"
    
    case "$type" in
        postgresql)
            local conn_str=$(generate_connection_string "$env")
            echo "$(psql "$conn_str" -t -c "SHOW server_version;")"
            ;;
        mysql)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            
            echo "$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db" -e "SELECT VERSION();" -N)"
            ;;
        redis)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local pass=$(read_db_config "$env" "password")
            
            if [ -z "$pass" ]; then
                echo "$(redis-cli -h "$host" -p "$port" info server | grep redis_version | cut -d: -f2 | tr -d '\r\n')"
            else
                echo "$(redis-cli -h "$host" -p "$port" -a "$pass" --no-auth-warning info server | grep redis_version | cut -d: -f2 | tr -d '\r\n')"
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 列出数据库表
list_tables() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    check_db_client "$env"
    check_connection "$env"
    
    case "$type" in
        postgresql)
            local conn_str=$(generate_connection_string "$env")
            psql "$conn_str" -c "\dt"
            ;;
        mysql)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            
            mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db" -e "SHOW TABLES;"
            ;;
        redis)
            log_info "Redis 不支持表查询"
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 获取数据库大小
get_db_size() {
    local env="$1"
    local type=$(read_db_config "$env" "type")
    
    check_db_client "$env"
    check_connection "$env"
    
    case "$type" in
        postgresql)
            local conn_str=$(generate_connection_string "$env")
            echo "$(psql "$conn_str" -t -c "SELECT pg_size_pretty(pg_database_size(current_database()));")"
            ;;
        mysql)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local db=$(read_db_config "$env" "database")
            local user=$(read_db_config "$env" "username")
            local pass=$(read_db_config "$env" "password")
            
            echo "$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" "$db" -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size in MB' FROM information_schema.tables WHERE table_schema = '${db}';")" MB
            ;;
        redis)
            local conn_str=$(generate_connection_string "$env")
            local host=$(read_db_config "$env" "host")
            local port=$(read_db_config "$env" "port")
            local pass=$(read_db_config "$env" "password")
            
            if [ -z "$pass" ]; then
                echo "$(redis-cli -h "$host" -p "$port" info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r\n')"
            else
                echo "$(redis-cli -h "$host" -p "$port" -a "$pass" --no-auth-warning info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r\n')"
            fi
            ;;
        *)
            log_error "不支持的数据库类型: $type"
            return 1
            ;;
    esac
}

# 打印数据库信息
print_db_info() {
    local env="$1"
    
    validate_env "$env"
    check_connection "$env"
    
    log_info "数据库信息:"
    log_info "  类型: $(read_db_config "$env" "type")"
    log_info "  版本: $(get_db_version "$env")"
    log_info "  大小: $(get_db_size "$env")"
    log_info "  表数: $(list_tables "$env" | grep -v '----' | grep -v '(0 rows)' | wc -l)"
}

# 主函数
main() {
    if [ $# -eq 0 ]; then
        log_error "请提供命令"
        log_info "可用命令:"
        log_info "  connection <env>: 生成数据库连接字符串"
        log_info "  check <env>: 检查数据库连接"
        log_info "  version <env>: 获取数据库版本"
        log_info "  tables <env>: 列出数据库表"
        log_info "  size <env>: 获取数据库大小"
        log_info "  info <env>: 打印数据库信息"
        log_info "  exec <env> <sql-file>: 执行 SQL 文件"
        return 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        connection)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            generate_connection_string "$1"
            ;;
        check)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            check_connection "$1"
            ;;
        version)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            get_db_version "$1"
            ;;
        tables)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            list_tables "$1"
            ;;
        size)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            get_db_size "$1"
            ;;
        info)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            print_db_info "$1"
            ;;
        exec)
            if [ $# -lt 2 ]; then
                log_error "请提供环境名称和 SQL 文件路径"
                return 1
            fi
            execute_sql_file "$1" "$2"
            ;;
        *)
            log_error "未知命令: $command"
            return 1
            ;;
    esac
}

# 如果直接调用此脚本，则执行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi