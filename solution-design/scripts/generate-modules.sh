#!/bin/bash
# generate-modules.sh - 从 REQ 自动生成模块草稿（保守起草，主 Agent 审）
#
# 用法：
#   bash generate-modules.sh <project> [--dry-run] [--from-roles] [--force]
#
# 策略（按优先级）：
#   1. 若 requirements/ 内 REQ-*.md 的标题里出现 "<角色>-<模块>" 形式（如 "学生-学业预警"）
#      → 用角色或 "—" 后的关键词作为模块候选
#   2. 否则使用关键词词典做粗匹配（中文领域词 + 英文）
#
# 行为：
#   - 仅创建尚不存在的模块目录
#   - 每个候选模块：拷贝 _example/* → modules/<slug>/
#     · design.md：替换 {{MODULE_NAME}} / {{MODULE_SLUG}}
#     · reqs.json：填入识别到的 REQ-ID 列表
#     · apis.json：保持空骨架 {module, base_path, apis:[]}
#   - --dry-run：仅打印候选列表，不写文件
#   - --force：覆盖已存在但属于"空骨架"的模块（design.md < 20 行）
#   - 完成后自动调用 sync-solution-map.sh

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_DIR="$(cd "$SKILL_DIR/../.." && pwd)"

DRY_RUN=false
FROM_ROLES=false
FORCE=false
PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=true;    shift ;;
    --from-roles) FROM_ROLES=true; shift ;;
    --force)      FORCE=true;      shift ;;
    --help|-h)    sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "❌ 未知参数: $1" >&2; exit 1 ;;
    *)  PROJECT="$1"; shift ;;
  esac
done

[ -n "$PROJECT" ] || { echo "❌ 用法: bash generate-modules.sh <project> [--dry-run] [--from-roles] [--force]" >&2; exit 1; }

PROJECT_DIR="$WORKSPACE_DIR/docs-repos/$PROJECT"
SOLUTION_DIR="$PROJECT_DIR/solution"
REQUIREMENTS_DIR="$PROJECT_DIR/requirements"
MODULES_DIR="$SOLUTION_DIR/modules"
EXAMPLE_DIR="$SOLUTION_DIR/modules/_example"

[ -d "$SOLUTION_DIR" ]     || { echo "❌ 方案目录不存在: $SOLUTION_DIR (先 init-solution.sh)" >&2; exit 1; }
[ -d "$REQUIREMENTS_DIR" ] || { echo "❌ 需求目录不存在: $REQUIREMENTS_DIR" >&2; exit 1; }
[ -d "$EXAMPLE_DIR" ]      || { echo "❌ modules/_example/ 缺失，无法拷贝模板" >&2; exit 1; }
mkdir -p "$MODULES_DIR"

# slug 化：中文 → 拼音不在能力内，所以中文模块名我们采用「拼音首字母拼接」过于不可靠
# 折中：中文模块名直接保留中文目录（OK on linux），同时去除空白、符号
slugify() {
  local s="$*"
  s="$(echo "$s" | tr -d '[:space:]' | sed 's#[/\\:*?"<>|]##g')"
  echo "$s"
}

# 关键词词典（领域常见）
declare -A KW_MAP
KW_MAP[user]="用户|账号|账户|user|account"
KW_MAP[auth]="登录|注册|权限|鉴权|登入|auth|login|signin"
KW_MAP[notification]="通知|消息|提醒|notification|message"
KW_MAP[dashboard]="工作台|首页|仪表|看板|portal|dashboard|cockpit"
KW_MAP[report]="报表|统计|分析|report|analytics"
KW_MAP[search]="搜索|查询|search|query"
KW_MAP[config]="配置|设置|config|setting"
KW_MAP[approval]="审批|流程|approval|workflow"
KW_MAP[archive]="档案|归档|archive"
KW_MAP[material]="素材|资源|素材中心|material"
KW_MAP[academic]="学业|课程|教学|academic|course"
KW_MAP[data_sync]="同步|数据治理|data sync|etl"

declare -A MOD_REQS   # slug -> "REQ-A REQ-B ..."
declare -A MOD_TITLES # slug -> "中文模块名"

