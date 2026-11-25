#!/bin/bash
# trigger-req.sh - 需求/Bug 触发入口
#
# 用法：
#   bash trigger-req.sh "<龙哥反馈的原话>"
#
# 自动识别：
#   - 项目（智策/晨曦/智院/权舆/智签/智客/智财）
#   - 类型（功能 / Bug）
#   - 优先级（默认 P1，含"紧急/必须立即"→P0）
#   - 编号（扫描 docs-repos/<project>/requirements/REQ-YYYYMMDD-*.md 自增）

set -euo pipefail

WORKSPACE="/var/lib/openclaw/.openclaw/workspace"

if [ "${1:-}" = "--subagent" ]; then
  echo "❌ req-trigger 只能由主Agent调用，子Agent禁止" >&2
  exit 1
fi

INPUT="${1:-}"
[ -z "$INPUT" ] && { echo "❌ 请输入需求/bug内容"; exit 1; }

# 移除斜杠/前缀
INPUT="${INPUT#/req }"
INPUT="${INPUT#\[REQ\] }"
INPUT="${INPUT#\[BUG\] }"
INPUT="${INPUT#\[FEEDBACK\] }"

ORIGINAL="$INPUT"

# 提取显式优先级
PRIORITY="P1"
if [[ "$INPUT" == *"-p P0"* ]] || [[ "$INPUT" == *"紧急"* ]] || [[ "$INPUT" == *"必须立即"* ]]; then
  PRIORITY="P0"
elif [[ "$INPUT" == *"-p P2"* ]] || [[ "$INPUT" == *"可延后"* ]]; then
  PRIORITY="P2"
fi
INPUT=$(echo "$INPUT" | sed 's/-p P[012]//g')

# 项目映射
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

# ─── 类型识别（Bug vs 功能）─────────────────────
# Bug 关键词：
#   - 显式错误：bug / 404 / 500 / 故障 / 报错 / 崩溃 / 闪退
#   - 现象与预期不符："应该...但是..." / "没有...到..." / "不能..." / "无法..."
#   - 修复类：修复 / 修一下
# 功能关键词：
#   - 新增 / 增加 / 需要 / 希望 / 想要 / 添加
TYPE="功能"
CATEGORY="业务功能"

# Bug 判定（任一命中即为 Bug）
if [[ "$INPUT" == *"bug"* ]] || \
   [[ "$INPUT" == *"404"* ]] || \
   [[ "$INPUT" == *"500"* ]] || \
   [[ "$INPUT" == *"故障"* ]] || \
   [[ "$INPUT" == *"报错"* ]] || \
   [[ "$INPUT" == *"崩溃"* ]] || \
   [[ "$INPUT" == *"闪退"* ]] || \
   [[ "$INPUT" == *"修复"* ]] || \
   [[ "$INPUT" == *"修一下"* ]] || \
   [[ "$INPUT" == *"指向错误"* ]] || \
   ( [[ "$INPUT" == *"应该"* ]] && [[ "$INPUT" == *"但"* ]] ) || \
   ( [[ "$INPUT" == *"应该"* ]] && [[ "$INPUT" == *"没"* ]] ) || \
   [[ "$INPUT" == *"不能进入"* ]] || \
   [[ "$INPUT" == *"无法访问"* ]] || \
   [[ "$INPUT" == *"打不开"* ]]; then
  TYPE="Bug"
  CATEGORY="非功能需求"
fi

# 功能判定优先级低于 Bug（如果同时含"新增/增加"且不含 Bug 关键词才覆盖）
if [ "$TYPE" = "功能" ]; then
  if [[ "$INPUT" == *"新增"* ]] || [[ "$INPUT" == *"增加"* ]] || [[ "$INPUT" == *"添加功能"* ]]; then
    TYPE="功能"
    CATEGORY="业务功能"
  fi
fi

# ─── 标题压缩（≤30字符，去掉项目名）─────────────
TITLE="$INPUT"
if [ -n "$PROJECT_NAME" ]; then
  TITLE=$(echo "$TITLE" | sed "s/${PROJECT_NAME}系统//g" | sed "s/${PROJECT_NAME}//g")
fi
TITLE=$(echo "$TITLE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
# 取第一个句子（"," "。" "，" 作为分隔）
TITLE=$(echo "$TITLE" | awk -F'[,，。]' '{print $1}')
# 截断到 40 字符
if [ ${#TITLE} -gt 40 ]; then
  TITLE="${TITLE:0:40}..."
fi

# ─── 编号生成（扫描已有 REQ + 自增）─────────────
TODAY=$(date +%Y%m%d)
REQ_DIR="$WORKSPACE/docs-repos/$PROJECT_ID/requirements"

NEXT_NUM=1
if [ -d "$REQ_DIR" ]; then
  LAST=$(ls "$REQ_DIR"/REQ-${TODAY}-*.md 2>/dev/null | sed -E "s/.*REQ-${TODAY}-([0-9]+)\.md/\1/" | sort -n | tail -1 || true)
  if [ -n "${LAST:-}" ]; then
    NEXT_NUM=$((10#$LAST + 1))
  fi
fi
REQ_ID=$(printf "REQ-%s-%03d" "$TODAY" "$NEXT_NUM")

# ─── 输出 ──────────────────────────────────────
ICON="📋"
[ "$TYPE" = "Bug" ] && ICON="🐛"

cat <<EOF
================================================
✅ 龙哥哥，已记录${TYPE}反馈

${ICON} ${REQ_ID}
- 项目：${PROJECT_NAME} (${PROJECT_ID})
- 类型：${TYPE}
- 优先级：${PRIORITY}
- 标题：${TITLE}

📄 原始内容：
${ORIGINAL}
================================================

⛔ 按流程，我不能直接动手，请确认：
1. 是否还有其他需求/bug需要补充？
2. 是否需要安排设计/排查？
3. 输入 /approve 确认登记，写入正式 REQ 文件
   输入 /edit "<新标题>" 修改标题
   输入 /cancel 取消
================================================
EOF

# ─── 保存草稿 ─────────────────────────────────
TMP_DIR="/tmp/req-trigger"
mkdir -p "$TMP_DIR"
cat > "$TMP_DIR/latest-draft.json" <<EOF
{
  "req_id": "$REQ_ID",
  "project_id": "$PROJECT_ID",
  "project_name": "$PROJECT_NAME",
  "type": "$TYPE",
  "category": "$CATEGORY",
  "priority": "$PRIORITY",
  "title": "$TITLE",
  "content": "$ORIGINAL",
  "status": "draft-pending-approve",
  "created_at": "$(date -Iseconds)"
}
EOF

exit 0
