#!/bin/bash
# dashboard.sh - 控制台全项目仪表盘
# Usage: dashboard.sh [--markdown]
set -e
. "$(dirname "$0")/_lib.sh"

MODE="console"
[ "$1" = "--markdown" ] && MODE="md"

ensure_registry

projects=()
while IFS= read -r p; do
    [ -z "$p" ] && continue
    projects+=("$p")
done < <(jq -r '.projects | keys[]?' "$REGISTRY" | sort)

if [ ${#projects[@]} -eq 0 ]; then
    echo "（暂无项目，先跑 new-project.sh 创建）"
    exit 0
fi

# tally
declare -A TALLY
for s in $LEGAL_STAGES; do TALLY[$s]=0; done

if [ "$MODE" = "md" ]; then
    echo "# 项目仪表盘"
    echo
    echo "> 生成时间：$(now_iso)"
    echo
    echo "| ID | 名称 | 阶段 | 需求(活/总) | 原型 | ADR | 部署30d | 节约 | 下一里程碑 |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    SUM_EST=0; SUM_SAVED=0
    for pid in "${projects[@]}"; do
        p="$PROJECTS_ROOT/$pid/profile.json"
        [ -f "$p" ] || continue
        st=$(jq -r '.stage' "$p"); TALLY[$st]=$((${TALLY[$st]:-0}+1))
        name=$(jq -r '.display_name' "$p")
        ra=$(jq -r '.metrics.requirements_active // 0' "$p")
        rt=$(jq -r '.metrics.requirements_total // 0' "$p")
        pt=$(jq -r '.metrics.prototypes_total // 0' "$p")
        adr=$(jq -r '.metrics.adr_count // 0' "$p")
        dp=$(jq -r '.metrics.deploy_count_30d // 0' "$p")
        nm=$(jq -r '.next_milestone // ""' "$p")
        sm=$(jq -r '.roi.saved_minutes // 0' "$p")
        sr=$(jq -r '.roi.save_ratio // 0' "$p")
        em=$(jq -r '.roi.estimated_minutes // 0' "$p")
        SUM_EST=$((SUM_EST + em)); SUM_SAVED=$((SUM_SAVED + sm))
        sr_pct=$(awk -v r="$sr" 'BEGIN{printf "%d", r*100}')
        roi_cell="${sm}min/${sr_pct}%"
        echo "| $pid | $name | $st | $ra/$rt | $pt | $adr | $dp | $roi_cell | ${nm:-—} |"
    done
    echo
    if [ "$SUM_EST" -gt 0 ]; then
        TOT_RATIO=$(awk -v s="$SUM_SAVED" -v e="$SUM_EST" 'BEGIN{printf "%d", (s/e)*100}')
    else
        TOT_RATIO=0
    fi
    echo "**全项目 ROI 汇总**：预估 ${SUM_EST}min / 节约 ${SUM_SAVED}min / 节约率 ${TOT_RATIO}%"
    echo
    echo
    echo "## 阶段汇总"
    for s in $LEGAL_STAGES; do
        printf -- '- %-12s %d\n' "$s" "${TALLY[$s]}"
    done
    exit 0
fi

# console mode
BOLD=$'\033[1m'; DIM=$'\033[2m'; CYA=$'\033[36m'

echo "${BOLD}📂 项目仪表盘${RESET}  ${DIM}$(now_iso)${RESET}"
echo
printf "${BOLD}%-22s %-26s %-13s %-12s %-7s %-5s %-8s %-12s %s${RESET}\n" \
    "ID" "名称" "阶段" "需求(活/总)" "原型" "ADR" "部署30d" "节约" "下一里程碑"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"
SUM_EST=0; SUM_SAVED=0
for pid in "${projects[@]}"; do
    p="$PROJECTS_ROOT/$pid/profile.json"
    [ -f "$p" ] || continue
    st=$(jq -r '.stage' "$p"); TALLY[$st]=$((${TALLY[$st]:-0}+1))
    name=$(jq -r '.display_name' "$p")
    ra=$(jq -r '.metrics.requirements_active // 0' "$p")
    rt=$(jq -r '.metrics.requirements_total // 0' "$p")
    pt=$(jq -r '.metrics.prototypes_total // 0' "$p")
    adr=$(jq -r '.metrics.adr_count // 0' "$p")
    dp=$(jq -r '.metrics.deploy_count_30d // 0' "$p")
    nm=$(jq -r '.next_milestone // ""' "$p")
    sm=$(jq -r '.roi.saved_minutes // 0' "$p")
    sr=$(jq -r '.roi.save_ratio // 0' "$p")
    em=$(jq -r '.roi.estimated_minutes // 0' "$p")
    SUM_EST=$((SUM_EST + em)); SUM_SAVED=$((SUM_SAVED + sm))
    sr_pct=$(awk -v r="$sr" 'BEGIN{printf "%d", r*100}')
    roi_cell="${sm}min/${sr_pct}%"
    color=$(stage_color "$st")
    # truncate name to ~24 chars (chinese may overflow, but readable)
    printf "%-22s %-26s ${color}%-13s${RESET} %-12s %-7s %-5s %-8s %-12s %s\n" \
        "$pid" "$name" "$st" "$ra/$rt" "$pt" "$adr" "$dp" "$roi_cell" "${nm:-—}"
done

echo
echo "${BOLD}阶段汇总${RESET}"
for s in $LEGAL_STAGES; do
    color=$(stage_color "$s")
    printf "  ${color}●${RESET} %-12s ${BOLD}%d${RESET}\n" "$s" "${TALLY[$s]}"
done

echo
if [ "$SUM_EST" -gt 0 ]; then
    TOT_RATIO=$(awk -v s="$SUM_SAVED" -v e="$SUM_EST" 'BEGIN{printf "%d", (s/e)*100}')
else
    TOT_RATIO=0
fi
echo "${BOLD}全项目 ROI 汇总${RESET}  预估 ${SUM_EST}min / 节约 ${SUM_SAVED}min / 节约率 ${TOT_RATIO}%"

echo
echo "${DIM}用法：dashboard.sh --markdown 输出 markdown 表格${RESET}"
