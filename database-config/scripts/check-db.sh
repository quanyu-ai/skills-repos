#!/usr/bin/env bash
# check-db.sh - 数据库健康检查 + 三态探测脚本
#
# 两种模式：
#   1) 健康检查模式（默认）: ./check-db.sh <env>
#   2) 三态探测模式（被 deploy.sh 编程调用）: ./check-db.sh <env> --app <key> --mode probe
#      stdout 单行返回:
#        - "missing"             数据库不存在
#        - "up_to_date"          schema 是最新
#        - "behind:<N>:<list>"   schema 落后 N 个迁移（逗号分隔名字）
#      退出码 0 = 探测成功；非 0 = 探测本身失败（不区分三态）
#
# 参考: knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="/var/lib/openclaw/.openclaw/workspace/skills/deploy-app/config"

source "$PROJECT_DIR/utils/config-utils.sh"
source "$PROJECT_DIR/utils/db-utils.sh"

# 健康检查阈值
MAX_CONNECTION_TIME=5
MIN_DISK_SPACE=1024
MAX_QUERY_TIME=3

# ----------------------------------------------------------------
# 模式 A: 健康检查（旧行为，保持兼容）
# ----------------------------------------------------------------
check_health() {
    local env="$1"
    log_info "开始健康检查 ($env)..."
    check_config_files
    validate_env "$env"
    log_info "检查数据库连接..."
    if ! check_connection "$env"; then
        log_error "数据库连接失败"
        return 1
    fi
    log_info "检查数据库版本..."
    local version=$(get_db_version "$env")
    [ -z "$version" ] && { log_error "无法获取数据库版本"; return 1; }
    log_info "数据库版本: $version"
    log_info "检查数据库大小..."
    local size=$(get_db_size "$env")
    log_info "数据库大小: $size"
    log_info "检查数据库表数..."
    local table_count=$(list_tables "$env" 2>/dev/null | grep -v '----' | grep -v '(0 rows)' | wc -l)
    log_info "数据库表数: $table_count"
    log_ok "数据库健康检查通过"
    return 0
}

# ----------------------------------------------------------------
# 模式 B: 三态探测（programmatic, 给 deploy.sh 调）
# ----------------------------------------------------------------
# 工具：从 apps.json 读取 app 在 env 下的 database 配置
# G 阶段：远端 DB 支持。如果 override 了 host/port（开 SSH 隧道后），返回 override 值
PROBE_HOST_OVERRIDE=""
PROBE_PORT_OVERRIDE=""
_probe_read_db() {
    local app="$1" env="$2" field="$3"
    if [ -n "$PROBE_HOST_OVERRIDE" ] && [ "$field" = "host" ]; then
        echo "$PROBE_HOST_OVERRIDE"; return
    fi
    if [ -n "$PROBE_PORT_OVERRIDE" ] && [ "$field" = "port" ]; then
        echo "$PROBE_PORT_OVERRIDE"; return
    fi
    jq -r --arg a "$app" --arg e "$env" --arg f "$field" \
        ".apps[\$a].env_config[\$e].database[\$f] // empty" \
        "$CONFIG_DIR/apps.json"
}

_probe_app_path() {
    local app="$1" env="$2"
    # 优先 env_config.<env>.project_path
    local p
    p=$(jq -r --arg a "$app" --arg e "$env" \
        ".apps[\$a].env_config[\$e].project_path // empty" \
        "$CONFIG_DIR/apps.json")
    [ -n "$p" ] && { echo "$p"; return; }
    # 兜底 project_code_path / project_path
    jq -r --arg a "$app" \
        ".apps[\$a].project_code_path // .apps[\$a].project_path // empty" \
        "$CONFIG_DIR/apps.json"
}

