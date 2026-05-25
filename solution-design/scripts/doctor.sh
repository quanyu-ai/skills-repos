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

# ─── 1. 模板目录存在 ────────────────────────────────
[ -d "$TEMPLATE_DIR" ] || fail "templates/solution-structure/ missing"

# ─── 2. 关键模板文件齐全 ────────────────────────────
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

# ─── 3. JSON 模板合法性 ─────────────────────────────
for jf in "$TEMPLATE_DIR/modules/_example/reqs.json" \
          "$TEMPLATE_DIR/modules/_example/apis.json" \
          "$TEMPLATE_DIR/meta/version.json"; do
    if command -v jq >/dev/null 2>&1; then
        jq empty "$jf" 2>/dev/null || fail "invalid JSON: $jf"
    fi
done

# ─── 4. 所有 scripts/ 脚本存在 + 可执行 + 语法 ─────
SCRIPTS=(
    "init-solution.sh"
    "generate-modules.sh"
    "sync-solution-map.sh"
    "diff-against-reqs.sh"
    "validate-solution.sh"
)
for s in "${SCRIPTS[@]}"; do
    P="$SKILL_DIR/scripts/$s"
    [ -f "$P" ] || fail "scripts/$s missing"
    [ -x "$P" ] || fail "scripts/$s not executable - run: chmod +x scripts/$s"
    bash -n "$P" 2>/dev/null || fail "scripts/$s has bash syntax error"
done

# ─── 5. adr-template.md 兼容旧引用 ──────────────────
[ -f "$SKILL_DIR/templates/adr-template.md" ] || fail "templates/adr-template.md missing"

# ─── 6. bash 基础工具 ───────────────────────────────
command -v sed >/dev/null 2>&1 || fail "sed not installed"
command -v cp  >/dev/null 2>&1 || fail "cp not installed"
command -v jq  >/dev/null 2>&1 || fail "jq not installed (Phase 2 scripts require jq)"

# ─── 7. 智院项目可选健康检查 ────────────────────────
if [ -d "/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college" ]; then
    SOLUTION_DIR="/var/lib/openclaw/.openclaw/workspace/docs-repos/smart-college/solution"
    if [ -d "$SOLUTION_DIR/modules" ]; then
        for MODULE in "$SOLUTION_DIR/modules"/*; do
            if [ -d "$MODULE" ] && [ "$(basename "$MODULE")" != "_example" ]; then
                APIS_JSON="$MODULE/apis.json"
                if [ ! -f "$APIS_JSON" ]; then
                    echo "⚠️  [WARNING] 模块 $(basename "$MODULE") 缺少 apis.json 文件"
                fi
            fi
        done
    fi
fi

echo "READY"
exit 0
