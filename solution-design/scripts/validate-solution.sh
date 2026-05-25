#!/bin/bash
# validate-solution.sh - 方案设计完整性 / 质量分级检查
#
# 用法：
#   bash validate-solution.sh <project> [--strict] [--report <path>] [--quiet]
#
# 检查矩阵：
#   [P0 必须]    目录结构 / 模板关键文件 / meta/version.json 合法
#   [P0 必须]    每个非示例模块必须有 design.md / reqs.json / apis.json
#   [P0 必须]    所有 reqs.json / apis.json 是合法 JSON
#   [P1 建议]    架构 overview.md 删除示例占位 (_TBD_ 数量 < 阈值)
#   [P1 建议]    至少有 1 条 ADR
#   [P1 建议]    solution-map.json 存在且 stats > 0
#   [P2 提示]    每个模块设计文档 > 30 行（内容不应为空骨架）
#
# 退出码：
#   0 = 全部通过
#   1 = 仅 P1/P2 失败
#   2 = P0 失败（致命）
#
# --strict：P1 失败也按致命处理（exit 2）

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

STRICT=false
QUIET=false
REPORT=""
PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=true; shift ;;
    --quiet)  QUIET=true;  shift ;;
    --report) REPORT="$2"; shift 2 ;;
    --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "❌ 未知参数: $1" >&2; exit 1 ;;
    *)  PROJECT="$1"; shift ;;
  esac
done

[ -n "$PROJECT" ] || { echo "❌ 用法: bash validate-solution.sh <project> [--strict] [--report <path>]" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ 需要 jq" >&2; exit 1; }

PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"
SOLUTION_DIR="$PROJECT_DIR/solution"

[ -d "$SOLUTION_DIR" ] || { echo "❌ 方案目录不存在: $SOLUTION_DIR" >&2; exit 2; }

# 计数
P0_FAIL=0
P1_FAIL=0
P2_FAIL=0
PASS=0
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

emit() {
  # emit <LVL> <STATUS> <MSG>
  local lvl="$1" st="$2" msg="$3"
  local icon
  case "$st" in
    PASS) icon="✅"; PASS=$((PASS+1)) ;;
    FAIL)
      icon="❌"
      case "$lvl" in
        P0) P0_FAIL=$((P0_FAIL+1)) ;;
        P1) P1_FAIL=$((P1_FAIL+1)) ;;
        P2) P2_FAIL=$((P2_FAIL+1)) ;;
      esac
      ;;
    WARN) icon="⚠️ " ;;
  esac
  printf '%s [%s] %s\n' "$icon" "$lvl" "$msg" >> "$TMP"
}

# ─── P0: 目录结构 ───────────────────────────────────
for d in architecture database api modules adr meta; do
  if [ -d "$SOLUTION_DIR/$d" ]; then
    emit P0 PASS "目录存在: $d/"
  else
    emit P0 FAIL "目录缺失: $d/"
  fi
done

# ─── P0: 关键模板文件 ───────────────────────────────
REQUIRED=(
  architecture/overview.md
  architecture/deployment.md
  architecture/data-flow.md
  database/er-diagram.md
  database/schema.md
  api/api-design.md
  adr/README.md
  meta/version.json
)
for f in "${REQUIRED[@]}"; do
  if [ -f "$SOLUTION_DIR/$f" ]; then
    emit P0 PASS "文件存在: $f"
  else
    emit P0 FAIL "文件缺失: $f"
  fi
done

# ─── P0: meta/version.json 合法 ────────────────────
META="$SOLUTION_DIR/meta/version.json"
if [ -f "$META" ]; then
  if jq empty "$META" 2>/dev/null; then
    PROJ=$(jq -r '.project // ""' "$META")
    if [ -n "$PROJ" ] && [ "$PROJ" != "{{PROJECT}}" ]; then
      emit P0 PASS "meta/version.json 合法 (project=$PROJ)"
    else
      emit P0 FAIL "meta/version.json: project 字段为空或未替换占位符"
    fi
  else
    emit P0 FAIL "meta/version.json: JSON 格式非法"
  fi
fi