# 检测数据库是否存在
_probe_db_exists() {
    local env="$1" app="$2"
    local type=$(_probe_read_db "$app" "$env" "type")
    local host=$(_probe_read_db "$app" "$env" "host")
    local port=$(_probe_read_db "$app" "$env" "port")
    local db_name=$(_probe_read_db "$app" "$env" "database")
    local user=$(_probe_read_db "$app" "$env" "username")
    local pass=$(_probe_read_db "$app" "$env" "password")

    case "$type" in
        postgresql)
            # 用同一账号连 postgres 库判定
            local out
            out=$(PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres -tAc \
                "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null || true)
            [ "$out" = "1" ] && return 0 || return 1
            ;;
        mysql)
            local out
            out=$(mysql -h "$host" -P "$port" -u "$user" -p"$pass" -N -B -e \
                "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}'" \
                2>/dev/null || true)
            [ -n "$out" ] && return 0 || return 1
            ;;
        redis)
            # redis 无 schema 概念，永远视为 up_to_date
            return 0
            ;;
        *)
            echo "[probe] 未支持的数据库类型: $type" >&2
            return 2
            ;;
    esac
}

# 检测 schema 状态（数据库已存在的前提下）
# 输出: "up_to_date" 或 "behind:<N>:<list>"
_probe_schema_state() {
    local env="$1" app="$2"
    local proj_path; proj_path=$(_probe_app_path "$app" "$env")

    # 优先 Prisma
    local prisma_schema=""
    for cand in "$proj_path/prisma/schema.prisma" "$proj_path/../prisma/schema.prisma" "$proj_path/../../prisma/schema.prisma"; do
        if [ -f "$cand" ]; then prisma_schema="$cand"; break; fi
    done

    if [ -n "$prisma_schema" ]; then
        local conn_str
        conn_str="$(generate_connection_string_for_app "$env" "$app")" || {
            echo "behind:?:unknown(prisma-conn-fail)"; return 0
        }
        local prisma_root
        prisma_root="$(dirname "$(dirname "$prisma_schema")")"
        # cd 到 prisma 项目根，确保 npx 能解析
        local status_out
        status_out=$(cd "$prisma_root" && DATABASE_URL="$conn_str" \
            npx --yes prisma migrate status --schema "$prisma_schema" 2>&1 || true)
        if echo "$status_out" | grep -q "Database schema is up to date"; then
            echo "up_to_date"; return 0
        fi
        if echo "$status_out" | grep -qE "Following migrations? have not yet been applied"; then
            # 抓未应用迁移名（行首形如 "20260520_xxx"）
            local pending
            pending=$(echo "$status_out" | grep -oE '^[0-9]{8,}_[A-Za-z0-9_]+' | sort -u | head -50 | paste -sd ',' -)
            local cnt
            cnt=$(echo "$pending" | tr ',' '\n' | grep -c . || echo 0)
            echo "behind:${cnt}:${pending}"; return 0
        fi
        # 不能判定 → 当作落后但未知
        echo "behind:?:unknown(prisma-status-unclear)"; return 0
    fi

    # 兜底：无 ORM 检测能力 → 视为 up_to_date（保守，避免误改 prod）
    echo "up_to_date"
}

# 给某 app 生成 DATABASE_URL（不同于 generate_connection_string 只读 env-level）
generate_connection_string_for_app() {
    local env="$1" app="$2"
    local type=$(_probe_read_db "$app" "$env" "type")
    local host=$(_probe_read_db "$app" "$env" "host")
    local port=$(_probe_read_db "$app" "$env" "port")
    local db=$(_probe_read_db "$app" "$env" "database")
    local user=$(_probe_read_db "$app" "$env" "username")
    local pass=$(_probe_read_db "$app" "$env" "password")
    case "$type" in
        postgresql) echo "postgresql://${user}:${pass}@${host}:${port}/${db}" ;;
        mysql)      echo "mysql://${user}:${pass}@${host}:${port}/${db}" ;;
        redis)
            if [ -z "$pass" ]; then echo "redis://${host}:${port}"; else echo "redis://:${pass}@${host}:${port}"; fi
            ;;
        *) return 1 ;;
    esac
}

probe_state() {
    local env="$1" app="$2"
    if _probe_db_exists "$env" "$app"; then
        _probe_schema_state "$env" "$app"
    else
        echo "missing"
    fi
}

