#!/bin/bash
# sync-solution-map.sh - 同步方案设计与需求/API/代码的映射关系
#
# 用法：
#   bash sync-solution-map.sh <project> [--dry-run] [--quiet]
#   例：bash sync-solution-map.sh smart-college
#   例：bash sync-solution-map.sh smart-college --dry-run
#
# 输出：docs-repos/<project>/solution/solution-map.json
# 结构：
#   {
#     "project": "...",
#     "generated_at": "ISO-8601",
#     "version": "v2.1",
#     "stats": { "modules": N, "reqs": N, "apis": N, "code_files": N },
#     "modules": [ {name, module_name, type, priority, reqs:[...], apis:[...]} ],
#     "req_module_map": { "REQ-XXX": ["module-a", ...] },
#     "req_api_map":    { "REQ-XXX": [ {module, method, path, api_id} ... ] },
#     "api_code_map":   { "module:METHOD path": ["src/..."] }
#   }

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DRY_RUN=false
QUIET=false
PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --quiet)   QUIET=true ;;
    --help|-h)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    -*) echo "❌ 未知参数: $arg" >&2; exit 1 ;;
    *)  PROJECT="$arg" ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "❌ 用法: bash sync-solution-map.sh <project> [--dry-run] [--quiet]" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq，请先安装" >&2; exit 1; }

log() { $QUIET || echo "$@"; }

PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"
SOLUTION_DIR="$PROJECT_DIR/solution"
REQUIREMENTS_DIR="$PROJECT_DIR/requirements"
CODE_DIR="$WORKSPACE_DIR/projects/$PROJECT/src"

[ -d "$PROJECT_DIR" ]  || { echo "❌ 项目目录不存在: $PROJECT_DIR" >&2; exit 1; }
[ -d "$SOLUTION_DIR" ] || { echo "❌ 方案目录不存在: $SOLUTION_DIR (请先 init-solution.sh)" >&2; exit 1; }

HAS_REQS=true
[ -d "$REQUIREMENTS_DIR" ] || { HAS_REQS=false; log "⚠️  无 requirements/ 目录，仅生成模块映射"; }

HAS_CODE=false
[ -d "$CODE_DIR" ] && HAS_CODE=true

TMP=$(mktemp /tmp/solution-map.XXXXXX.json)
trap 'rm -f "$TMP" "$TMP.tmp"' EXIT

GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ─── 初始化 map 骨架 ────────────────────────────────
jq -n --arg p "$PROJECT" --arg t "$GENERATED_AT" '{
  project: $p,
  generated_at: $t,
  version: "v2.1",
  stats: { modules: 0, reqs: 0, apis: 0, code_files: 0 },
  modules: [],
  req_module_map: {},
  req_api_map: {},
  api_code_map: {}
}' > "$TMP"

