#!/bin/bash
# diff-against-reqs.sh - 检测「需求 ↔ 方案」漂移
#
# 用法：
#   bash diff-against-reqs.sh <project> [--report <path>] [--quiet] [--fail-on-warn]
#   例：bash diff-against-reqs.sh smart-college
#   例：bash diff-against-reqs.sh smart-college --report /tmp/diff.md
#   例：bash diff-against-reqs.sh smart-college --fail-on-warn   # 任意警告即非零退出
#
# 检测维度：
#   1) requirements/ 里有但 solution 模块未关联    → MISSING_IN_SOLUTION
#   2) solution 模块引用了但 requirements/ 已删除   → ORPHAN_IN_SOLUTION
#   3) 模块 reqs 数=0                               → EMPTY_MODULE
#   4) 模块 apis 数=0                               → MODULE_NO_API
#   5) API 引用的 REQ-ID 在 requirements/ 不存在    → API_REQ_NOT_FOUND
#   6) requirements/ 里的需求在多个模块中重复       → REQ_IN_MULTIPLE_MODULES (info)
#
# 输出：
#   - 默认 stdout 打印汇总
#   - --report <path>：同时写入 markdown 报告
#   - 退出码：0 = 无问题；2 = 有 ERROR；1 = 仅有 WARN 且加了 --fail-on-warn

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

REPORT=""
QUIET=false
FAIL_ON_WARN=false
PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --report) REPORT="$2"; shift 2 ;;
    --quiet)  QUIET=true; shift ;;
    --fail-on-warn) FAIL_ON_WARN=true; shift ;;
    --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "❌ 未知参数: $1" >&2; exit 1 ;;
    *)  PROJECT="$1"; shift ;;
  esac
done

[ -n "$PROJECT" ] || { echo "❌ 用法: bash diff-against-reqs.sh <project> [--report <path>]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq" >&2; exit 1; }

log() { $QUIET || echo "$@"; }

PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"
SOLUTION_DIR="$PROJECT_DIR/solution"
REQUIREMENTS_DIR="$PROJECT_DIR/requirements"
MAP_FILE="$SOLUTION_DIR/solution-map.json"

[ -d "$SOLUTION_DIR" ]     || { echo "❌ 方案目录不存在: $SOLUTION_DIR" >&2; exit 1; }
[ -d "$REQUIREMENTS_DIR" ] || { echo "❌ 需求目录不存在: $REQUIREMENTS_DIR" >&2; exit 1; }

# 若 map 缺失或落后，自动重生（静默）
if [ ! -f "$MAP_FILE" ] || [ "$SOLUTION_DIR/modules" -nt "$MAP_FILE" ]; then
  log "🔄 solution-map.json 缺失或过期，自动重新生成..."
  bash "$SKILL_DIR/scripts/sync-solution-map.sh" "$PROJECT" --quiet
fi

# 收集 requirements/ 真实存在的 REQ-ID
REQ_LIST_FILE=$(mktemp)
trap 'rm -f "$REQ_LIST_FILE"' EXIT
find "$REQUIREMENTS_DIR" -maxdepth 3 -type f -name 'REQ-*.md' -not -path '*/_archive/*' \
  | xargs -I{} basename {} .md 2>/dev/null | sort -u > "$REQ_LIST_FILE"

REAL_REQ_COUNT=$(wc -l < "$REQ_LIST_FILE")
MAPPED_REQ_COUNT=$(jq -r '.req_module_map | length' "$MAP_FILE")

ERRORS=0
WARNS=0
INFOS=0
TMP_REPORT=$(mktemp)
trap 'rm -f "$REQ_LIST_FILE" "$TMP_REPORT"' EXIT

emit() {
  # emit <LEVEL> <CODE> <MSG>
  local lvl="$1" code="$2" msg="$3"
  case "$lvl" in
    ERROR) ERRORS=$((ERRORS+1)) ;;
    WARN)  WARNS=$((WARNS+1)) ;;
    INFO)  INFOS=$((INFOS+1)) ;;
  esac
  printf '%s\n' "- [$lvl] $code  $msg" >> "$TMP_REPORT"
}

# ─── 检查 1: MISSING_IN_SOLUTION ─────────────────────
MISSING=$(comm -23 "$REQ_LIST_FILE" <(jq -r '.req_module_map | keys[]' "$MAP_FILE" | sort -u))
if [ -n "$MISSING" ]; then
  while IFS= read -r id; do
    emit WARN MISSING_IN_SOLUTION "需求 \`$id\` 存在但未关联到任何模块"
  done <<< "$MISSING"
