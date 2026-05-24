#!/bin/bash
# doctor.sh - solution-design skill 自检
# 输出格式: 最后一行 READY 或 NEED_SETUP: <原因>
# 退出码: 0 = READY, 1 = NEED_SETUP

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_DIR="$SKILL_DIR/templates/solution-structure"

fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 检查项 1: 模板目录存在
[ -d "$TEMPLATE_DIR" ] || fail "templates/solution-structure/ missing"

# 检查项 2: 关键模板文件齐全
REQUIRED=(
    "architecture/overview.md"
    "architecture/deployment.md"
    "architecture/data-flow.md"
    "database/er-diagram.md"
    "database/schema.md"
    "api/api-design.md"
    "modules/_example/design.md"
    "modules/_example/reqs.json"
    "modules/_example/apis.json"
    "adr/README.md"
    "adr/_template.md"
    "meta/version.json"
)
for f in "${REQUIRED[@]}"; do
    [ -f "$TEMPLATE_DIR/$f" ] || fail "template missing: $f"
done

# 检查项 3: init-solution.sh 存在且可执行
INIT_SH="$SKILL_DIR/scripts/init-solution.sh"
[ -f "$INIT_SH" ] || fail "scripts/init-solution.sh missing"
[ -x "$INIT_SH" ] || fail "scripts/init-solution.sh not executable - run: chmod +x scripts/init-solution.sh"

# 检查项 4: adr-template.md（兼容旧引用）
[ -f "$SKILL_DIR/templates/adr-template.md" ] || fail "templates/adr-template.md missing"

# 检查项 5: bash 基础工具
command -v sed >/dev/null 2>&1 || fail "sed not installed"
command -v cp  >/dev/null 2>&1 || fail "cp not installed"

# 检查项 6: 检查智院项目的方案设计（如果存在）
if [ -d "/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college" ]; then
    SOLUTION_DIR="/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college/solution"
    if [ -d "$SOLUTION_DIR" ]; then
        # 检查模块 apis.json
        MODULES_DIR="$SOLUTION_DIR/modules"
        if [ -d "$MODULES_DIR" ]; then
            for MODULE in "$MODULES_DIR"/*; do
                if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
                    APIS_JSON="$MODULE/apis.json"
                    if [ ! -f "$APIS_JSON" ]; then
                        echo "⚠️  [WARNING] 模块 $(basename "$MODULE") 缺少 apis.json 文件"
                    fi
                fi
            done
        fi
    fi
fi

echo "READY"
exit 0
