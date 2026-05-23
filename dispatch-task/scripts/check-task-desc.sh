#!/bin/bash
# check-task-desc.sh - 任务描述合规性校验（打分制）
#
# 用法：
#   bash check-task-desc.sh <task-description-file>
#   cat task.md | bash check-task-desc.sh -    # 从 stdin 读
#
# 输出：
#   ✅ PASS (score≥80)
#   ⚠️ WARN (60-79)
#   ❌ FAIL (<60)
#
# exit 0 = 可派发, 1 = 建议优化, 2 = 禁止派发

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo "用法: $0 <task-file>  或  cat task.md | $0 -" >&2
    exit 3
fi

if [ "$1" = "-" ]; then
    CONTENT=$(cat)
elif [ -e "$1" ] && [ -r "$1" ]; then
    CONTENT=$(cat "$1")
else
    echo "❌ 文件不存在或不可读: $1" >&2
    exit 3
fi

score=100
issues=()

# ❌ 致命：出现"读取/参考/看一下" + 文件路径关键词（粗略匹配）
if echo "$CONTENT" | grep -E "(读取|参考|看一下|查看|读一下).*\.(prisma|ts|tsx|js|py|md|json|sql|html|css|sh)" -q; then
    score=$((score - 50))
    issues+=("${RED}❌ -50 出现「读取/参考/查看 XX 大文件」指令，应主Agent 先消化后内联要点${NC}")
fi

# ❌ 致命：没有任何绝对路径（要求至少 1 个 /xxx/ 路径）
if ! echo "$CONTENT" | grep -E "(/var/|/home/|/tmp/|/etc/|/opt/|/usr/|/root/)" -q; then
    score=$((score - 30))
    issues+=("${RED}❌ -30 任务描述缺绝对路径，子 Agent 会猜路径${NC}")
fi

# ❌ 重要：没有 commit/push/部署/build/test 任何关键词
if ! echo "$CONTENT" | grep -E "(commit|push|部署|deploy|build|测试|test)" -iq; then
    score=$((score - 20))
    issues+=("${RED}❌ -20 没有「commit/push/部署/build/测试」执行链路${NC}")
fi

# ⚠️ 估时 > 5 分钟
if echo "$CONTENT" | grep -E "(预估|耗时|时间).*([6-9]|[0-9]{2,}).*(分钟|min)" -q; then
    score=$((score - 10))
    issues+=("${YELLOW}⚠️  -10 估时 > 5 分钟，建议拆分${NC}")
fi

# ⚠️ 提到生成大文件（HTML/MD/JSON）但没提 write-large-file.sh
if echo "$CONTENT" | grep -E "(生成|创建|新建|写).*\.(html|md|json|tsx|ts)" -q; then
    if ! echo "$CONTENT" | grep -E "(write-large-file|heredoc|cat <<)" -q; then
        score=$((score - 15))
        issues+=("${YELLOW}⚠️  -15 涉及生成文件却未提 write-large-file.sh / heredoc，可能触发 OpenClaw write 10KB 截断${NC}")
    fi
fi

# 输出
echo "═══════════════════════════════════════"
echo "  任务描述合规性校验"
echo "═══════════════════════════════════════"
if [ ${#issues[@]} -eq 0 ]; then
    echo -e "${GREEN}✅ 无违规${NC}"
else
    for i in "${issues[@]}"; do echo -e "  $i"; done
fi
echo "---------------------------------------"
echo "  分数：$score / 100"

if [ "$score" -ge 80 ]; then
    echo -e "  结论：${GREEN}✅ PASS 可派发${NC}"
    exit 0
elif [ "$score" -ge 60 ]; then
    echo -e "  结论：${YELLOW}⚠️  WARN 建议优化${NC}"
    exit 1
else
    echo -e "  结论：${RED}❌ FAIL 禁止派发${NC}"
    exit 2
fi
