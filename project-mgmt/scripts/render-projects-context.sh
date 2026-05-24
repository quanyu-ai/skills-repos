#!/bin/bash
# render-projects-context.sh - 把所有项目档案合并成一份紧凑的快查 markdown
# 输出到 stdout。常用：
#   render-projects-context.sh > knowledge-repos/management/PROJECTS-CONTEXT.md

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

GEN_TIME=$(now_iso)

echo "# 项目快查（自动生成 @ $GEN_TIME）"
echo
echo "> 由 \`skills/project-mgmt/scripts/render-projects-context.sh\` 从 \`knowledge-repos/projects/*/profile.json\` 汇总生成。"
echo "> **不要手编辑**。状态变更后跑 \`bash skills/project-mgmt/scripts/refresh-context.sh\` 重新生成。"
echo
echo "## 项目总表"
echo
echo "| ID | 名称 | 阶段 | 优先级 | 健康 | 风险 | 客户 | 技术栈 | 主要部署 |"
echo "|----|------|------|--------|------|------|------|--------|----------|"

health_icon() {
    case "$1" in
        green) echo "🟢" ;;
        yellow) echo "🟡" ;;
        red) echo "🔴" ;;
        *) echo "—" ;;
    esac
}
risk_icon() {
    case "$1" in
        low) echo "🟢" ;;
        medium) echo "🟡" ;;
        high) echo "🟠" ;;
        critical) echo "🔴" ;;
        *) echo "—" ;;
    esac
}

# 总表
shopt -s nullglob
for pd in "$PROJECTS_ROOT"/*/; do
    pid=$(basename "$pd")
    [ "$pid" = "_archive" ] && continue
    pf="$pd/profile.json"
    [ -f "$pf" ] || continue
    name=$(jq -r '.display_name // "—"' "$pf")
    stage=$(jq -r '.stage // "—"' "$pf")
    prio=$(jq -r '.priority // "—"' "$pf")
    health=$(jq -r '.health // "green"' "$pf")
    risk=$(jq -r '.risk_level // "low"' "$pf")
    client=$(jq -r '.client // "—"' "$pf")
    stack=$(jq -r '.tech_stack // "—"' "$pf")
    # 取第一个非 null 的部署
    dep=$(jq -r '[.deployment // {} | to_entries[] | select(.value != null) | "\(.key):\(.value)"][0] // "—"' "$pf")
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" "$pid" "$name" "$stage" "$prio" "$(health_icon "$health")" "$(risk_icon "$risk")" "$client" "$stack" "$dep"
done

echo
echo "## 各项目最近里程碑（每项目最多 3 条）"
echo

for pd in "$PROJECTS_ROOT"/*/; do
    pid=$(basename "$pd")
    [ "$pid" = "_archive" ] && continue
    pf="$pd/profile.json"
    mf="$pd/milestones.md"
    [ -f "$pf" ] || continue
    name=$(jq -r '.display_name // .id' "$pf")
    echo "### $pid — $name"
    # ROI line
    roi_calc=$(jq -r '.roi.last_calculated_at // ""' "$pf")
    if [ -z "$roi_calc" ] || [ "$roi_calc" = "null" ]; then
        echo "- 📊 ROI: 未同步（跑 sync-roi.sh 初始化）"
    else
        tc=$(jq -r '.roi.tasks_completed // 0' "$pf")
        tt=$(jq -r '.roi.tasks_total // 0' "$pf")
        sm=$(jq -r '.roi.saved_minutes // 0' "$pf")
        sr=$(jq -r '.roi.save_ratio // 0' "$pf")
        sr_pct=$(awk -v r="$sr" 'BEGIN{printf "%d", r*100}')
        echo "- 📊 ROI: ${tc}/${tt} task, 节约 ${sm}min (${sr_pct}%)"
    fi
    if [ -f "$mf" ]; then
        # 取 table 行（以 | 开头，且第二列不是「---」也不是「日期」）
        grep "^|" "$mf" \
            | grep -v -E "^\| *日期 *\|" \
            | grep -v -E "^\| *-+ *\|" \
            | tail -3 \
            | awk -F'|' '{
                d=$2; gsub(/^ +| +$/,"",d);
                t=$3; gsub(/^ +| +$/,"",t);
                ti=$4; gsub(/^ +| +$/,"",ti);
                printf("- %s [%s] %s\n", d, t, ti);
              }'
    else
        echo "  _（无 milestones.md）_"
    fi
    echo
done

echo "## 各项目关键决策（每项目最多 3 条）"
echo

for pd in "$PROJECTS_ROOT"/*/; do
    pid=$(basename "$pd")
    [ "$pid" = "_archive" ] && continue
    pf="$pd/profile.json"
    df="$pd/decisions.md"
    [ -f "$pf" ] || continue
    name=$(jq -r '.display_name // .id' "$pf")
    n=0
    if [ -f "$df" ]; then
        n=$(grep -c "^|" "$df" || true)
        # 减表头 2 行
        n=$((n>2 ? n-2 : 0))
    fi
    [ "$n" = "0" ] && continue
    echo "### $pid — $name"
    grep "^|" "$df" \
        | grep -v -E "^\| *日期 *\|" \
        | grep -v -E "^\| *-+ *\|" \
        | tail -3 \
        | awk -F'|' '{
            d=$2; gsub(/^ +| +$/,"",d);
            t=$3; gsub(/^ +| +$/,"",t);
            r=$4; gsub(/^ +| +$/,"",r);
            printf("- %s %s (%s)\n", d, t, r);
          }'
    echo
done

shopt -u nullglob

echo "## 🌐 最近全局里程碑（tail 5）"
echo
GMF="$WORKSPACE_ROOT/knowledge-repos/management/GLOBAL-MILESTONES.md"
if [ -f "$GMF" ]; then
    # 表体行：以 | 开头，排除表头与分隔。按日期倒序取 5 条。
    rows=$(grep "^|" "$GMF" \
        | grep -v -E "^\| *日期 *\|" \
        | grep -v -E "^\| *-+ *\|" \
        | sort -r -t'|' -k2,2 \
        | head -5)
    if [ -n "$rows" ]; then
        echo "$rows" | awk -F'|' '{
            d=$2; gsub(/^ +| +$/,"",d);
            c=$3; gsub(/^ +| +$/,"",c);
            t=$4; gsub(/^ +| +$/,"",t);
            printf("- %s [%s] %s\n", d, c, t);
        }'
    else
        echo "_（暂无全局里程碑，添加：bash skills/project-mgmt/scripts/add-global-milestone.sh ...）_"
    fi
else
    echo "_（GLOBAL-MILESTONES.md 未初始化）_"
fi
echo

echo "---"
echo "_共 $(jq -r '.projects | length' "$REGISTRY") 个项目，下次刷新跑 \`bash skills/project-mgmt/scripts/refresh-context.sh\`_"
