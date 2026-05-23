#!/bin/bash
# add-global-milestone.sh - 追加一条全局里程碑（无项目归属，跨项目 / 平台 / 战略 / 流程类）
# Usage: add-global-milestone.sh "<title>" --category skill|infra|strategy|platform|process [--date YYYY-MM-DD]
set -e
. "$(dirname "$0")/_lib.sh"

usage() {
    echo 'Usage: '"$0"' "<title>" --category skill|infra|strategy|platform|process [--date YYYY-MM-DD]' >&2
    exit 1
}

[ $# -lt 1 ] && usage
TITLE="$1"; shift
CAT=""
DATE=$(today)
while [ $# -gt 0 ]; do
    case "$1" in
        --category) CAT="$2"; shift 2 ;;
        --date) DATE="$2"; shift 2 ;;
        *) echo "unknown: $1" >&2; usage ;;
    esac
done

[ -z "$TITLE" ] && { echo "✗ title 不能为空" >&2; usage; }
[ -z "$CAT" ] && { echo "✗ 必须 --category" >&2; usage; }

case "$CAT" in
    skill|infra|strategy|platform|process) ;;
    *) echo "✗ 非法 category '$CAT'（仅支持 skill / infra / strategy / platform / process）" >&2; exit 1 ;;
esac

GMF="$WORKSPACE_ROOT/knowledge-repos/management/GLOBAL-MILESTONES.md"
if [ ! -f "$GMF" ]; then
    {
        echo "# 全局里程碑 GLOBAL-MILESTONES"
        echo
        echo "> 跨项目 / 平台级 / 工具基建类里程碑。项目级里程碑请走 skills/project-mgmt/scripts/add-milestone.sh。"
        echo
        echo "| 日期 | 分类 | 标题 |"
        echo "|------|------|------|"
    } > "$GMF"
fi

echo "| $DATE | $CAT | $TITLE |" >> "$GMF"
echo "✓ + global-milestone: [$DATE][$CAT] $TITLE"

auto_refresh_context
