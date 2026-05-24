#!/bin/bash
# render-dashboard-html.sh - 生成 dashboard.html (单文件 / 零依赖 / 浏览器可离线打开)
# Usage: render-dashboard-html.sh [--output <path>]
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

OUT="$WORKSPACE_ROOT/knowledge-repos/management/dashboard.html"
while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--output <path>]"
            echo "Default output: $WORKSPACE_ROOT/knowledge-repos/management/dashboard.html"
            exit 0 ;;
        *) echo "✗ 未知参数：$1" >&2; exit 1 ;;
    esac
done

mkdir -p "$(dirname "$OUT")"
ensure_registry
GEN_TIME=$(now_iso)

TOTAL_PROJECTS=0; LIVE=0; HIGH_PRIO=0
H_GREEN=0; H_YELLOW=0; H_RED=0
SUM_EST=0; SUM_SAVED=0

projects=()
while IFS= read -r p; do
    [ -z "$p" ] && continue
    projects+=("$p")
done < <(jq -r '.projects | keys[]?' "$REGISTRY" | sort)

for pid in "${projects[@]}"; do
    pf="$PROJECTS_ROOT/$pid/profile.json"
    [ -f "$pf" ] || continue
    TOTAL_PROJECTS=$((TOTAL_PROJECTS+1))
    st=$(jq -r '.stage // "planning"' "$pf")
    [ "$st" = "live" ] && LIVE=$((LIVE+1))
    pr=$(jq -r '.priority // "medium"' "$pf")
    [ "$pr" = "high" ] && HIGH_PRIO=$((HIGH_PRIO+1))
    h=$(jq -r '.health // "green"' "$pf")
    case "$h" in
        green)  H_GREEN=$((H_GREEN+1)) ;;
        yellow) H_YELLOW=$((H_YELLOW+1)) ;;
        red)    H_RED=$((H_RED+1)) ;;
    esac
    em=$(jq -r '.roi.estimated_minutes // 0' "$pf")
    sm=$(jq -r '.roi.saved_minutes // 0' "$pf")
    SUM_EST=$((SUM_EST + em))
    SUM_SAVED=$((SUM_SAVED + sm))
done

if [ "$SUM_EST" -gt 0 ]; then
    TOT_RATIO=$(awk -v s="$SUM_SAVED" -v e="$SUM_EST" 'BEGIN{printf "%d", (s/e)*100}')
else
    TOT_RATIO=0
fi

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

stage_class() {
    case "$1" in
        planning) echo "stage-planning" ;;
        requirement) echo "stage-requirement" ;;
        design) echo "stage-design" ;;
        develop) echo "stage-develop" ;;
        test) echo "stage-test" ;;
        live) echo "stage-live" ;;
        deprecated) echo "stage-deprecated" ;;
        *) echo "stage-planning" ;;
    esac
}

health_icon_html() {
    case "$1" in
        green) echo "🟢" ;;
        yellow) echo "🟡" ;;
        red) echo "🔴" ;;
        *) echo "⚪" ;;
    esac
}
risk_icon_html() {
    case "$1" in
        low) echo "🟢" ;;
        medium) echo "🟡" ;;
        high) echo "🟠" ;;
        critical) echo "🔴" ;;
        *) echo "⚪" ;;
    esac
}
risk_label_cn() {
    case "$1" in
        low) echo "低" ;;
        medium) echo "中" ;;
        high) echo "高" ;;
        critical) echo "极高" ;;
        *) echo "—" ;;
    esac
}

role_chip_class() {
    case "$1" in
        PM|pm) echo "pm" ;;
        架构师|架构|Architect|architect) echo "arch" ;;
        产品|Product|product) echo "prod" ;;
        开发|Developer|developer|Dev|dev) echo "dev" ;;
        测试|Tester|tester|QA|qa) echo "test" ;;
        审查|Reviewer|reviewer|Review|review) echo "review" ;;
        *) echo "" ;;
    esac
}

