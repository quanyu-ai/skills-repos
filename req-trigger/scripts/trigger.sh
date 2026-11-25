#!/bin/bash
# trigger.sh - 需求/Bug 统一触发入口（分流到 REQ 或 BUG 两套体系）
#
# 用法：
#   bash trigger.sh "<龙哥反馈的原话>"
#
# 自动识别：
#   - 项目（智策/晨曦/智院/权舆/智签/智客/智财）
#   - 分类：
#     · Bug → BUG-YYYYMMDD-XXX（单独体系，docs-repos/<project>/bugs/）
#     · 需求新增 → REQ-YYYYMMDD-NNN type=new
#     · 需求变更 → REQ-YYYYMMDD-NNN type=change
#   - 优先级（默认 P1，"紧急/必须立即"→P0）

set -euo pipefail

WORKSPACE="/var/lib/openclaw/.openclaw/workspace"

if [ "${1:-}" = "--subagent" ]; then
  echo "❌ req-trigger 只能由主Agent调用，子Agent禁止" >&2
  exit 1
fi

INPUT="${1:-}"
[ -z "$INPUT" ] && { echo "❌ 请输入需求/bug内容"; exit 1; }

INPUT="${INPUT#/req }"
INPUT="${INPUT#/bug }"
INPUT="${INPUT#\[REQ\] }"
INPUT="${INPUT#\[BUG\] }"
INPUT="${INPUT#\[FEEDBACK\] }"
ORIGINAL="$INPUT"

# ─── 优先级 ──────────────────────────────────
PRIORITY="P1"
if [[ "$INPUT" == *"-p P0"* ]] || [[ "$INPUT" == *"紧急"* ]] || [[ "$INPUT" == *"必须立即"* ]]; then
  PRIORITY="P0"
elif [[ "$INPUT" == *"-p P2"* ]] || [[ "$INPUT" == *"可延后"* ]]; then
  PRIORITY="P2"
fi
INPUT=$(echo "$INPUT" | sed 's/-p P[012]//g')

# ─── 项目识别 ───────────────────────────────
declare -A PROJECT_MAP=(
  ["智策"]="smartops"
  ["晨曦"]="chenxi-study"
  ["智院"]="smart-college"
  ["权舆"]="quanyu-console"
  ["智签"]="contract-platform"
  ["智客"]="smartcs"
  ["智财"]="quanyu-finance"
)

PROJECT_ID=""
PROJECT_NAME=""
for KEY in "${!PROJECT_MAP[@]}"; do
  if [[ "$INPUT" == *"$KEY"* ]]; then
    PROJECT_ID="${PROJECT_MAP[$KEY]}"
    PROJECT_NAME="$KEY"
    break
  fi
done

if [ -z "$PROJECT_ID" ]; then
  echo "❓ 龙哥哥，没识别出项目，请说明：智策/晨曦/智院/权舆/智签/智客/智财"
  exit 0
fi

# ─── 分类识别（核心三分类）──────────────────
# 1) BUG：现有功能坏了/与预期不符
# 2) REQ-new：新功能/新增能力
# 3) REQ-change：已有功能的逻辑/规则要改
TRACK=""           # "bug" 或 "req"
REQ_SUBTYPE=""     # 只在 TRACK=req 时有值："new"/"change"

# BUG 判定：现有功能不正常
IS_BUG=false
if [[ "$INPUT" == *"bug"* ]] || \
   [[ "$INPUT" == *"BUG"* ]] || \
   [[ "$INPUT" == *"404"* ]] || \
   [[ "$INPUT" == *"500"* ]] || \
   [[ "$INPUT" == *"故障"* ]] || \
   [[ "$INPUT" == *"报错"* ]] || \
   [[ "$INPUT" == *"崩溃"* ]] || \
   [[ "$INPUT" == *"闪退"* ]] || \
   [[ "$INPUT" == *"打不开"* ]] || \
   [[ "$INPUT" == *"指向错误"* ]] || \
   ( [[ "$INPUT" == *"已经"* ]] && [[ "$INPUT" == *"但"* ]] ) || \
   ( [[ "$INPUT" == *"应该"* ]] && [[ "$INPUT" == *"但"* ]] && [[ "$INPUT" == *"没"* ]] ) || \
   ( [[ "$INPUT" == *"应该"* ]] && [[ "$INPUT" == *"没进入"* ]] ) || \
   [[ "$INPUT" == *"不能进入"* ]] || \
   [[ "$INPUT" == *"无法访问"* ]] || \
   [[ "$INPUT" == *"修复"* ]] || \
   [[ "$INPUT" == *"修一下"* ]]; then
  IS_BUG=true
