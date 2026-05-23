#!/bin/bash
# doctor.sh - prototype-design skill 自检脚本
# 输出格式：最后一行 READY 或 NEED_SETUP: <原因>
# 退出码：0 = READY, 1 = NEED_SETUP

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SKILL_DIR/config"

fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 检查项 1：jq 必装
command -v jq >/dev/null 2>&1 || fail "jq not installed - run: sudo apt-get install -y jq"

# 检查项 2：projects.json 存在
[ -f "$CONFIG_DIR/projects.json" ] || fail "projects.json missing - copy from projects.json.template and fill in"

# 检查项 3：projects.json JSON 格式有效
jq empty "$CONFIG_DIR/projects.json" 2>/dev/null || fail "projects.json invalid JSON"

# 检查项 4：brand.json 存在
[ -f "$CONFIG_DIR/brand.json" ] || fail "brand.json missing - run setup.md step 3"

# 检查项 5：brand.json JSON 格式有效
jq empty "$CONFIG_DIR/brand.json" 2>/dev/null || fail "brand.json invalid JSON"

# 检查项 6：wireframe 模板目录存在
[ -d "$SKILL_DIR/templates/wireframe" ] || fail "wireframe templates missing - re-install skill"

# 检查项 7：wireframe base.html 存在
[ -f "$SKILL_DIR/templates/wireframe/base.html" ] || fail "wireframe base.html missing - re-install skill"

# 检查项 8：已注册项目目录可访问（WARN，不阻塞）
PROJECTS_JSON="$CONFIG_DIR/projects.json"
PROJECT_NAMES=$(jq -r '.projects | keys[]' "$PROJECTS_JSON" 2>/dev/null || true)
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
for proj in $PROJECT_NAMES; do
    if [ ! -d "$WORKSPACE_ROOT/docs-repos/$proj" ]; then
        echo "WARN: project dir missing: docs-repos/$proj"
    fi
done

# 检查项 9：需求条目可读（WARN，不阻塞）
for proj in $PROJECT_NAMES; do
    REQ_MAP="$WORKSPACE_ROOT/docs-repos/$proj/requirements/requirements-map.json"
    if [ ! -f "$REQ_MAP" ]; then
        echo "WARN: requirements-map.json missing for project: $proj"
    elif ! jq empty "$REQ_MAP" 2>/dev/null; then
        echo "WARN: requirements-map.json invalid JSON for project: $proj"
    fi
done

# 检查项 10：双向一致性扫描（阻塞）
# 对每个项目：如果 prototype/meta/requirements-map.json 存在，
# 则验证 mapping 中每条 file 都在对应 REQ 的 related_files.prototype 中
BACK_REF="$SKILL_DIR/scripts/lib/back_ref.py"
INCONSISTENT=0
for proj in $PROJECT_NAMES; do
    META_MAP="$WORKSPACE_ROOT/docs-repos/$proj/prototype/meta/requirements-map.json"
    REQ_DIR="$WORKSPACE_ROOT/docs-repos/$proj/requirements"
    [ -f "$META_MAP" ] || continue
    [ -d "$REQ_DIR" ] || continue
    [ -f "$BACK_REF" ] || continue

    # 提取 req_id + files
    MAPPING_LINES=$(jq -r '.mappings[]? | "\(.req_id)\t\(.files | join(","))"' "$META_MAP" 2>/dev/null || true)
    [ -z "$MAPPING_LINES" ] && continue

    while IFS=$'\t' read -r REQ_ID FILES_CSV; do
        [ -z "$REQ_ID" ] && continue
        REQ_FILE="$REQ_DIR/${REQ_ID}.md"
        if [ ! -f "$REQ_FILE" ]; then
            echo "WARN: [$proj] mapping 指向不存在的 REQ: $REQ_ID"
            continue
        fi
        IFS=',' read -ra PATHS_ARR <<< "$FILES_CSV"
        for p in "${PATHS_ARR[@]}"; do
            if ! python3 "$BACK_REF" check "$REQ_FILE" "$p" >/dev/null 2>&1; then
                echo "INCONSISTENT: [$proj] $REQ_ID 的 related_files.prototype 缺 $p"
                INCONSISTENT=$((INCONSISTENT + 1))
            fi
        done
    done <<< "$MAPPING_LINES"
