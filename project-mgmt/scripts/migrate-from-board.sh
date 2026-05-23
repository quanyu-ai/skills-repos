#!/bin/bash
# migrate-from-board.sh - 把 PROJECT-BOARD.md 的历史条目映射到对应项目档案
# Usage:
#   migrate-from-board.sh              # dry-run（默认）
#   migrate-from-board.sh --apply      # 真迁移
#
# 策略：
#   1. 解析 PROJECT-BOARD.md「已完成里程碑」段（- ✅ YYYY-MM-DD ...）
#   2. 解析「活跃项目」「原型/方案阶段」「待启动项目」表格行 → 当前状态作为里程碑
#   3. 关键字匹配项目（智院/智财/智策/智客/智签/官网/控制台/晨曦学园）
#   4. 匹配不到 → 归入「全局里程碑」（输出到迁移报告，不写项目）
#   5. 含「决策/选择/方案/确认/上线/采用」类关键字 → 同时调 add-decision
#   6. 含「bug/事故/反馈/问题/失败」类关键字 → 同时调 add-incident

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

BOARD_FILE="$WORKSPACE_ROOT/knowledge-repos/management/PROJECT-BOARD.md"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$BOARD_FILE" ] || { echo "✗ $BOARD_FILE 不存在" >&2; exit 1; }

# 项目关键字 → id 映射
declare -A KEYWORD_MAP=(
    ["智院"]="smart-college"
    ["SmartCollege"]="smart-college"
    ["smart-college"]="smart-college"
    ["智财"]="quanyu-finance"
    ["拍记"]="quanyu-finance"
    ["财税通"]="quanyu-finance"
    ["AI财税"]="quanyu-finance"
    ["智策"]="smartops"
    ["SmartOps"]="smartops"
    ["smartops"]="smartops"
    ["智策平台"]="smartops"
    ["智客"]="smartcs"
    ["SmartCS"]="smartcs"
    ["答客"]="smartcs"
    ["客服通"]="smartcs"
    ["智客系统"]="smartcs"
    ["智签"]="contract-platform"
    ["契察"]="contract-platform"
    ["合同通"]="contract-platform"
    ["AI合同"]="contract-platform"
    ["官网"]="quanyu-website"
    ["权舆官网"]="quanyu-website"
    ["权舆科技官网"]="quanyu-website"
    ["控制台"]="quanyu-console"
    ["展示控制台"]="quanyu-console"
    ["权舆系统展示"]="quanyu-console"
    ["晨曦学园"]="chenxi-study"
    ["晨曦"]="chenxi-study"
)

# 匹配 line → project_id（取第一个命中的关键字）
match_project() {
    local line="$1"
    local kw
    for kw in "${!KEYWORD_MAP[@]}"; do
        if echo "$line" | grep -q "$kw"; then
            echo "${KEYWORD_MAP[$kw]}"
            return 0
        fi
    done
    return 1
}

# 分类（decision / incident / milestone）—— 同条可同时是多类
classify() {
    local line="$1"
    local types=""
    if echo "$line" | grep -Eq "决策|选择|采用|方案|确认|路线"; then
        types="$types decision"
    fi
    if echo "$line" | grep -Eq "bug|Bug|BUG|事故|反馈|失败|问题|崩溃|outage"; then
        types="$types incident"
    fi
    # 默认总是 milestone（除非纯 incident）
    if [ -z "$types" ] || echo "$types" | grep -q decision; then
        types="$types milestone"
    fi
    echo "$types" | xargs
}

# 统计
declare -A STAT_M STAT_D STAT_I
GLOBAL_LINES=()
APPLIED_LOG=()

# 执行（dry-run 或真做）
exec_or_log() {
    local action="$1"; shift
    local pid="$1"; shift
    local args=("$@")
    if [ "$APPLY" = "1" ]; then
        case "$action" in
            milestone)
                "$SCRIPT_DIR/add-milestone.sh" "$pid" "${args[0]}" --date "${args[1]}" >/dev/null
                ;;
            decision)
                "$SCRIPT_DIR/add-decision.sh" "$pid" "${args[0]}" --date "${args[1]}" >/dev/null
                ;;
            incident)
                "$SCRIPT_DIR/add-incident.sh" "$pid" "${args[0]}" --date "${args[1]}" --type inner --severity P2 >/dev/null
                ;;
        esac
    fi
    APPLIED_LOG+=("[$action][$pid] ${args[1]} ${args[0]}")
}