fi

# ─── 检查 2: ORPHAN_IN_SOLUTION ──────────────────────
ORPHAN=$(comm -13 "$REQ_LIST_FILE" <(jq -r '.req_module_map | keys[]' "$MAP_FILE" | sort -u))
if [ -n "$ORPHAN" ]; then
  while IFS= read -r id; do
    MODS=$(jq -r --arg id "$id" '.req_module_map[$id] | join(", ")' "$MAP_FILE")
    emit ERROR ORPHAN_IN_SOLUTION "方案模块 [$MODS] 引用了不存在的需求 \`$id\`"
  done <<< "$ORPHAN"
fi

# ─── 检查 3 / 4: EMPTY_MODULE / MODULE_NO_API ──────
while IFS=$'\t' read -r MNAME RCNT ACNT; do
  [ "$RCNT" = "0" ] && emit WARN EMPTY_MODULE "模块 \`$MNAME\` 未关联任何需求"
  [ "$ACNT" = "0" ] && emit WARN MODULE_NO_API "模块 \`$MNAME\` 未定义任何 API"
done < <(jq -r '.modules[] | [.name, .reqs_count, .apis_count] | @tsv' "$MAP_FILE")

# ─── 检查 5: API_REQ_NOT_FOUND ──────────────────────
while IFS= read -r req_id; do
  [ -z "$req_id" ] && continue
  if ! grep -qx "$req_id" "$REQ_LIST_FILE"; then
    LOC=$(jq -r --arg id "$req_id" '
      [.modules[] as $m | $m.apis[] | select(.req_ids|index($id)) |
       "\($m.name) \(.method) \(.path)"] | join("; ")
    ' "$MAP_FILE")
    emit ERROR API_REQ_NOT_FOUND "API 引用了不存在的需求 \`$req_id\`  (位置: $LOC)"
  fi
done < <(jq -r '[.modules[].apis[].req_ids[]?] | unique | .[]' "$MAP_FILE")

# ─── 检查 6: REQ_IN_MULTIPLE_MODULES (info) ─────────
while IFS=$'\t' read -r req_id mod_list; do
  CNT=$(echo "$mod_list" | tr ',' '\n' | wc -l)
  if [ "$CNT" -gt 1 ]; then
    emit INFO REQ_IN_MULTIPLE_MODULES "需求 \`$req_id\` 关联多个模块: $mod_list（确认是否应拆分）"
  fi
done < <(jq -r '.req_module_map | to_entries[] | [.key, (.value|join(","))] | @tsv' "$MAP_FILE")

# ─── 生成报告 ────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# Solution Drift Report — $PROJECT"
  echo ""
  echo "- 生成时间：$TS"
  echo "- 需求文件数：$REAL_REQ_COUNT"
  echo "- 已映射需求：$MAPPED_REQ_COUNT"
  echo "- 模块数：$(jq -r '.stats.modules' "$MAP_FILE")"
  echo "- API 数：$(jq -r '.stats.apis' "$MAP_FILE")"
  echo ""
  echo "## 摘要"
  echo ""
  echo "| 级别 | 数量 |"
  echo "| --- | --- |"
  echo "| ERROR | $ERRORS |"
  echo "| WARN  | $WARNS |"
  echo "| INFO  | $INFOS |"
  echo ""
  echo "## 明细"
  echo ""
  if [ -s "$TMP_REPORT" ]; then
    cat "$TMP_REPORT"
  else
    echo "_无任何问题，方案与需求完全一致 🎉_"
  fi
} > "${TMP_REPORT}.md"

# 输出
if [ -n "$REPORT" ]; then
  mkdir -p "$(dirname "$REPORT")"
  cp "${TMP_REPORT}.md" "$REPORT"
  log "📄 报告已写入: $REPORT"
fi

if ! $QUIET; then
  cat "${TMP_REPORT}.md"
fi

# 更新 meta/version.json 的 last_checked_reqs
META="$SOLUTION_DIR/meta/version.json"
if [ -f "$META" ]; then
  jq --arg t "$TS" '. + {last_checked_reqs: $t}' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
fi

rm -f "${TMP_REPORT}.md"

# 退出码策略
if [ "$ERRORS" -gt 0 ]; then exit 2; fi
if $FAIL_ON_WARN && [ "$WARNS" -gt 0 ]; then exit 1; fi
exit 0
