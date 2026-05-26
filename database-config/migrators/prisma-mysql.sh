#!/usr/bin/env bash
# migrators/prisma-mysql.sh
# 同 prisma-postgresql 但用 MySQL
set -uo pipefail

log()  { echo "[prisma-mysql] $*" >&2; }
emit() { echo "$1"; }

: "${DB_HOST:?}"; : "${DB_PORT:?}"; : "${DB_NAME:?}"; : "${DB_USER:?}"; : "${DB_PASSWORD:?}"
: "${PROJECT_PATH:?}"; : "${SCHEMA_PATH:?}"; : "${ENV_NAME:?}"
COMMAND_DEPLOY="${COMMAND_DEPLOY:-}"
COMMAND_SEED="${COMMAND_SEED:-}"

# 1. 定位 schema
abs_schema=""
if [ -f "$PROJECT_PATH/$SCHEMA_PATH" ]; then
    abs_schema="$PROJECT_PATH/$SCHEMA_PATH"
elif [ -f "$PROJECT_PATH/$SCHEMA_PATH/schema.prisma" ]; then
    abs_schema="$PROJECT_PATH/$SCHEMA_PATH/schema.prisma"
elif [ -f "$SCHEMA_PATH" ]; then
    abs_schema="$SCHEMA_PATH"
fi
if [ -z "$abs_schema" ] || [ ! -f "$abs_schema" ]; then
    log "❌ schema 未找到"
    emit '{"status":"fail","tool":"prisma-mysql","stage":"locate","error":"schema not found"}'
    exit 1
fi
log "schema = $abs_schema"

# 2. provider 校验
prov=$(awk '/^[[:space:]]*datasource[[:space:]]/{flag=1;next} flag && /\}/{flag=0} flag && /provider[[:space:]]*=/{match($0,/"[^"]+"/); if(RSTART){print substr($0,RSTART+1,RLENGTH-2); exit}}' "$abs_schema")
if [ "$prov" != "mysql" ]; then
    log "❌ provider=$prov 期望 mysql"
    emit '{"status":"fail","tool":"prisma-mysql","stage":"validate","error":"provider mismatch"}'
    exit 1
fi

# 3. npx
command -v npx >/dev/null 2>&1 || {
    log "❌ npx 缺失"
    emit '{"status":"fail","tool":"prisma-mysql","stage":"prereq","error":"npx missing"}'
    exit 5
}

# 4. URL
url_encode() {
    local s="$1" out="" i ch
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-]) out+="$ch" ;;
            *) out+=$(printf '%%%02X' "'$ch") ;;
        esac
    done
    printf %s "$out"
}
ENC_PASS=$(url_encode "$DB_PASSWORD")
DATABASE_URL="mysql://${DB_USER}:${ENC_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log "DATABASE_URL=mysql://${DB_USER}:***@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log "ℹ️ 推荐字符集 utf8mb4_unicode_ci（init-db.sh 默认）"

schema_dir="$(dirname "$abs_schema")"
work_dir="$(dirname "$schema_dir")"

count_applied() {
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -B \
        -e "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL" 2>/dev/null || echo 0
}
count_tables() {
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -B \
        -e "SELECT count(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'" 2>/dev/null || echo 0
}

applied_before=$(count_applied)

if [ -n "$COMMAND_DEPLOY" ]; then
    log "[deploy] 自定义命令: $COMMAND_DEPLOY"
    (cd "$PROJECT_PATH" && DATABASE_URL="$DATABASE_URL" bash -c "$COMMAND_DEPLOY" 1>&2) || {
        log "❌ 自定义 deploy 失败"
        emit '{"status":"fail","tool":"prisma-mysql","stage":"deploy","error":"custom deploy failed"}'
        exit 2
    }
else
    log "[deploy] npx prisma migrate deploy --schema $abs_schema (cwd=$work_dir)"
    (cd "$work_dir" && DATABASE_URL="$DATABASE_URL" \
        npx --yes prisma migrate deploy --schema "$abs_schema" 1>&2) || {
        log "❌ prisma migrate deploy 失败"
        emit '{"status":"fail","tool":"prisma-mysql","stage":"deploy","error":"prisma migrate deploy failed"}'
        exit 2
    }
fi

applied_after=$(count_applied)
tables_after=$(count_tables)
applied=$((applied_after - applied_before))
log "✅ migrate 完成: applied=$applied tables_after=$tables_after"

seed_done=false
if [ -n "$COMMAND_SEED" ]; then
    log "[seed] 自定义: $COMMAND_SEED"
    if (cd "$PROJECT_PATH" && DATABASE_URL="$DATABASE_URL" bash -c "$COMMAND_SEED" 1>&2); then
        seed_done=true
    else
        emit "{\"status\":\"fail\",\"tool\":\"prisma-mysql\",\"stage\":\"seed\",\"applied\":$applied,\"tables_after\":$tables_after,\"error\":\"custom seed failed\"}"
        exit 3
    fi
else
    seed_file=""
    [ -f "$work_dir/prisma/seed.ts" ] && seed_file="$work_dir/prisma/seed.ts"
    [ -z "$seed_file" ] && [ -f "$schema_dir/seed.ts" ] && seed_file="$schema_dir/seed.ts"
    if [ -n "$seed_file" ]; then
        log "[seed] $seed_file"
        if (cd "$work_dir" && DATABASE_URL="$DATABASE_URL" npx --yes tsx "$seed_file" 1>&2); then
            seed_done=true
        else
            log "⚠️ seed 失败（忽略）"
        fi
    fi
fi

emit "{\"status\":\"ok\",\"tool\":\"prisma-mysql\",\"applied\":$applied,\"tables_after\":$tables_after,\"seed\":$seed_done}"
exit 0
