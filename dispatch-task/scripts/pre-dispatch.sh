#!/bin/bash
# pre-dispatch.sh - 派发前 5 项必检
#
# 用法：
#   bash pre-dispatch.sh <task-description-file>
#
# 检查：
#   1. 任务描述合规性（调 check-task-desc.sh）
#   2. TASK-TRACKER.json 中是否有对应 TASK-ID
#   3. 工作目录是否给了绝对路径
#   4. 是否提及执行链路
#   5. 是否提及大文件方法（如适用）

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/var/lib/openclaw/.openclaw/workspace}"
TRACKER="$WORKSPACE/knowledge-repos/management/TASK-TRACKER.json"

if [ $# -lt 1 ]; then
    echo "用法: $0 <task-file>" >&2
    exit 3
fi

if [ ! -f "$1" ]; then
    echo "❌ 任务文件不存在: $1" >&2
    exit 3
fi

TASK_FILE="$1"
CONTENT=$(cat "$TASK_FILE")
fail=0
warn=0

echo "═══════════════════════════════════════"
echo "  派发前必检（5 项）"
echo "═══════════════════════════════════════"

# 1. 合规性
echo "[1/5] 任务描述合规性..."
if bash "$SCRIPT_DIR/check-task-desc.sh" "$TASK_FILE" > /tmp/check-task-desc.out 2>&1; then
    score_line=$(grep -E "(分数|score)" /tmp/check-task-desc.out | head -1)
    echo -e "  ${GREEN}✅ PASS${NC}  $score_line"
else
    rc=$?
    if [ "$rc" = "1" ]; then
        warn=$((warn+1))
        echo -e "  ${YELLOW}⚠️  WARN${NC}  $(grep -E 分数 /tmp/check-task-desc.out | head -1)"
    else
        fail=$((fail+1))
        echo -e "  ${RED}❌ FAIL${NC}  详情：cat /tmp/check-task-desc.out"
    fi
fi

# 2. TASK-TRACKER 登记
echo "[2/5] TASK-TRACKER.json 登记..."
TASK_ID=$(grep -oE "TASK-[0-9]{8}-[0-9A-Z]+" "$TASK_FILE" | head -1 || true)
if [ -z "$TASK_ID" ]; then
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  任务描述未含 TASK-YYYYMMDD-NNN 格式 ID"
elif [ ! -f "$TRACKER" ]; then
    warn=$((warn+1))
    echo -e "  ${YELLOW}⚠️  WARN${NC}  TASK-TRACKER.json 不存在: $TRACKER"
elif grep -q "\"$TASK_ID\"" "$TRACKER"; then
    echo -e "  ${GREEN}✅ PASS${NC}  $TASK_ID 已登记"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  $TASK_ID 未在 TRACKER 登记"
fi

# 3. 绝对路径
echo "[3/5] 绝对路径..."
ap_count=$(echo "$CONTENT" | grep -oE "/var/|/home/|/tmp/|/etc/|/opt/" | wc -l)
if [ "$ap_count" -ge 1 ]; then
    echo -e "  ${GREEN}✅ PASS${NC}  发现 $ap_count 处绝对路径"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  无绝对路径"
fi

# 4. 执行链路
echo "[4/5] 执行链路（commit/push/build/部署）..."
if echo "$CONTENT" | grep -E "(commit|push|部署|deploy|build|测试)" -iq; then
    echo -e "  ${GREEN}✅ PASS${NC}"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  缺执行链路关键词"
fi

# 5. 大文件方法
echo "[5/5] 大文件提示..."
if echo "$CONTENT" | grep -E "\.(html|md|json|tsx|ts)" -q; then
    if echo "$CONTENT" | grep -E "(write-large-file|heredoc|cat <<)" -q; then
        echo -e "  ${GREEN}✅ PASS${NC}  已提示 write-large-file.sh / heredoc"
    else
        warn=$((warn+1))
        echo -e "  ${YELLOW}⚠️  WARN${NC}  涉及生成文件，建议加 write-large-file.sh 提示"
    fi
else
    echo -e "  ${GREEN}✅ N/A${NC}  无大文件生成需求"
fi

echo "---------------------------------------"
echo "  汇总：fail=$fail warn=$warn"
if [ "$fail" -gt 0 ]; then
    echo -e "  ${RED}❌ 禁止派发${NC}"
    exit 2
elif [ "$warn" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠️  可派发，但建议优化${NC}"
    exit 1
else
    echo -e "  ${GREEN}✅ 全部通过，放心 spawn${NC}"
    exit 0
fi