done

if [ "$INCONSISTENT" -gt 0 ]; then
    fail "发现 $INCONSISTENT 个双向不一致项 - 请跑: bash scripts/sync-back-refs.sh <project>"
fi

# 检查项 11：sidebar 完整性 / styles.css 引用 / title 含项目名
SIDEBAR_ISSUES=0
STYLE_ISSUES=0
TITLE_ISSUES=0
for proj in $PROJECT_NAMES; do
    MODULES_DIR="$WORKSPACE_ROOT/docs-repos/$proj/prototype/modules"
    [ -d "$MODULES_DIR" ] || continue
    # 读 项目 display name（优先 brand.json projects[<proj>].display_name，其次 projects.json）
    PROJ_DISPLAY=$(jq -r --arg p "$proj" '.projects[$p].display_name // empty' "$PROJECTS_JSON" 2>/dev/null || true)
    [ -z "$PROJ_DISPLAY" ] && PROJ_DISPLAY="$proj"

    for role_dir in "$MODULES_DIR"/*/; do
        [ -d "$role_dir" ] || continue
        role_name=$(basename "$role_dir")
        # 该角色下所有 html 文件
        mapfile -t HTMLS < <(find "$role_dir" -maxdepth 1 -name '*.html' -printf '%f\n' | sort)
        N=${#HTMLS[@]}
        [ "$N" -eq 0 ] && continue

        for f in "${HTMLS[@]}"; do
            full="$role_dir$f"
            # 检查 styles.css 引用
            if ! grep -q '_shared/styles.css' "$full"; then
                echo "STYLE_MISSING: [$proj] modules/$role_name/$f 未引用 _shared/styles.css"
                STYLE_ISSUES=$((STYLE_ISSUES + 1))
            fi
            # 检查 <title> 含项目名或 display_name
            T=$(grep -oE '<title>[^<]*</title>' "$full" | head -1 || true)
            if [ -n "$T" ]; then
                if ! echo "$T" | grep -qE "$proj|$PROJ_DISPLAY"; then
                    echo "TITLE_NO_BRAND: [$proj] modules/$role_name/$f title='$T' 未含 '$proj' 或 '$PROJ_DISPLAY'"
                    TITLE_ISSUES=$((TITLE_ISSUES + 1))
                fi
            else
                echo "TITLE_MISSING: [$proj] modules/$role_name/$f 无 <title>"
                TITLE_ISSUES=$((TITLE_ISSUES + 1))
            fi
            # 检查 sidebar 是否列全（该角色下每个 html 都应出现在 sidebar href 中）
            # 提取该页 aside/sidebar 区域的 href
            SIDEBAR_HREFS=$(awk '/<aside/,/<\/aside>/' "$full" | grep -oE 'href="[^"#]+\.html"' | sed 's|href="||;s|"||' | sort -u)
            MISSING_LINKS=""
            for other in "${HTMLS[@]}"; do
                if ! echo "$SIDEBAR_HREFS" | grep -qx "$other"; then
                    MISSING_LINKS="$MISSING_LINKS $other"
                fi
            done
            if [ -n "$MISSING_LINKS" ]; then
                echo "SIDEBAR_INCOMPLETE: [$proj] modules/$role_name/$f 缺链接:$MISSING_LINKS"
                SIDEBAR_ISSUES=$((SIDEBAR_ISSUES + 1))
            fi
        done
    done
done

TOTAL_NEW=$((SIDEBAR_ISSUES + STYLE_ISSUES + TITLE_ISSUES))
if [ "$TOTAL_NEW" -gt 0 ]; then
    echo ""
    echo "增强检查汇总：sidebar=$SIDEBAR_ISSUES, styles.css=$STYLE_ISSUES, title=$TITLE_ISSUES"
    fail "发现 $TOTAL_NEW 个一致性问题（sidebar/styles.css/title）"
fi

echo "READY"
exit 0
