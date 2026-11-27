#!/bin/bash
# validate-planning.sh - 检查已采用的规划文件可读性；不判断产品完成
# Usage:
#   validate-planning.sh <project-id>     # 校验单个项目
#   validate-planning.sh --doctor         # skill 自检（脚本/模板齐全）
#   validate-planning.sh --all            # 校验所有项目

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
DOCS_ROOT="$WORKSPACE_ROOT/docs-repos"

# 颜色
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

err=0
warn=0
ok=0

pass() { echo "${GREEN}✓${RESET} $1"; ok=$((ok+1)); }
warning() { echo "${YELLOW}⚠${RESET} $1"; warn=$((warn+1)); }
fail() { echo "${RED}✗${RESET} $1"; err=$((err+1)); }

usage() {
    cat >&2 <<EOF
Usage:
  $0 <project-id>     # 校验单个项目
  $0 --doctor         # skill 自检
  $0 --all            # 校验所有有 docs-repos 的项目
EOF
    exit 1
}

doctor_check() {
    echo "📋 planning skill doctor check..."
    for f in PRD.template.md ROADMAP.template.md OKR.template.md; do
        if [ -f "$SKILL_DIR/templates/$f" ]; then
            pass "templates/$f 存在"
        else
            fail "templates/$f 缺失"
        fi
    done
    for f in init-planning.sh validate-planning.sh sync-to-profile.sh; do
        if [ -x "$SKILL_DIR/scripts/$f" ]; then
            pass "scripts/$f 可执行"
        else
            fail "scripts/$f 缺失或不可执行"
        fi
    done
    for bin in jq; do
        if command -v "$bin" &>/dev/null; then
            pass "依赖 $bin 已安装"
        else
            fail "依赖 $bin 未安装"
        fi
    done
    if [ $err -eq 0 ]; then
        echo "READY"
        exit 0
    else
        echo "NEED_SETUP: $err 项失败，请参考 README.md / setup.md"
        exit 1
    fi
}

validate_project() {
    local proj="$1"
    local planning_dir="$DOCS_ROOT/$proj/planning"

    echo ""
    echo "📂 校验项目: $proj"

    if [ ! -d "$DOCS_ROOT/$proj" ]; then
        fail "docs-repos/$proj/ 不存在"
        return
    fi

    if [ ! -d "$planning_dir" ]; then
        warning "$proj 未采用 planning/ 目录；沿项目现有规划，不要求补模板"
        return
    fi
    local found=0
    for f in PRD.md ROADMAP.md OKR.md; do
        [ -e "$planning_dir/$f" ] || continue
        found=$((found+1))
        if [ -r "$planning_dir/$f" ] && [ -s "$planning_dir/$f" ]; then
            pass "$proj/planning/$f 可读且非空；内容是否解决用户问题需实际判断"
        else
            fail "$proj/planning/$f 存在但不可读或为空"
        fi
    done
    [ "$found" -gt 0 ] || warning "未使用这些模板文件；不据此否定项目现有规划"
}

validate_all() {
    for dir in "$DOCS_ROOT"/*/; do
        [ -d "$dir" ] || continue
        local proj=$(basename "$dir")
        case "$proj" in
            _*|.*) continue ;;
        esac
        validate_project "$proj"
    done
}

# === main ===
if [ -z "$1" ]; then
    usage
fi

case "$1" in
    --doctor)
        doctor_check
        ;;
    --all)
        validate_all
        ;;
    -*)
        usage
        ;;
    *)
        validate_project "$1"
        ;;
esac

echo ""
echo "==========================="
echo "✓ pass: $ok    ⚠ warn: $warn    ✗ error: $err"
echo "==========================="

if [ $err -gt 0 ]; then
    exit 1
fi
exit 0
