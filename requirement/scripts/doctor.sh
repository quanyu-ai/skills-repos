#!/bin/bash
# doctor.sh - requirement skill 自检脚本
# 输出最后一行 READY 或 NEED_SETUP: <原因>

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DOCS_ROOT="$WORKSPACE_ROOT/docs-repos"

fail() {
    echo "NEED_SETUP: $1"
    exit 1
}

# 检查 jq
command -v jq >/dev/null 2>&1 || fail "jq not installed - run: sudo yum install -y jq"

# 检查 pandoc
command -v pandoc >/dev/null 2>&1 || fail "pandoc not installed - run: sudo yum install -y pandoc"

# 检查 templates 存在
[ -f "$SKILL_DIR/templates/req-template.md" ] || fail "templates/req-template.md missing"
[ -f "$SKILL_DIR/templates/requirements-map.template.json" ] || fail "templates/requirements-map.template.json missing"

# 检查 docs-repos 根目录
[ -d "$DOCS_ROOT" ] || echo "WARN: docs-repos not found at $DOCS_ROOT - 项目目录需要手动创建"

# 提醒：sync 时若 .md frontmatter 缺字段会跳过
echo "READY"
exit 0
