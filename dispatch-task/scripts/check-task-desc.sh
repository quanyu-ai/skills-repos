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

# ❌ 致命：出现"读取/参考/看一下 XX 业务大文件"（精细化匹配，2026-05-24 调优）
#
# 规则：
#   触发条件 = 关键词(读/查/参考/查看/阅读) + 30 字内出现明确文件路径
#   且：文件名不在通用调研白名单（hooks.md/building-plugins.md/README.md/SKILL.md/AGENTS.md/SOUL.md 等）
#   且：文件名带路径分隔符 / 或扩展名属业务代码类（.prisma/.tsx/.ts/.py/.sql 等）
#
# 放行：
#   - 纯短语 "看一下文档" "查文档" "调研一下"（无具体文件名）
#   - 调研通用文档（hooks.md / building-plugins.md / SKILL.md / README.md 等）

KW_RE="(读取|参考|查看|阅读|读一下|看一下)"
# 业务大文件扩展名（代码/数据/Schema 类，不含通用 md/json）
BIZ_EXT_RE="\.(prisma|tsx?|jsx?|py|sql|html|css|sh)"
# 通用调研类文档白名单（命中则放行）
RESEARCH_WHITELIST_RE="(hooks\.md|building-plugins\.md|README\.md|SKILL\.md|AGENTS\.md|SOUL\.md|USER\.md|IDENTITY\.md|TOOLS\.md|MEMORY\.md|CHANGELOG\.md|LICENSE)"

# 判定 1：业务代码大文件（高危）—— 关键词 + 业务扩展名（30 字内）
if echo "$CONTENT" | grep -E "$KW_RE.{0,30}[A-Za-z0-9_./-]+$BIZ_EXT_RE" -q; then
    score=$((score - 50))
    issues+=("${RED}❌ -50 出现「读取/参考 XX 业务代码大文件」指令，应主Agent 先消化后内联要点${NC}")
fi

# 判定 2：明确 .md/.json 大文件（但排除调研白名单）
if echo "$CONTENT" | grep -oE "$KW_RE.{0,30}[A-Za-z0-9_./-]+\.(md|json)" \
    | grep -vE "$RESEARCH_WHITELIST_RE" \
    | grep -qE "$KW_RE"; then
    score=$((score - 50))
    issues+=("${RED}❌ -50 出现「读取/参考 XX 业务文档(md/json)」指令，应主Agent 先消化后内联要点${NC}")
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

# ❌ 致命：提到生成大文件（HTML/MD/JSON）但没提 write-large-file.sh
if echo "$CONTENT" | grep -E "(生成|创建|新建|写).*\.(html|md|json|tsx|ts)" -q; then
    if ! echo "$CONTENT" | grep -E "(write-large-file|heredoc|cat <<)" -q; then
        score=$((score - 20))
        issues+=("${RED}❌ -20 涉及生成文件却未提 write-large-file.sh / heredoc，会触发 OpenClaw write 10KB 截断${NC}")
    fi
fi

# ❌ 致命：涉及修改 skills/ 目录下的脚本文件（违反 AGENTS.md 第1条铁律）
if echo "$CONTENT" | grep -E "skills/[a-z0-9-]+/scripts/.*\.(sh|ts|js|tsx)" -q; then
    score=$((score - 50))
    issues+=('${RED}❌ -50 涉及修改技能脚本文件，必须使用子Agent派发，违反 AGENTS.md 第1条铁律${NC}')
fi

# ❌ 重要：涉及覆盖/重写文件但未提备份/确认
if echo "$CONTENT" | grep -E "(覆盖|重写|替换|覆盖.*文件|覆盖.*配置)" -q; then
    if ! echo "$CONTENT" | grep -E "(备份|确认|允许覆盖|已获授权|经.*批准)" -q; then
        score=$((score - 30))
        issues+=('${RED}❌ -30 涉及覆盖文件但未提备份/确认/授权${NC}')
    fi
fi

# ⚠️ 防呆：没有「完成后」或「回报清单」
if ! echo "$CONTENT" | grep -E "(完成后必含|完成后回报|回报清单|回报真实产出|回报：)" -q; then
    score=$((score - 10))
    issues+=("${RED}❌ -10 任务描述缺「完成后必含/回报清单」，子 Agent 会交「已完成」代替产出详情${NC}")
fi

# ⚠️ 防呆：没有 ls/wc/du/git 验证命令
if ! echo "$CONTENT" | grep -E "\bls\b|\bwc\b|\bdu\b|\bgit\s+(status|log|rev-parse)\b" -q; then
    score=$((score - 10))
    issues+=("${RED}❌ -10 任务描述未要求跱 ls / wc / du / git 验证命令，无法验证真实产出${NC}")
fi

# ⚠️ 防呆：没有明示「不允许思考代替行动」
if ! echo "$CONTENT" | grep -E "(思考代替行动|只规划不|模糊表达|不允许.*设计|不要只写方案)" -q; then
    # 轻量警告，不严重扣分
    score=$((score - 5))
    issues+=("${YELLOW}⚠️  -5 未明示「不允许思考代替行动」，建议加反-以思考代替行动约束${NC}")
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
