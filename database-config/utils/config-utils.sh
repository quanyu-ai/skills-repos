#!/usr/bin/env bash

# config-utils.sh - 配置工具函数

set -euo pipefail

# 配置文件路径
CONFIG_DIR="/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config"
ENVS_JSON="$CONFIG_DIR/environments.json"
APPS_JSON="$CONFIG_DIR/apps.json"

# 日志函数
log() {
    echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

log_info() {
    log "[INFO] $1"
}

log_warn() {
    log "[WARN] $1"
}

log_error() {
    log "[ERROR] $1" >&2
}

log_ok() {
    log "[OK] $1"
}

# 读取 environments.json 中的配置
read_env_config() {
    local env="$1"
    local key="$2"
    local default="${3:-}"
    
    if [ ! -f "$ENVS_JSON" ]; then
        log_error "配置文件不存在: $ENVS_JSON"
        return 1
    fi
    
    local value=$(jq -r --arg e "$env" --arg k "$key" '.environments[$e] | .[$k] // ""' "$ENVS_JSON")
    
    if [ -z "$value" ]; then
        if [ -z "$default" ]; then
            log_warn "配置项不存在: $env.$key，使用默认值 $default"
        fi
        echo "$default"
    else
        echo "$value"
    fi
}

# 读取数据库配置
read_db_config() {
    local env="$1"
    local key="$2"
    local default="${3:-}"
    
    local db_config=$(read_env_config "$env" "database")
    
    if [ -z "$db_config" ] || [ "$db_config" = "null" ]; then
        log_warn "数据库配置不存在: $env.database"
        return 1
    fi
    
    local value=$(jq -r --arg k "$key" '.[$k] // ""' <<<"$db_config")
    
    if [ -z "$value" ]; then
        if [ -z "$default" ]; then
            log_warn "数据库配置项不存在: $env.database.$key，使用默认值 $default"
        fi
        echo "$default"
    else
        echo "$value"
    fi
}

# 读取 app 配置
read_app_config() {
    local app="$1"
    local key="$2"
    local default="${3:-}"
    
    if [ ! -f "$APPS_JSON" ]; then
        log_error "配置文件不存在: $APPS_JSON"
        return 1
    fi
    
    local value=$(jq -r --arg a "$app" '.apps[$a] | .[$k] // ""' --arg k "$key" "$APPS_JSON")
    
    if [ -z "$value" ]; then
        if [ -z "$default" ]; then
            log_warn "应用配置项不存在: $app.$key，使用默认值 $default"
        fi
        echo "$default"
    else
        echo "$value"
    fi
}

# 验证环境名称
validate_env() {
    local env="$1"
    
    if [ -z "$env" ]; then
        log_error "环境名称不能为空"
        return 1
    fi
    
    if ! jq -e ".environments | has(\"$env\")" "$ENVS_JSON" >/dev/null; then
        log_error "无效的环境名称: $env"
        log_error "允许的环境名称: $(jq -r '.environments | keys_unsorted | join(", ")' "$ENVS_JSON")"
        return 1
    fi
    
    log_ok "环境验证通过: $env"
}

# 验证应用名称
validate_app() {
    local app="$1"
    
    if [ -z "$app" ]; then
        log_error "应用名称不能为空"
        return 1
    fi
    
    if ! jq -e ".apps | has(\"$app\")" "$APPS_JSON" >/dev/null; then
        log_error "无效的应用名称: $app"
        log_error "允许的应用名称: $(jq -r '.apps | keys_unsorted | join(", ")' "$APPS_JSON")"
        return 1
    fi
    
    log_ok "应用验证通过: $app"
}

# 检查 jq 是否可用
check_jq() {
    if ! command -v jq &>/dev/null; then
        log_error "jq 未安装"
        return 1
    fi
}

# 检查配置文件
check_config_files() {
    if [ ! -f "$ENVS_JSON" ]; then
        log_error "配置文件不存在: $ENVS_JSON"
        return 1
    fi
    
    if [ ! -f "$APPS_JSON" ]; then
        log_error "配置文件不存在: $APPS_JSON"
        return 1
    fi
    
    log_ok "配置文件检查通过"
}

# 打印配置信息
print_config() {
    local env="$1"
    
    validate_env "$env"
    
    log_info "环境配置信息:"
    log_info "  host: $(read_env_config "$env" "host")"
    log_info "  ssh_user: $(read_env_config "$env" "ssh_user")"
    log_info "  ssh_key: $(read_env_config "$env" "ssh_key")"
    log_info "  deploy_mode: $(read_env_config "$env" "deploy_mode")"
    log_info "  deploy_base_path: $(read_env_config "$env" "deploy_base_path")"
    
    if read_env_config "$env" "database"; then
        log_info "  database:"
        log_info "    type: $(read_db_config "$env" "type")"
        log_info "    host: $(read_db_config "$env" "host")"
        log_info "    port: $(read_db_config "$env" "port")"
        log_info "    database: $(read_db_config "$env" "database")"
        log_info "    username: $(read_db_config "$env" "username")"
        if [ "$(read_db_config "$env" "password")" ]; then
            log_info "    password: ***"
        fi
    fi
}

# 主函数
main() {
    check_jq
    check_config_files
    
    if [ $# -eq 0 ]; then
        log_error "请提供命令"
        log_info "可用命令:"
        log_info "  print <env>: 打印环境配置"
        log_info "  validate <env>: 验证环境配置"
        log_info "  read <env> <key>: 读取配置项"
        return 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        print)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            print_config "$1"
            ;;
        validate)
            if [ $# -eq 0 ]; then
                log_error "请提供环境名称"
                return 1
            fi
            validate_env "$1"
            ;;
        read)
            if [ $# -lt 2 ]; then
                log_error "请提供环境名称和配置项"
                return 1
            fi
            read_env_config "$1" "$2" "$3"
            ;;
        db)
            if [ $# -lt 2 ]; then
                log_error "请提供环境名称和配置项"
                return 1
            fi
            read_db_config "$1" "$2" "$3"
            ;;
        app)
            if [ $# -lt 2 ]; then
                log_error "请提供应用名称和配置项"
                return 1
            fi
            read_app_config "$1" "$2" "$3"
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