# ─── P0: 每个非示例模块的三件套 ────────────────────
MODULES_DIR="$SOLUTION_DIR/modules"
MODULE_COUNT=0
if [ -d "$MODULES_DIR" ]; then
  for M in "$MODULES_DIR"/*/; do
    [ -d "$M" ] || continue
    NAME="$(basename "$M")"
    [ "$NAME" = "_example" ] && continue
    MODULE_COUNT=$((MODULE_COUNT+1))
    for f in design.md reqs.json apis.json; do
      if [ -f "$M/$f" ]; then
        # JSON 合法性校验
        if [[ "$f" == *.json ]]; then
          if jq empty "$M/$f" 2>/dev/null; then
            emit P0 PASS "模块 $NAME: $f 存在且合法"
          else
            emit P0 FAIL "模块 $NAME: $f JSON 格式非法"
          fi
        else
          emit P0 PASS "模块 $NAME: $f 存在"
        fi
      else
        emit P0 FAIL "模块 $NAME: 缺失 $f"
      fi
    done
  done
fi

# ─── P1: overview.md 占位符清理 ─────────────────────
OV="$SOLUTION_DIR/architecture/overview.md"
if [ -f "$OV" ]; then
  TBD_COUNT=$(grep -c '_TBD_' "$OV" 2>/dev/null | head -1 || true)
  TBD_COUNT=${TBD_COUNT:-0}
  if [ "$TBD_COUNT" -le 3 ]; then
    emit P1 PASS "architecture/overview.md: _TBD_ 占位符已清理（残留 $TBD_COUNT 处）"
  else
    emit P1 FAIL "architecture/overview.md: 残留 $TBD_COUNT 处 _TBD_ 占位符，请填充实际内容"
  fi
fi

# ─── P1: 至少 1 条 ADR ──────────────────────────────
ADR_COUNT=$(find "$SOLUTION_DIR/adr" -maxdepth 1 -name 'ADR-*.md' 2>/dev/null | wc -l)
if [ "$ADR_COUNT" -ge 1 ]; then
  emit P1 PASS "ADR 数量: $ADR_COUNT 条"
else
  emit P1 FAIL "未发现任何 ADR-NNN-*.md（请记录技术决策）"
fi

# ─── P1: solution-map.json ─────────────────────────
MAP="$SOLUTION_DIR/solution-map.json"
if [ -f "$MAP" ]; then
  if jq empty "$MAP" 2>/dev/null; then
    M=$(jq -r '.stats.modules // 0' "$MAP")
    R=$(jq -r '.stats.reqs // 0'    "$MAP")
    A=$(jq -r '.stats.apis // 0'    "$MAP")
    if [ "$M" -gt 0 ]; then
      emit P1 PASS "solution-map.json: 模块=$M 需求=$R API=$A"
    else
      emit P1 FAIL "solution-map.json: stats.modules=0（请检查模块是否未关联）"
    fi
  else
    emit P1 FAIL "solution-map.json: JSON 格式非法"
  fi
else
  emit P1 FAIL "solution-map.json 不存在（请运行 sync-solution-map.sh）"
fi

# ─── P2: 模块设计文档行数 ──────────────────────────
if [ -d "$MODULES_DIR" ]; then
  for M in "$MODULES_DIR"/*/; do
    NAME="$(basename "$M")"
    [ "$NAME" = "_example" ] && continue
    [ -f "$M/design.md" ] || continue
    L=$(wc -l < "$M/design.md")
    if [ "$L" -lt 20 ]; then
      emit P2 FAIL "模块 $NAME: design.md 仅 $L 行，疑似空骨架"
    fi
  done
fi

# ─── 输出 ──────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# Solution Validation Report — $PROJECT"
  echo ""
  echo "- 生成时间: $TS"
  echo "- 检查模块数: $MODULE_COUNT"
  echo ""
  echo "## 汇总"
  echo ""
  echo "| 级别 | 失败 |"
  echo "| --- | --- |"
  echo "| P0 (必须) | $P0_FAIL |"
  echo "| P1 (建议) | $P1_FAIL |"
  echo "| P2 (提示) | $P2_FAIL |"
  echo "| PASS      | $PASS |"
  echo ""
  echo "## 明细"
  echo ""
  echo '```'
  cat "$TMP"
  echo '```'
} > "$TMP.md"

if [ -n "$REPORT" ]; then
  mkdir -p "$(dirname "$REPORT")"
  cp "$TMP.md" "$REPORT"
  $QUIET || echo "📄 报告已写入: $REPORT"
fi

if ! $QUIET; then
  cat "$TMP.md"
fi

rm -f "$TMP.md"

# 退出码
if [ "$P0_FAIL" -gt 0 ]; then exit 2; fi
if $STRICT && [ "$P1_FAIL" -gt 0 ]; then exit 2; fi
if [ "$P1_FAIL" -gt 0 ] || [ "$P2_FAIL" -gt 0 ]; then exit 1; fi
exit 0
