#!/bin/bash
# new-triggered-req.sh - 根据用户输入创建需求草案
#
# 用法：
#   bash new-triggered-req.sh <project> "<description>" [--priority P0|P1|P2]
#   例：bash new-triggered-req.sh smartops "首页404修复" --priority P1
#
# 输出：
#   - REQ草案（未创建文件）
#   - 等待用户确认

set -euo pipefail

PROJECT=""
DESCRIPTION=""
PRIORITY="P1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --priority)
      PRIORITY="$2"
      shift 2
      ;;
    *)
      if [ -z "$PROJECT" ]; then
        PROJECT="$1"
      else
        DESCRIPTION="$1"
      fi
      shift
      ;;
  esac
done

# 验证参数
if [ -z "$PROJECT" ] || [ -z "$DESCRIPTION" ]; then
  echo "❌ 用法: bash new-triggered-req.sh <project> \"<description>\" [--priority P0|P1|P2]" >&2
  exit 1
fi

# 项目映射
PROJECT_MAP=(
  "智策:smartops"
  "晨曦:chenxi-study"
  "智院:smart-college"
  "权舆:quanyu-console"
  "智签:contract-platform"
)

# 解析项目
PROJECT_ID=""
for map in "${PROJECT_MAP[@]}"; do
  KEY="${map%%:*}"
  VAL="${map##*:}"
  if [[ "$PROJECT" == *"$KEY"* ]]; then
    PROJECT_ID="$VAL"
    break
  fi
done

if [ -z "$PROJECT_ID" ]; then
  echo "❌ 无法识别项目，请说清楚是哪个项目（智策/晨曦/智院/权舆/智签）" >&2
  exit 1
fi

# 类型识别（更准确的关键词）
CATEGORY="业务功能"
if [[ "$DESCRIPTION" == *"bug"* ]] || [[ "$DESCRIPTION" == *"错误"* ]] || [[ "$DESCRIPTION" == *"404"* ]] || [[ "$DESCRIPTION" == *"500"* ]] || [[ "$DESCRIPTION" == *"故障"* ]]; then
  CATEGORY="非功能需求"
fi

# 优先级验证
if [[ ! "$PRIORITY" =~ ^(P0|P1|P2)$ ]]; then
  echo "❌ 优先级必须是 P0/P1/P2" >&2
  exit 1
fi

# 输出草案
echo "✅ 已识别需求："
echo "- 项目：$PROJECT_ID"
echo "- 标题：$DESCRIPTION"
echo "- 类型：${CATEGORY} (根据关键词识别)"
echo "- 优先级：$PRIORITY"
echo ""
echo "我来创建 REQ-$(date +%Y%m%d)-NNN.md"
echo "等待确认中..."
echo ""
echo "输入 /approve 确认创建"
echo "或 /edit 修改描述"
echo "或 /cancel 取消"

# 保存草案信息到临时文件
TMP_DIR="/tmp/req-trigger"
mkdir -p "$TMP_DIR"
cat > "$TMP_DIR/draft-$(date +%Y%m%d-%H%M%S).json" <<EOF
{
  "project_id": "$PROJECT_ID",
  "title": "$DESCRIPTION",
  "category": "$CATEGORY",
  "priority": "$PRIORITY",
  "created_at": "$(date -Iseconds)",
  "status": "draft"
}
EOF

exit 0