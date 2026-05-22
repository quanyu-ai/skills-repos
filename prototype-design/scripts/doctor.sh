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

echo "READY"
exit 0