# ─── 工具函数：从 reqs.json 安全提取 REQ-ID 列表 ────
extract_req_ids() {
  local file="$1"
  [ -f "$file" ] || { echo ""; return; }
  # 兼容三种格式：{reqs:[{id}]} / [{id}] / [string]
  jq -r '
    (if type=="object" and has("reqs") then .reqs else . end)
    | if type=="array" then .[] else . end
    | if type=="object" then (.id // empty) else . end
  ' "$file" 2>/dev/null | grep -E '^REQ-[0-9]{8}-[0-9]{3}$' || true
}

# ─── 工具函数：从 apis.json 提取 API 列表（标准化） ─
extract_apis_normalized() {
  local file="$1" module="$2"
  [ -f "$file" ] || { echo "[]"; return; }
  jq --arg mod "$module" '
    (if type=="object" and has("apis") then .apis else . end)
    | if type=="array" then . else [] end
    | map({
        id: (.id // ""),
        method: (.method // "GET"),
        path: (.path // ""),
        summary: (.summary // ""),
        auth: (.auth // ""),
        req_ids: (.req_ids // []),
        module: $mod
      })
  ' "$file" 2>/dev/null || echo "[]"
}

# ─── 1) 收集每个模块 ─────────────────────────────────
MODULES_DIR="$SOLUTION_DIR/modules"
MODULE_COUNT=0
[ -d "$MODULES_DIR" ] || { echo "⚠️  无 modules/ 目录" >&2; }

for MODULE in "$MODULES_DIR"/*/; do
  [ -d "$MODULE" ] || continue
  NAME="$(basename "$MODULE")"
  [ "$NAME" = "_example" ] && continue
  MODULE_COUNT=$((MODULE_COUNT + 1))

  # 模块元数据（从 reqs.json 里读，兼容旧版本）
  META_NAME=""
  META_TYPE=""
  META_PRIO=""
  if [ -f "$MODULE/reqs.json" ]; then
    META_NAME=$(jq -r '.module_name // ""' "$MODULE/reqs.json" 2>/dev/null || echo "")
    META_TYPE=$(jq -r '.type // ""'        "$MODULE/reqs.json" 2>/dev/null || echo "")
    META_PRIO=$(jq -r '.priority // ""'    "$MODULE/reqs.json" 2>/dev/null || echo "")
  fi

  # 从 design.md 第一个 # 标题提取兜底名称
  if [ -z "$META_NAME" ] && [ -f "$MODULE/design.md" ]; then
    META_NAME=$(grep -m1 -E '^#\s+' "$MODULE/design.md" 2>/dev/null | sed -E 's/^#+\s*//' || echo "")
  fi

  REQ_IDS_FILE=$(mktemp)
  extract_req_ids "$MODULE/reqs.json" > "$REQ_IDS_FILE"
  REQS_JSON=$(jq -R . "$REQ_IDS_FILE" 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
  rm -f "$REQ_IDS_FILE"

  APIS_JSON=$(extract_apis_normalized "$MODULE/apis.json" "$NAME")

  jq --arg n "$NAME" \
     --arg mn "$META_NAME" --arg ty "$META_TYPE" --arg pr "$META_PRIO" \
     --argjson reqs "$REQS_JSON" --argjson apis "$APIS_JSON" '
    .modules += [{
      name: $n, module_name: $mn, type: $ty, priority: $pr,
      reqs: $reqs, apis: $apis,
      reqs_count: ($reqs|length), apis_count: ($apis|length)
    }]
  ' "$TMP" > "$TMP.tmp" && mv "$TMP.tmp" "$TMP"
done

# ─── 2) 构建反向映射 req → modules / req → apis ─────
jq '
  .req_module_map = (
    [ .modules[] as $m | $m.reqs[] | {req: ., mod: $m.name} ]
    | group_by(.req)
    | map({ key: .[0].req, value: (map(.mod) | unique) })
    | from_entries
  )
  | .req_api_map = (
    [ .modules[] as $m | $m.apis[] as $a | $a.req_ids[]? | {
        req: .,
        api: { module: $m.name, method: $a.method, path: $a.path, api_id: $a.id, summary: $a.summary }
      } ]
    | group_by(.req)
    | map({ key: .[0].req, value: (map(.api)) })
    | from_entries
  )
' "$TMP" > "$TMP.tmp" && mv "$TMP.tmp" "$TMP"

# ─── 3) API ↔ 代码映射（如有代码目录） ──────────────
CODE_FILE_COUNT=0
if $HAS_CODE; then
  log "🔎 扫描代码目录: $CODE_DIR"
  # 提取所有 (module, method, path) 三元组
  while IFS=$'\t' read -r MOD METHOD APIPATH; do
    [ -n "$APIPATH" ] || continue
    KEY="$MOD:$METHOD $APIPATH"
    # 用 path 主体（去 :param）做粗匹配
    SEARCH=$(echo "$APIPATH" | sed -E 's#:[a-zA-Z_][a-zA-Z0-9_]*#[^/]+#g; s#/$##')
    # 严格匹配字符串作为兜底
    HITS=$(grep -rlE "\"${APIPATH}\"|'${APIPATH}'|\`${APIPATH}\`" "$CODE_DIR" \
            --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
            2>/dev/null | sed "s|$CODE_DIR/||" | sort -u || true)
    if [ -n "$HITS" ]; then
      HITS_JSON=$(printf '%s\n' "$HITS" | jq -R . | jq -s .)
      jq --arg k "$KEY" --argjson v "$HITS_JSON" '
        .api_code_map[$k] = $v
      ' "$TMP" > "$TMP.tmp" && mv "$TMP.tmp" "$TMP"
      CODE_FILE_COUNT=$((CODE_FILE_COUNT + $(echo "$HITS" | wc -l)))
    fi
  done < <(jq -r '.modules[] | .name as $m | .apis[] | [$m, .method, .path] | @tsv' "$TMP")
fi

# ─── 4) 汇总 stats ───────────────────────────────────
jq --argjson cfc "$CODE_FILE_COUNT" '
  .stats = {
    modules: (.modules | length),
    reqs:    (.req_module_map | length),
    apis:    ([.modules[].apis[]] | length),
    code_files: $cfc
  }
' "$TMP" > "$TMP.tmp" && mv "$TMP.tmp" "$TMP"

# ─── 5) 输出 ─────────────────────────────────────────
OUTPUT_FILE="$SOLUTION_DIR/solution-map.json"
if $DRY_RUN; then
  log "🔍 [DRY-RUN] 预览（前 60 行）:"
  jq . "$TMP" | head -60
  log "...（已截断）"
else
  jq . "$TMP" > "$OUTPUT_FILE"
  log "✅ solution-map.json 已生成: $OUTPUT_FILE"
  log "📊 模块=$(jq -r .stats.modules "$OUTPUT_FILE") 需求=$(jq -r .stats.reqs "$OUTPUT_FILE") API=$(jq -r .stats.apis "$OUTPUT_FILE") 代码文件=$(jq -r .stats.code_files "$OUTPUT_FILE")"
fi

exit 0