fi

if $IS_BUG; then
  TRACK="bug"
else
  TRACK="req"
  # 需求变更 vs 需求新增
  if [[ "$INPUT" == *"变更"* ]] || \
     [[ "$INPUT" == *"改成"* ]] || \
     [[ "$INPUT" == *"调整"* ]] || \
     [[ "$INPUT" == *"修改"* ]] || \
     [[ "$INPUT" == *"优化"* ]] || \
     [[ "$INPUT" == *"改为"* ]]; then
    REQ_SUBTYPE="change"
  else
    REQ_SUBTYPE="new"
  fi
fi

# ─── 标题压缩 ───────────────────────────────
TITLE="$INPUT"
TITLE=$(echo "$TITLE" | sed "s/${PROJECT_NAME}系统//g" | sed "s/${PROJECT_NAME}//g")
TITLE=$(echo "$TITLE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
TITLE=$(echo "$TITLE" | awk -F'[,，。]' '{print $1}')
if [ ${#TITLE} -gt 40 ]; then
  TITLE="${TITLE:0:40}..."
fi

# ─── 编号生成 ───────────────────────────────
TODAY=$(date +%Y%m%d)

if [ "$TRACK" = "bug" ]; then
  TARGET_DIR="$WORKSPACE/docs-repos/$PROJECT_ID/bugs"
  PREFIX="BUG"
  ICON="🐛"
  LABEL="Bug"
else
  TARGET_DIR="$WORKSPACE/docs-repos/$PROJECT_ID/requirements"
  PREFIX="REQ"
  ICON="📋"
  if [ "$REQ_SUBTYPE" = "change" ]; then
    LABEL="需求变更"
  else
    LABEL="需求新增"
  fi
fi

NEXT_NUM=1
if [ -d "$TARGET_DIR" ]; then
  LAST=$(ls "$TARGET_DIR"/${PREFIX}-${TODAY}-*.md 2>/dev/null | sed -E "s/.*${PREFIX}-${TODAY}-([0-9]+)\.md/\1/" | sort -n | tail -1 || true)
  if [ -n "${LAST:-}" ]; then
    NEXT_NUM=$((10#$LAST + 1))
  fi
fi
ITEM_ID=$(printf "%s-%s-%03d" "$PREFIX" "$TODAY" "$NEXT_NUM")

# ─── 输出 ──────────────────────────────────
EXTRA=""
[ "$TRACK" = "req" ] && EXTRA="（${LABEL}）"

cat <<EOF
================================================
✅ 龙哥哥，已记录${LABEL}

${ICON} ${ITEM_ID}${EXTRA}
- 项目：${PROJECT_NAME} (${PROJECT_ID})
- 优先级：${PRIORITY}
- 标题：${TITLE}

📄 原始内容：
${ORIGINAL}
================================================

⛔ 按流程，我不能直接动手，请龙哥确认：
1. 还有其他 需求/Bug 要补充吗？（说「还有：xxx」我接着记）
2. 标题/分类对吗？（说「改标题为 xxx」或「分类错了，是需求变更」）
3. 确认登记吗？（说「确认」或「OK」我就写入正式 ${PREFIX} 文件）
4. 不要了就说「取消」
================================================
EOF

# ─── 保存草稿 ─────────────────────────────────
TMP_DIR="/tmp/req-trigger"
mkdir -p "$TMP_DIR"
cat > "$TMP_DIR/latest-draft.json" <<EOF
{
  "item_id": "$ITEM_ID",
  "track": "$TRACK",
  "req_subtype": "$REQ_SUBTYPE",
  "project_id": "$PROJECT_ID",
  "project_name": "$PROJECT_NAME",
  "priority": "$PRIORITY",
  "title": "$TITLE",
  "content": "$ORIGINAL",
  "target_dir": "$TARGET_DIR",
  "status": "draft-pending-approve",
  "created_at": "$(date -Iseconds)"
}
EOF

exit 0