scan_req_file() {
  local f="$1"
  local req_id; req_id="$(basename "$f" .md)"
  local title; title="$(grep -m1 -E '^#\s+' "$f" 2>/dev/null | sed -E 's/^#+\s*//' || true)"

  # 1) "角色-模块" 模式（如 "学生-学业预警" "教师-学生指导"）
  if $FROM_ROLES && [[ "$title" =~ ^[^-：:]+-[^：:]+ ]]; then
    local mod_part; mod_part="$(echo "$title" | sed -E 's/^[^-]+-//; s/[（(].*$//' | sed -E 's/[[:space:]]+//g')"
    if [ -n "$mod_part" ]; then
      local slug; slug="$(slugify "$mod_part")"
      MOD_TITLES[$slug]="$mod_part"
      MOD_REQS[$slug]="${MOD_REQS[$slug]:-} $req_id"
      return
    fi
  fi

  # 2) 关键词匹配
  local body; body="$(cat "$f")"
  local matched=0
  for slug in "${!KW_MAP[@]}"; do
    if echo "$title $body" | grep -qiE "${KW_MAP[$slug]}"; then
      MOD_TITLES[$slug]="${MOD_TITLES[$slug]:-$slug}"
      MOD_REQS[$slug]="${MOD_REQS[$slug]:-} $req_id"
      matched=1
    fi
  done
  if [ $matched -eq 0 ]; then
    MOD_TITLES[misc]="misc"
    MOD_REQS[misc]="${MOD_REQS[misc]:-} $req_id"
  fi
}

echo "🔎 扫描 $REQUIREMENTS_DIR ..."
REQ_COUNT=0
while IFS= read -r REQ_FILE; do
  REQ_COUNT=$((REQ_COUNT+1))
  scan_req_file "$REQ_FILE"
done < <(find "$REQUIREMENTS_DIR" -maxdepth 3 -name 'REQ-*.md' -not -path '*/_archive/*')

echo "📋 共扫描 $REQ_COUNT 条需求，识别出 ${#MOD_TITLES[@]} 个候选模块"
echo ""

# 打印候选
for slug in "${!MOD_TITLES[@]}"; do
  local_reqs="${MOD_REQS[$slug]}"
  count=$(echo "$local_reqs" | wc -w)
  exists_mark=""
  [ -d "$MODULES_DIR/$slug" ] && exists_mark=" [已存在]"
  printf "  • %-30s  reqs=%3d  %s%s\n" "$slug" "$count" "${MOD_TITLES[$slug]}" "$exists_mark"
done | sort

if $DRY_RUN; then
  echo ""
  echo "🔍 [DRY-RUN] 未创建任何文件。去掉 --dry-run 实际生成。"
  exit 0
fi

# 实际创建
CREATED=0; SKIPPED=0
for slug in "${!MOD_TITLES[@]}"; do
  TARGET="$MODULES_DIR/$slug"
  MNAME="${MOD_TITLES[$slug]}"
  REQS_LIST="${MOD_REQS[$slug]}"

  if [ -d "$TARGET" ]; then
    # --force：仅当 design.md < 20 行（视为空骨架）才覆盖
    if $FORCE; then
      LINES=0
      [ -f "$TARGET/design.md" ] && LINES=$(wc -l < "$TARGET/design.md")
      if [ "$LINES" -ge 20 ]; then
        echo "⏭  跳过 $slug：已存在且 design.md 已编辑（$LINES 行）"
        SKIPPED=$((SKIPPED+1))
        continue
      fi
    else
      echo "⏭  跳过 $slug：已存在（用 --force 可覆盖空骨架）"
      SKIPPED=$((SKIPPED+1))
      continue
    fi
  fi

  mkdir -p "$TARGET"
  cp "$EXAMPLE_DIR/design.md" "$TARGET/design.md"
  sed -i "s|{{MODULE_NAME}}|$MNAME|g; s|{{MODULE_SLUG}}|$slug|g; s|_example|$slug|g" "$TARGET/design.md"

  # reqs.json
  REQS_JSON_ARR=$(printf '%s\n' $REQS_LIST | jq -R '{id: ., title: "", priority: "P1", status: "draft"}' | jq -s .)
  jq -n --arg mod "$slug" --arg mn "$MNAME" --argjson reqs "$REQS_JSON_ARR" '{
    module: $mod,
    module_name: $mn,
    type: "business",
    priority: "P1",
    reqs: $reqs
  }' > "$TARGET/reqs.json"

  # apis.json
  jq -n --arg mod "$slug" '{
    module: $mod,
    base_path: ("/api/v1/" + $mod),
    description: "",
    apis: []
  }' > "$TARGET/apis.json"

  CREATED=$((CREATED+1))
  echo "✅ 已创建模块: $slug  (关联 $(echo $REQS_LIST | wc -w) 条需求)"
done

echo ""
echo "📊 总结: 新建 $CREATED 个 / 跳过 $SKIPPED 个"
echo "🔄 自动 sync-solution-map ..."
bash "$SKILL_DIR/scripts/sync-solution-map.sh" "$PROJECT" --quiet
echo "✅ 完成。请人工审阅 modules/*/design.md / reqs.json，再补 apis.json。"

exit 0