milestone_cat_class() {
    case "$1" in
        skill) echo "cat-skill" ;;
        infra) echo "cat-infra" ;;
        strategy) echo "cat-strategy" ;;
        platform) echo "cat-platform" ;;
        process) echo "cat-process" ;;
        *) echo "cat-default" ;;
    esac
}

TMP=$(mktemp)

cat > "$TMP" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>📂 权舆项目仪表盘</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei","Segoe UI",sans-serif;background:#f5f7fb;color:#2d3748;line-height:1.5;padding-bottom:40px}
.header{background:linear-gradient(135deg,#7c3aed 0%,#f97316 100%);color:#fff;padding:24px 32px;box-shadow:0 4px 12px rgba(0,0,0,.08)}
.header h1{font-size:24px;font-weight:700;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.header .meta{margin-top:6px;font-size:13px;opacity:.92}
.container{max-width:1400px;margin:0 auto;padding:24px 20px}
.kpi-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:24px}
.kpi-card{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 2px 6px rgba(0,0,0,.06);border-left:4px solid #7c3aed}
.kpi-card .label{font-size:12px;color:#718096;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
.kpi-card .value{font-size:26px;font-weight:700;color:#2d3748}
.kpi-card .sub{font-size:12px;color:#a0aec0;margin-top:4px}
.kpi-card.k-live{border-left-color:#10b981}
.kpi-card.k-high{border-left-color:#f59e0b}
.kpi-card.k-health{border-left-color:#06b6d4}
.kpi-card.k-saved{border-left-color:#ec4899}
.kpi-card.k-ratio{border-left-color:#8b5cf6}
.toolbar{margin-bottom:16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.toolbar label{font-size:13px;color:#4a5568}
.toolbar select{padding:6px 10px;border:1px solid #cbd5e0;border-radius:6px;background:#fff;font-size:13px;cursor:pointer}
.section-title{font-size:16px;font-weight:600;margin:8px 0 14px;color:#2d3748;display:flex;align-items:center;gap:8px}
.section-title::before{content:"";display:inline-block;width:4px;height:18px;background:linear-gradient(135deg,#7c3aed,#f97316);border-radius:2px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(380px,1fr));gap:16px}
.card{background:#fff;border-radius:12px;padding:18px 20px;box-shadow:0 2px 8px rgba(0,0,0,.06);transition:transform .15s,box-shadow .15s;display:flex;flex-direction:column;gap:10px}
.card:hover{transform:translateY(-2px);box-shadow:0 6px 16px rgba(0,0,0,.1)}
.card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;flex-wrap:wrap}
.card-title{font-weight:700;font-size:16px;color:#1a202c;line-height:1.3}
.card-id{font-size:11px;color:#a0aec0;font-family:Menlo,Consolas,monospace;margin-top:2px}
.badge{display:inline-block;padding:3px 10px;font-size:11px;font-weight:600;border-radius:12px;letter-spacing:.3px}
.stage-planning{background:#edf2f7;color:#4a5568}
.stage-requirement{background:#e0f2fe;color:#0369a1}
.stage-design{background:#dbeafe;color:#1d4ed8}
.stage-develop{background:#ffedd5;color:#c2410c}
.stage-test{background:#fef3c7;color:#a16207}
.stage-live{background:#d1fae5;color:#047857}
.stage-deprecated{background:#f1f5f9;color:#94a3b8;text-decoration:line-through}
.indicators{display:flex;gap:14px;align-items:center;font-size:13px;color:#4a5568;flex-wrap:wrap}
.ind-item{display:flex;align-items:center;gap:4px}
.meta-row{font-size:12px;color:#718096;display:flex;gap:12px;flex-wrap:wrap}
.meta-row strong{color:#4a5568;font-weight:600}
.metrics-block{background:#f7fafc;border-radius:8px;padding:10px 12px;font-size:12px;display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.metrics-block .m-item{display:flex;flex-direction:column}
.metrics-block .m-label{color:#a0aec0;font-size:10px;text-transform:uppercase;letter-spacing:.3px}
.metrics-block .m-value{color:#2d3748;font-weight:600;font-size:13px;margin-top:2px}
.roi-block{background:linear-gradient(90deg,#fdf2f8,#fef3c7);border-radius:8px;padding:10px 12px;font-size:12px}
.roi-block .roi-row{display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap}
.roi-block .roi-label{color:#831843;font-weight:600}
.roi-block .roi-value{color:#9d174d;font-weight:700}
.roi-star{color:#d97706;margin-left:4px}
.next-ms{font-size:13px;color:#2b6cb0;background:#ebf8ff;padding:6px 10px;border-radius:6px;border-left:3px solid #3182ce;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:help}
.team-chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{display:inline-block;padding:2px 8px;font-size:11px;border-radius:10px;background:#ede9fe;color:#5b21b6}
.chip.pm{background:#fce7f3;color:#9d174d}
.chip.arch{background:#dbeafe;color:#1e40af}
.chip.prod{background:#fef3c7;color:#92400e}
.chip.dev{background:#d1fae5;color:#065f46}
.chip.test{background:#fed7aa;color:#9a3412}
.chip.review{background:#e0e7ff;color:#3730a3}
.timeline{border-left:2px solid #e2e8f0;padding-left:10px;margin-top:4px}
.timeline .tl-item{font-size:11px;color:#4a5568;margin-bottom:4px;position:relative}
.timeline .tl-item::before{content:"●";position:absolute;left:-15px;color:#7c3aed;font-size:10px}
.timeline .tl-date{color:#a0aec0;margin-right:6px}
.timeline .tl-type{color:#7c3aed;font-weight:600;margin-right:6px}
.links{display:flex;gap:10px;font-size:12px;flex-wrap:wrap}
.links a{color:#5b21b6;text-decoration:none;padding:4px 10px;background:#f3e8ff;border-radius:6px}
.links a:hover{background:#ede9fe}
.global-section{margin-top:30px;background:#fff;border-radius:12px;padding:20px;box-shadow:0 2px 8px rgba(0,0,0,.06)}
.global-section table{width:100%;border-collapse:collapse;font-size:13px}
.global-section th,.global-section td{padding:8px 12px;text-align:left;border-bottom:1px solid #edf2f7}
.global-section th{background:#f7fafc;color:#4a5568;font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.3px}
.cat-skill{background:#fef3c7;color:#92400e;padding:2px 8px;border-radius:10px;font-size:11px}
.cat-infra{background:#dbeafe;color:#1e40af;padding:2px 8px;border-radius:10px;font-size:11px}
.cat-strategy{background:#fce7f3;color:#9d174d;padding:2px 8px;border-radius:10px;font-size:11px}
.cat-platform{background:#d1fae5;color:#065f46;padding:2px 8px;border-radius:10px;font-size:11px}
.cat-process{background:#e0e7ff;color:#3730a3;padding:2px 8px;border-radius:10px;font-size:11px}
.cat-default{background:#edf2f7;color:#4a5568;padding:2px 8px;border-radius:10px;font-size:11px}
.footer{text-align:center;margin-top:30px;font-size:11px;color:#a0aec0}
.hidden{display:none}
@media(max-width:640px){.grid{grid-template-columns:1fr}.kpi-row{grid-template-columns:repeat(2,1fr)}.header{padding:16px 18px}.header h1{font-size:18px}}
</style>
</head>
<body>
HTMLHEAD

# ===== Header =====
cat >> "$TMP" <<HDR
<div class="header">
<h1>📂 权舆项目仪表盘 · 共 ${TOTAL_PROJECTS} 个项目</h1>
<div class="meta">生成时间：${GEN_TIME}</div>
</div>
<div class="container">

<div class="kpi-row">
<div class="kpi-card"><div class="label">📂 总项目</div><div class="value">${TOTAL_PROJECTS}</div><div class="sub">活跃中</div></div>
<div class="kpi-card k-live"><div class="label">🟢 Live 上线</div><div class="value">${LIVE}</div><div class="sub">生产环境运行</div></div>
<div class="kpi-card k-high"><div class="label">🔥 高优先级</div><div class="value">${HIGH_PRIO}</div><div class="sub">优先级 high</div></div>
<div class="kpi-card k-health"><div class="label">健康分布</div><div class="value">🟢 ${H_GREEN} · 🟡 ${H_YELLOW} · 🔴 ${H_RED}</div><div class="sub">green / yellow / red</div></div>
<div class="kpi-card k-saved"><div class="label">⏱️ 总节约</div><div class="value">${SUM_SAVED}<span style="font-size:14px;color:#a0aec0;font-weight:400"> min</span></div><div class="sub">预估 ${SUM_EST} min</div></div>
<div class="kpi-card k-ratio"><div class="label">✨ 整体节约率</div><div class="value">${TOT_RATIO}%</div><div class="sub">saved / estimated</div></div>
</div>

<div class="toolbar">
<label>按阶段筛选：</label>
<select id="stage-filter" onchange="filterByStage()">
<option value="all">全部</option>
<option value="planning">planning</option>
<option value="requirement">requirement</option>
<option value="design">design</option>
<option value="develop">develop</option>
<option value="test">test</option>
<option value="live">live</option>
<option value="deprecated">deprecated</option>
</select>
</div>

<div class="section-title">📊 项目卡片</div>
<div class="grid" id="project-grid">
HDR


# ===== 项目卡片循环 =====
for pid in "${projects[@]}"; do
    pf="$PROJECTS_ROOT/$pid/profile.json"
    [ -f "$pf" ] || continue

    name=$(jq -r '.display_name // .id' "$pf")
    stage=$(jq -r '.stage // "planning"' "$pf")
    client=$(jq -r '.client // "—"' "$pf")
    stack=$(jq -r '.tech_stack // "—"' "$pf")
    prio=$(jq -r '.priority // "medium"' "$pf")
    health=$(jq -r '.health // "green"' "$pf")
    risk=$(jq -r '.risk_level // "low"' "$pf")
    next_ms=$(jq -r '.next_milestone // ""' "$pf")

    req_active=$(jq -r '.metrics.requirements_active // 0' "$pf")
    req_total=$(jq -r '.metrics.requirements_total // 0' "$pf")
    proto=$(jq -r '.metrics.prototypes_total // 0' "$pf")
    adr=$(jq -r '.metrics.adr_count // 0' "$pf")
    dep30=$(jq -r '.metrics.deploy_count_30d // 0' "$pf")
    com30=$(jq -r '.metrics.commits_30d // 0' "$pf")

    roi_done=$(jq -r '.roi.tasks_completed // 0' "$pf")
    roi_tot=$(jq -r '.roi.tasks_total // 0' "$pf")
    roi_saved=$(jq -r '.roi.saved_minutes // 0' "$pf")
    roi_ratio=$(jq -r '.roi.save_ratio // 0' "$pf")
    roi_ratio_pct=$(awk -v r="$roi_ratio" 'BEGIN{printf "%d", r*100}')
    roi_star=""
    if [ "$roi_ratio_pct" -ge 50 ]; then roi_star='<span class="roi-star">✨</span>'; fi

    docs_repo=$(jq -r '.github_repos.docs // ""' "$pf")
    code_repo=$(jq -r '.github_repos.code // ""' "$pf")

    name_esc=$(html_escape "$name")
    client_esc=$(html_escape "$client")
    stack_esc=$(html_escape "$stack")
    next_ms_esc=$(html_escape "$next_ms")
    stage_cls=$(stage_class "$stage")
    h_icon=$(health_icon_html "$health")
    r_icon=$(risk_icon_html "$risk")
    r_label=$(risk_label_cn "$risk")

    {
    printf '<div class="card" data-stage="%s">\n' "$stage"
    printf '<div class="card-head"><div><div class="card-title">%s</div><div class="card-id">%s</div></div><span class="badge %s">%s</span></div>\n' \
        "$name_esc" "$pid" "$stage_cls" "$stage"
    printf '<div class="indicators"><span class="ind-item">健康 %s</span><span class="ind-item">风险 %s %s</span><span class="ind-item">🔥 %s</span></div>\n' \
        "$h_icon" "$r_icon" "$r_label" "$prio"
    printf '<div class="meta-row"><span><strong>客户：</strong>%s</span><span><strong>技术栈：</strong>%s</span></div>\n' \
        "$client_esc" "$stack_esc"

    # metrics block
    printf '<div class="metrics-block">'
    printf '<div class="m-item"><span class="m-label">需求(活/总)</span><span class="m-value">%s / %s</span></div>' "$req_active" "$req_total"
    printf '<div class="m-item"><span class="m-label">原型数</span><span class="m-value">%s</span></div>' "$proto"
    printf '<div class="m-item"><span class="m-label">ADR</span><span class="m-value">%s</span></div>' "$adr"
    printf '<div class="m-item"><span class="m-label">部署 30d</span><span class="m-value">%s</span></div>' "$dep30"
    printf '<div class="m-item"><span class="m-label">Commit 30d</span><span class="m-value">%s</span></div>' "$com30"
    printf '<div class="m-item"><span class="m-label">—</span><span class="m-value">—</span></div>'
    printf '</div>\n'

    # ROI block
    printf '<div class="roi-block"><div class="roi-row"><span class="roi-label">📊 ROI</span><span class="roi-value">%s / %s task · 节约 %s min · %s%%%s</span></div></div>\n' \
        "$roi_done" "$roi_tot" "$roi_saved" "$roi_ratio_pct" "$roi_star"

    # next milestone
    if [ -n "$next_ms" ] && [ "$next_ms" != "null" ]; then
        printf '<div class="next-ms" title="%s">📌 下一里程碑：%s</div>\n' "$next_ms_esc" "$next_ms_esc"
    fi

    # team roles
    team_count=$(jq -r '.team_roles | length // 0' "$pf")
    if [ "$team_count" -gt 0 ]; then
        printf '<div class="team-chips">'
        printf '<span style="font-size:11px;color:#718096;align-self:center">👥 团队：</span>'
        jq -r '.team_roles[]? | "\(.name)|\(.role)"' "$pf" | while IFS='|' read -r tn tr; do
            tn_esc=$(html_escape "$tn")
            tr_esc=$(html_escape "$tr")
            tcls=$(role_chip_class "$tr")
            printf '<span class="chip %s">%s · %s</span>' "$tcls" "$tn_esc" "$tr_esc"
        done
        printf '</div>\n'
    fi

    # mini timeline (recent 3)
    mf="$PROJECTS_ROOT/$pid/milestones.md"
    if [ -f "$mf" ]; then
        ms_rows=$(grep "^|" "$mf" | grep -v -E "^\| *日期 *\|" | grep -v -E "^\| *-+ *\|" | tail -3)
        if [ -n "$ms_rows" ]; then
            printf '<div class="timeline">'
            while IFS= read -r row; do
                d=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$2);print $2}')
                t=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$3);print $3}')
                ti=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$4);print $4}')
                d_esc=$(html_escape "$d")
                t_esc=$(html_escape "$t")
                ti_esc=$(html_escape "$ti")
                printf '<div class="tl-item"><span class="tl-date">%s</span><span class="tl-type">%s</span>%s</div>' "$d_esc" "$t_esc" "$ti_esc"
            done <<< "$ms_rows"
            printf '</div>\n'
        fi
    fi

    # links
    if [ -n "$docs_repo" ] && [ "$docs_repo" != "null" ]; then
        docs_esc=$(html_escape "$docs_repo")
        printf '<div class="links"><a href="../../%s" target="_blank">📚 docs</a>' "$docs_esc"
        if [ -n "$code_repo" ] && [ "$code_repo" != "null" ]; then
            code_esc=$(html_escape "$code_repo")
            printf '<a href="../../%s" target="_blank">💻 code</a>' "$code_esc"
        fi
        printf '</div>\n'
    elif [ -n "$code_repo" ] && [ "$code_repo" != "null" ]; then
        code_esc=$(html_escape "$code_repo")
        printf '<div class="links"><a href="../../%s" target="_blank">💻 code</a></div>\n' "$code_esc"
    fi

    printf '</div>\n'
    } >> "$TMP"
done


# close project grid
echo '</div>' >> "$TMP"

# ===== 全局里程碑 tail 10 =====
cat >> "$TMP" <<GMHEAD
<div class="global-section">
<div class="section-title">🌐 最近全局里程碑（tail 10）</div>
<table>
<thead><tr><th>日期</th><th>分类</th><th>标题</th></tr></thead>
<tbody>
GMHEAD

GMF="$WORKSPACE_ROOT/knowledge-repos/management/GLOBAL-MILESTONES.md"
if [ -f "$GMF" ]; then
    rows=$(grep "^|" "$GMF" | grep -v -E "^\| *日期 *\|" | grep -v -E "^\| *-+ *\|" | sort -r -t'|' -k2,2 | head -10)
    if [ -n "$rows" ]; then
        while IFS= read -r row; do
            d=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$2);print $2}')
            c=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$3);print $3}')
            t=$(echo "$row" | awk -F'|' '{gsub(/^ +| +$/,"",$4);print $4}')
            d_esc=$(html_escape "$d")
            t_esc=$(html_escape "$t")
            ccls=$(milestone_cat_class "$c")
            printf '<tr><td>%s</td><td><span class="%s">%s</span></td><td>%s</td></tr>\n' "$d_esc" "$ccls" "$c" "$t_esc" >> "$TMP"
        done <<< "$rows"
    else
        echo '<tr><td colspan="3" style="color:#a0aec0;text-align:center">暂无全局里程碑</td></tr>' >> "$TMP"
    fi
else
    echo '<tr><td colspan="3" style="color:#a0aec0;text-align:center">GLOBAL-MILESTONES.md 未初始化</td></tr>' >> "$TMP"
fi

cat >> "$TMP" <<'GMTAIL'
</tbody>
</table>
</div>

<div class="footer">
🌸 由 <code>skills/project-mgmt/scripts/render-dashboard-html.sh</code> 自动生成 · 权舆科技
</div>

</div>
<script>
function filterByStage(){
    var v=document.getElementById('stage-filter').value;
    var cards=document.querySelectorAll('#project-grid .card');
    cards.forEach(function(c){
        if(v==='all'||c.getAttribute('data-stage')===v){c.classList.remove('hidden');}
        else{c.classList.add('hidden');}
    });
}
</script>
</body>
</html>
GMTAIL

# ===== finalize =====
mv "$TMP" "$OUT"
BYTES=$(wc -c < "$OUT")
LINES=$(wc -l < "$OUT")
echo "✓ 已生成 $OUT"
echo "  大小：${BYTES} bytes / ${LINES} 行"

# 检测闭合
if ! grep -q '</html>' "$OUT"; then
    echo "✗ HTML 未正确闭合（缺 </html>）" >&2
    exit 1
fi

# tidy 校验（可选）
if command -v tidy >/dev/null 2>&1; then
    tidy -e -q -utf8 "$OUT" >/dev/null 2>&1 && echo "✓ tidy 校验通过" || echo "ℹ tidy 报警（不阻塞）"
fi