inc_stat() {
    local type="$1"; local pid="$2"
    case "$type" in
        milestone) STAT_M["$pid"]=$((${STAT_M[$pid]:-0}+1)) ;;
        decision)  STAT_D["$pid"]=$((${STAT_D[$pid]:-0}+1)) ;;
        incident)  STAT_I["$pid"]=$((${STAT_I[$pid]:-0}+1)) ;;
    esac
}

# 1. 解析「已完成里程碑」段
# 匹配格式：- ✅ YYYY-MM-DD <text>
echo "==> 扫描已完成里程碑段..."
while IFS= read -r line; do
    # 跳过非里程碑行
    echo "$line" | grep -Eq "^- ✅ [0-9]{4}-[0-9]{2}-[0-9]{2}" || continue
    date=$(echo "$line" | grep -Eo "[0-9]{4}-[0-9]{2}-[0-9]{2}" | head -1)
    title=$(echo "$line" | sed -E "s/^- ✅ [0-9]{4}-[0-9]{2}-[0-9]{2} *//")
    [ -z "$title" ] && continue
    pid=$(match_project "$title") || pid=""
    if [ -z "$pid" ]; then
        GLOBAL_LINES+=("$date | $title")
        continue
    fi
    types=$(classify "$title")
    for t in $types; do
        exec_or_log "$t" "$pid" "$title" "$date"
        inc_stat "$t" "$pid"
    done
done < "$BOARD_FILE"

# 2. 解析活跃项目 / 原型方案 / 待启动 三个表格
# 表格行：| 项目 | 状态 | 当前阶段 | ...
echo "==> 扫描项目表格段（当前状态作为快照里程碑）..."
TODAY=$(today)
while IFS= read -r line; do
    # 仅取以 | 开头、含「🟢/🟡/🔴/🔵」状态符号的行（排除表头）
    echo "$line" | grep -Eq "^\| .* \|" || continue
    echo "$line" | grep -Eq "🟢|🟡|🔴|🔵" || continue
    # 排除 TODO 表格行（含 TODO-）
    echo "$line" | grep -q "TODO-" && continue
    # 取项目名（第一列），去掉 ** 和括号内说明
    pname=$(echo "$line" | awk -F'|' '{print $2}' | sed 's/^[ *]*//;s/[ *]*$//')
    state=$(echo "$line" | awk -F'|' '{print $3}' | sed 's/^[ ]*//;s/[ ]*$//')
    stage=$(echo "$line" | awk -F'|' '{print $4}' | sed 's/^[ ]*//;s/[ ]*$//')
    [ -z "$pname" ] && continue
    pid=$(match_project "$pname") || pid=""
    if [ -z "$pid" ]; then
        GLOBAL_LINES+=("$TODAY | [board-row] $pname | $state | $stage")
        continue
    fi
    snapshot="board 状态快照：$state — $stage"
    exec_or_log "milestone" "$pid" "$snapshot" "$TODAY"
    inc_stat "milestone" "$pid"
done < "$BOARD_FILE"

# === 输出报告 ===
echo
echo "================ 迁移报告 ================"
if [ "$APPLY" = "1" ]; then
    echo "模式：APPLY（已实际写入）"
else
    echo "模式：DRY-RUN（仅预览，未写入）"
fi
echo
echo "各项目统计："
ALL_PIDS=$(echo "${!STAT_M[@]} ${!STAT_D[@]} ${!STAT_I[@]}" | tr ' ' '\n' | sort -u)
for pid in $ALL_PIDS; do
    [ -z "$pid" ] && continue
    printf "  %-22s milestone=%-2s decision=%-2s incident=%-2s\n" \
        "$pid" "${STAT_M[$pid]:-0}" "${STAT_D[$pid]:-0}" "${STAT_I[$pid]:-0}"
done
echo
echo "未匹配到任何项目（归入全局里程碑，未写入）：${#GLOBAL_LINES[@]} 条"
for g in "${GLOBAL_LINES[@]}"; do
    echo "  - $g"
done

if [ "$APPLY" != "1" ]; then
    echo
    echo "[DRY-RUN] 将执行的操作（前 30 条）："
    n=0
    for op in "${APPLIED_LOG[@]}"; do
        echo "  $op"
        n=$((n+1)); [ $n -ge 30 ] && { echo "  ...（剩余 $((${#APPLIED_LOG[@]}-30)) 条省略）"; break; }
    done
    echo
    echo "确认无误后跑：$0 --apply"
fi
