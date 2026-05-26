#!/usr/bin/env bash
# migrators/prisma-postgresql.sh
# 输入：DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD PROJECT_PATH SCHEMA_PATH
#       COMMAND_DEPLOY(opt) COMMAND_SEED(opt) ENV_NAME
# 输出：stdout 最后一行 JSON
# 退出码：0=ok 1=schema not found 2=migrate fail 3=seed fail 4=db conn fail 5=tool missing

set -uo pipefail

log()  { echo "[prisma-pg] $*" >&2; }
emit() { echo "$1"; }   # JSON 到 stdout（最后一行）

: "${DB_HOST:?}"; : "${DB_PORT:?}"; : "${DB_NAME:?}"; : "${DB_USER:?}"; : "${DB_PASSWORD:?}"
: "${PROJECT_PATH:?}"; : "${SCHEMA_PATH:?}"; : "${ENV_NAME:?}"
COMMAND_DEPLOY="${COMMAND_DEPLOY:-}"
COMMAND_SEED="${COMMAND_SEED:-}"

# 1. 定位 schema 文件
abs_schema=""
if [ -f "$PROJECT_PATH/$SCHEMA_PATH" ]; then
    abs_schema="$PROJECT_PATH/$SCHEMA_PATH"
elif [ -f "$PROJECT_PATH/$SCHEMA_PATH/schema.prisma" ]; then
    abs_schema="$PROJECT_PATH/$SCHEMA_PATH/schema.prisma"
elif [ -f "$SCHEMA_PATH" ]; then
    abs_schema="$SCHEMA_PATH"
fi

if [ -z "$abs_schema" ] || [ ! -f "$abs_schema" ]; then
    log "❌ schema 文件未找到: PROJECT=$PROJECT_PATH SCHEMA=$SCHEMA_PATH"
    emit '{"status":"fail","tool":"prisma-postgresql","stage":"locate","error":"schema not found"}'
    exit 1
fi
log "schema = $abs_schema"

# 2. 校验 datasource
prov=$(awk '/^[[:space:]]*datasource[[:space:]]/{flag=1;next} flag && /\}/{flag=0} flag && /provider[[:space:]]*=/{match($0,/"[^"]+"/); if(RSTART){print substr($0,RSTART+1,RLENGTH-2); exit}}' "$abs_schema")
if [ "$prov" != "postgresql" ]; then
    log "❌ datasource provider=$prov，期望 postgresql"
    emit '{"status":"fail","tool":"prisma-postgresql","stage":"validate","error":"provider mismatch"}'
    exit 1
fi

# 3. 检查 prisma 可用
if ! command -v npx >/dev/null 2>&1; then
    log "❌ npx 未安装"
    emit '{"status":"fail","tool":"prisma-postgresql","stage":"prereq","error":"npx missing"}'
    exit 5
fi

# 4. 拼 DATABASE_URL（URL 编码密码）
url_encode() {
    local s="$1" out=""
    local i ch
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
DATABASE_URL="postgresql://${DB_USER}:${ENC_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
log "DATABASE_URL=postgresql://${DB_USER}:***@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# 5. 选 working dir：abs_schema 上两级（prisma/schema.prisma → 项目 root；或 packages/db/prisma → packages/db）
schema_dir="$(dirname "$abs_schema")"      # .../prisma
work_dir="$(dirname "$schema_dir")"        # .../packages/db 或 项目 root

# 6. 执行 migrate deploy
applied_before=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -tAc "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL" 2>/dev/null || echo 0)

if [ -n "$COMMAND_DEPLOY" ]; then
    log "[deploy] 用自定义命令: $COMMAND_DEPLOY"
    if ! (cd "$PROJECT_PATH" && DATABASE_URL="$DATABASE_URL" bash -c "$COMMAND_DEPLOY" 1>&2); then
        log "❌ 自定义 deploy 命令失败"
        emit '{"status":"fail","tool":"prisma-postgresql","stage":"deploy","error":"custom deploy failed"}'
        exit 2
    fi
else
    log "[deploy] npx prisma migrate deploy --schema $abs_schema (cwd=$work_dir)"
    if ! (cd "$work_dir" && DATABASE_URL="$DATABASE_URL" \
            npx --yes prisma migrate deploy --schema "$abs_schema" 1>&2); then
        log "❌ prisma migrate deploy 失败"
        emit '{"status":"fail","tool":"prisma-postgresql","stage":"deploy","error":"prisma migrate deploy failed"}'
        exit 2
    fi
fi

applied_after=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -tAc "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL" 2>/dev/null || echo 0)
tables_after=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -tAc "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null || echo 0)
applied=$((applied_after - applied_before))
log "✅ migrate 完成: applied=$applied tables_after=$tables_after"

# 7. seed（可选）
seed_done=false
if [ -n "$COMMAND_SEED" ]; then
    log "[seed] 用自定义命令: $COMMAND_SEED"
    if (cd "$PROJECT_PATH" && DATABASE_URL="$DATABASE_URL" bash -c "$COMMAND_SEED" 1>&2); then
        seed_done=true
    else
        log "⚠️ 自定义 seed 失败"
        emit "{\"status\":\"fail\",\"tool\":\"prisma-postgresql\",\"stage\":\"seed\",\"applied\":$applied,\"tables_after\":$tables_after,\"error\":\"custom seed failed\"}"
        exit 3
    fi
else
    seed_file=""
    [ -f "$work_dir/prisma/seed.ts" ] && seed_file="$work_dir/prisma/seed.ts"
    [ -z "$seed_file" ] && [ -f "$schema_dir/seed.ts" ] && seed_file="$schema_dir/seed.ts"
    if [ -n "$seed_file" ]; then
        log "[seed] 检测到 $seed_file，执行 npx tsx"
        if (cd "$work_dir" && DATABASE_URL="$DATABASE_URL" npx --yes tsx "$seed_file" 1>&2); then
            seed_done=true
        else
            log "⚠️ seed 失败（忽略，migrate 已成功）"
        fi
    fi
fi

emit "{\"status\":\"ok\",\"tool\":\"prisma-postgresql\",\"applied\":$applied,\"tables_after\":$tables_after,\"seed\":$seed_done}"
exit 0