# ----------------------------------------------------------------
# 参数解析
# ----------------------------------------------------------------
print_help() {
    cat <<EOF
用法:
  $0 <env>                              健康检查模式（默认）
  $0 <env> --app <key> --mode probe     三态探测模式（被 deploy.sh 调）

环境: proto | test | demo | prod

probe 模式 stdout 返回:
  missing               数据库不存在
  up_to_date            schema 最新
  behind:<N>:<csv>      schema 落后 N 个迁移（逗号分隔）

参见: knowledge-repos/management/PRINCIPLES/DB-DEPLOY-INTEGRATION.md
EOF
}

ENV=""; APP=""; MODE="health"; VIA_SSH=""; SSH_KEY_VIA=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) print_help; exit 0 ;;
        --app)     APP="$2"; shift 2 ;;
        --mode)    MODE="$2"; shift 2 ;;
        --via-ssh) VIA_SSH="$2"; shift 2 ;;
        --ssh-key) SSH_KEY_VIA="$2"; shift 2 ;;
        proto|test|demo|prod) ENV="$1"; shift ;;
        *) echo "无效参数: $1" >&2; print_help; exit 1 ;;
    esac
done

[ -z "$ENV" ] && { echo "未指定环境" >&2; print_help; exit 1; }

case "$MODE" in
    health)
        if check_health "$ENV"; then
            log_ok "数据库健康检查通过 ($ENV)"; exit 0
        else
            log_error "数据库健康检查失败 ($ENV)"; exit 1
        fi
        ;;
    probe)
        [ -z "$APP" ] && { echo "probe 模式需要 --app <key>" >&2; exit 1; }
        # G 阶段：如 --via-ssh 传入，开 SSH 隧道到远端 DB
        if [ -n "$VIA_SSH" ]; then
            REAL_DB_HOST=$(_probe_read_db "$APP" "$ENV" "host")
            REAL_DB_PORT=$(_probe_read_db "$APP" "$ENV" "port")
            [ -n "$REAL_DB_HOST" ] || { echo "probe: 读不到 db host" >&2; exit 1; }
            [ -n "$REAL_DB_PORT" ] || REAL_DB_PORT=5432
            # 从远端视角，db 一般在 127.0.0.1（同机 PG）。如果 host 是远端公网 IP，同机访问也能通
            # 随机本地端口
            LOCAL_PORT=$(comm -23 <(seq 15432 15532 | sort) <(ss -tlnH | awk '{print $4}' | awk -F: '{print $NF}' | sort -u) | shuf -n 1)
            [ -n "$LOCAL_PORT" ] || LOCAL_PORT=15432
            SSH_OPTS_TUN=(-o StrictHostKeyChecking=no -o BatchMode=yes)
            [ -n "$SSH_KEY_VIA" ] && SSH_OPTS_TUN+=(-i "${SSH_KEY_VIA/#\~/$HOME}")
            # 开后台隧道
            ssh "${SSH_OPTS_TUN[@]}" -fN -L "${LOCAL_PORT}:127.0.0.1:${REAL_DB_PORT}" "$VIA_SSH" 2>/dev/null \
                || { echo "probe: SSH 隧道开启失败 ($VIA_SSH)" >&2; exit 1; }
            # 记住 PID 以便退出时关闭
            TUN_PID=$(pgrep -fnx "ssh -i .* -fN -L ${LOCAL_PORT}:127.0.0.1:${REAL_DB_PORT} $VIA_SSH" 2>/dev/null || pgrep -f "${LOCAL_PORT}:127.0.0.1:${REAL_DB_PORT}" 2>/dev/null | head -1)
            trap '[ -n "${TUN_PID:-}" ] && kill "$TUN_PID" 2>/dev/null || true' EXIT
            sleep 1
            PROBE_HOST_OVERRIDE="127.0.0.1"
            PROBE_PORT_OVERRIDE="$LOCAL_PORT"
            echo "[probe] SSH 隧道已开：local:$LOCAL_PORT -> $VIA_SSH:127.0.0.1:$REAL_DB_PORT (pid=$TUN_PID)" >&2
        fi
        probe_state "$ENV" "$APP"
        exit 0
        ;;
    *) echo "未知 --mode: $MODE" >&2; exit 1 ;;
esac
