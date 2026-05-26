#!/usr/bin/env bash
# migrators/raw-sql.sh
# 输入：DB_TYPE (postgresql|mysql), DB_HOST/PORT/NAME/USER/PASSWORD
#       PROJECT_PATH, SCHEMA_PATH（目录，含 .sql 文件，按字典序执行）
#       ENV_NAME
# 行为：维护 _migrations 表，跳过已执行；按文件名排序执行
#       seed.sql 在所有 migrate 后执行
set -uo pipefail

log()  { echo "[raw-sql] $*" >&2; }
emit() { echo "$1"; }

: "${DB_TYPE:?DB_TYPE required (postgresql|mysql)}"; : "${DB_HOST:?}"; : "${DB_PORT:?}"
: "${DB_NAME:?}"; : "${DB_USER:?}"; : "${DB_PASSWORD:?}"
: "${PROJECT_PATH:?}"; : "${SCHEMA_PATH:?}"; : "${ENV_NAME:?}"

# 1. 定位 SQL 目录
sql_dir=""
if [ -d "$PROJECT_PATH/$SCHEMA_PATH" ]; then
    sql_dir="$PROJECT_PATH/$SCHEMA_PATH"
elif [ -d "$SCHEMA_PATH" ]; then
    sql_dir="$SCHEMA_PATH"
fi
if [ -z "$sql_dir" ] || [ ! -d "$sql_dir" ]; then
    log "❌ SQL 目录未找到"
    emit '{"status":"fail","tool":"raw-sql","stage":"locate","error":"sql dir not found"}'
    exit 1
fi
log "sql_dir = $sql_dir"

# 2. 收集 sql 文件
mapfile -t sql_files < <(find "$sql_dir" -maxdepth 1 -type f -name '*.sql' ! -name 'seed.sql' | sort)
if [ "${#sql_files[@]}" -eq 0 ]; then
    log "⚠️ 目录中无 .sql 文件"
    emit '{"status":"ok","tool":"raw-sql","applied":0,"tables_after":0,"seed":false,"note":"no sql files"}'
    exit 0
fi
log "发现 ${#sql_files[@]} 个 SQL 文件"

# 3. 抽象 SQL 执行函数
case "$DB_TYPE" in
    postgresql)
        run_sql_inline() {
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                -v ON_ERROR_STOP=1 -tAc "$1"
        }
        run_sql_file() {
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
                -v ON_ERROR_STOP=1 -1 -f "$1"
        }
        ensure_table_sql="CREATE TABLE IF NOT EXISTS _migrations (
            id SERIAL PRIMARY KEY,
            filename VARCHAR(255) UNIQUE NOT NULL,
            applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );"
        count_tables_sql="SELECT count(*) FROM pg_tables WHERE schemaname='public'"
        ;;
    mysql)
        run_sql_inline() {
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" -N -B -e "$1"
        }
        run_sql_file() {
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -D "$DB_NAME" < "$1"
        }
        ensure_table_sql="CREATE TABLE IF NOT EXISTS _migrations (
            id INT AUTO_INCREMENT PRIMARY KEY,
            filename VARCHAR(255) UNIQUE NOT NULL,
            applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
        count_tables_sql="SELECT count(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'"
        ;;
    *)
        log "❌ 不支持的 DB_TYPE: $DB_TYPE"
        emit '{"status":"fail","tool":"raw-sql","stage":"validate","error":"unsupported db_type"}'
        exit 1
        ;;
esac

# 4. 客户端可用性
if [ "$DB_TYPE" = "postgresql" ] && ! command -v psql >/dev/null 2>&1; then
    log "❌ psql 未安装"
    emit '{"status":"fail","tool":"raw-sql","stage":"prereq","error":"psql missing"}'
    exit 5
fi
if [ "$DB_TYPE" = "mysql" ] && ! command -v mysql >/dev/null 2>&1; then
    log "❌ mysql 客户端未安装"
    emit '{"status":"fail","tool":"raw-sql","stage":"prereq","error":"mysql missing"}'
    exit 5
fi

# 5. 建 _migrations 表
if ! run_sql_inline "$ensure_table_sql" >/dev/null 2>&1; then
    log "❌ 无法建 _migrations 表（连接失败？）"
    emit '{"status":"fail","tool":"raw-sql","stage":"bootstrap","error":"cannot create _migrations"}'
    exit 4
fi

# 6. 逐文件执行
applied=0
for f in "${sql_files[@]}"; do
    base=$(basename "$f")
    # 已执行?
    existed=$(run_sql_inline "SELECT 1 FROM _migrations WHERE filename='$base'" 2>/dev/null || echo "")
    if [ -n "$existed" ]; then
        log "⏭️  跳过已执行: $base"
        continue
    fi
    log "▶️  执行: $base"
    if ! run_sql_file "$f"; then
        log "❌ 失败: $base"
        emit "{\"status\":\"fail\",\"tool\":\"raw-sql\",\"stage\":\"deploy\",\"file\":\"$base\",\"applied\":$applied,\"error\":\"sql execution failed\"}"
        exit 2
    fi
    # 登记
    run_sql_inline "INSERT INTO _migrations (filename) VALUES ('$base')" >/dev/null 2>&1
    applied=$((applied+1))
done

tables_after=$(run_sql_inline "$count_tables_sql" 2>/dev/null | head -1 | tr -d '[:space:]')
[ -z "$tables_after" ] && tables_after=0
log "✅ migrate 完成: applied=$applied tables_after=$tables_after"

# 7. seed.sql
seed_done=false
if [ -f "$sql_dir/seed.sql" ]; then
    log "[seed] 执行 $sql_dir/seed.sql"
    if run_sql_file "$sql_dir/seed.sql"; then
        seed_done=true
    else
        log "⚠️ seed.sql 失败（忽略）"
    fi
fi

emit "{\"status\":\"ok\",\"tool\":\"raw-sql\",\"db_type\":\"$DB_TYPE\",\"applied\":$applied,\"tables_after\":$tables_after,\"seed\":$seed_done}"
exit 0
