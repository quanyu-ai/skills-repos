#!/bin/bash
# pre-dispatch.sh - 派发前 10 项必检（强化版 2026-05-24）
#
# 用法：
#   bash pre-dispatch.sh <task-description-file>
#
# 检查（5 项基础 + 5 项强化）：
#   1. 任务描述合规性（调 check-task-desc.sh）
#   2. TASK-TRACKER.json 中是否有对应 TASK-ID
#   3. 工作目录是否给了绝对路径
#   4. 是否提及执行链路
#   5. 是否提及大文件方法（如适用）
#   6. 任务描述完整性：≥500 字 + 含"工作目录"+"完成后"+"重要约束"
#   7. 大文件防呆：若涉及生成 >10KB 必须出现 write-large-file/heredoc
#   8. 防呆约束：必须含"不 sessions_yield" 或同义表达
#   9. 超时合理性：runTimeoutSeconds >= estimatedMinutes * 60 * 1.5
#  10. 依赖文件存在性：扫描描述里的路径，不存在的告警

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
echo "  派发前必检（10 项 / 强化版）"
echo "═══════════════════════════════════════"

# 字数（中文按字符计）
CHAR_COUNT=$(echo -n "$CONTENT" | wc -m)


# 1. 合规性
echo "[1/10] 任务描述合规性..."
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
echo "[2/10] TASK-TRACKER.json 登记..."
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
echo "[3/10] 绝对路径..."
ap_count=$(echo "$CONTENT" | grep -oE "/var/|/home/|/tmp/|/etc/|/opt/" | wc -l || true)
if [ "$ap_count" -ge 1 ]; then
    echo -e "  ${GREEN}✅ PASS${NC}  发现 $ap_count 处绝对路径"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  无绝对路径"
fi

# 4. 执行链路
echo "[4/10] 执行链路（commit/push/build/部署）..."
if echo "$CONTENT" | grep -E "(commit|push|部署|deploy|build|测试)" -iq; then
    echo -e "  ${GREEN}✅ PASS${NC}"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  缺执行链路关键词"
fi

# 5. 大文件方法
echo "[5/10] 大文件提示..."
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

# 6. 任务描述完整性
echo "[6/10] 任务描述完整性..."
missing=()
if [ "$CHAR_COUNT" -lt 500 ]; then missing+=("长度<500字(实际$CHAR_COUNT)"); fi
if ! echo "$CONTENT" | grep -q "工作目录"; then missing+=("缺『工作目录』"); fi
if ! echo "$CONTENT" | grep -E "(完成后|完成后必)" -q; then missing+=("缺『完成后』"); fi
if ! echo "$CONTENT" | grep -E "(重要约束|约束|防呆)" -q; then missing+=("缺『重要约束/约束/防呆』"); fi
if [ ${#missing[@]} -eq 0 ]; then
    echo -e "  ${GREEN}✅ PASS${NC}  字数=$CHAR_COUNT 必含段齐全"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  缺失：${missing[*]}"
fi

# 7. 大文件防呆（强化版）
echo "[7/10] 大文件防呆（生成/创建/写入关键词）..."
if echo "$CONTENT" | grep -E "(生成|创建|写入|产出|新建).*\.(html|md|json|tsx?|css|sh)" -q; then
    if echo "$CONTENT" | grep -E "(write-large-file|heredoc|cat\s*<<)" -q; then
        echo -e "  ${GREEN}✅ PASS${NC}  已提示大文件方法"
    else
        fail=$((fail+1))
        echo -e "  ${RED}❌ FAIL${NC}  涉及生成文件却未提 write-large-file.sh / heredoc（>10KB 必触发截断）"
    fi
else
    echo -e "  ${GREEN}✅ N/A${NC}  无生成文件关键词"
fi

# 8. 防呆约束（不 sessions_yield / 完成后回报）
echo "[8/10] 防呆约束（不 sessions_yield + 完成后回报）..."
miss_constraint=()
if ! echo "$CONTENT" | grep -E "(不\s*sessions_yield|sessions_yield.*禁用|禁用.*sessions_yield|不要.*yield)" -q; then
    miss_constraint+=("不 sessions_yield")
fi
if ! echo "$CONTENT" | grep -E "(完成后回报|完成后必含|回报真实|回报：|回报清单)" -q; then
    miss_constraint+=("完成后回报")
fi
if [ ${#miss_constraint[@]} -eq 0 ]; then
    echo -e "  ${GREEN}✅ PASS${NC}"
else
    fail=$((fail+1))
    echo -e "  ${RED}❌ FAIL${NC}  缺：${miss_constraint[*]}"
fi

# 9. 超时合理性
echo "[9/10] 超时合理性..."
est_min=$(echo "$CONTENT" | grep -oE "(预估|预计|耗时)\s*([0-9]+)\s*(分钟|min)" 2>/dev/null | head -1 | grep -oE "[0-9]+" 2>/dev/null | head -1 || true)
if [ -n "$TASK_ID" ] && [ -f "$TRACKER" ]; then
    timeout_sec=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id==$id) | .timeoutSeconds // .runTimeoutSeconds // empty' "$TRACKER" 2>/dev/null | head -1)
    if [ -n "$est_min" ] && [ -n "$timeout_sec" ]; then
        min_required=$(( est_min * 60 * 3 / 2 ))
        if [ "$timeout_sec" -ge "$min_required" ]; then
            echo -e "  ${GREEN}✅ PASS${NC}  est=${est_min}min timeout=${timeout_sec}s (需≥${min_required}s)"
        else
            warn=$((warn+1))
            echo -e "  ${YELLOW}⚠️  WARN${NC}  timeout=${timeout_sec}s < est*1.5=${min_required}s"
        fi
    else
        echo -e "  ${GREEN}✅ SKIP${NC}  est_min/timeout 缺失，无法校验"
    fi
else
    echo -e "  ${GREEN}✅ SKIP${NC}  无 TASK 登记，跳过"
fi

# 10. 依赖文件存在性
echo "[10/10] 依赖文件存在性扫描..."
# 抓 path-like 字符串：xxx/xxx.ext 或 /abs/path/file.ext
missing_paths=()
while IFS= read -r p; do
    [ -z "$p" ] && continue
    # 跳过明显是 URL / 命令选项 / 占位符
    case "$p" in
        http*|*'<'*|*'>'*|*'{'*|*'$'*) continue ;;
    esac
    # 相对路径转工作区绝对
    abs="$p"
    [[ "$abs" = /* ]] || abs="$WORKSPACE/$p"
    [ -e "$abs" ] || missing_paths+=("$p")
done < <(echo "$CONTENT" | grep -oE "[A-Za-z0-9_./-]+\.(md|json|sh|ts|tsx|js|html|css|prisma|yml|yaml|sql)" | sort -u)
if [ ${#missing_paths[@]} -eq 0 ]; then
    echo -e "  ${GREEN}✅ PASS${NC}  扫描到的路径全部存在"
else
    # 限制最多展示 5 条
    show="${missing_paths[*]:0:5}"
    warn=$((warn+1))
    echo -e "  ${YELLOW}⚠️  WARN${NC}  ${#missing_paths[@]} 条路径不存在（示例：$show）"
fi

echo "---------------------------------------"
echo "  汇总：fail=$fail warn=$warn  字数=$CHAR_COUNT"
if [ -n "$TASK_ID" ]; then echo "  TASK: $TASK_ID"; fi
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
