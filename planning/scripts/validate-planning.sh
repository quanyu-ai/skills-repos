#!/bin/bash
# validate-planning.sh - 校验项目 planning 三件套完整性
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
        fail "$proj 缺少 planning/ 目录，请跑：bash scripts/init-planning.sh $proj"
        return
    fi

    # 检查三件套
    for f in PRD.md ROADMAP.md; do
        if [ -f "$planning_dir/$f" ]; then
            pass "$proj/planning/$f 存在"
        else
            fail "$proj/planning/$f 缺失（必填）"
            continue
        fi
    done

    if [ -f "$planning_dir/OKR.md" ]; then
        pass "$proj/planning/OKR.md 存在（可选）"
    else
        warning "$proj/planning/OKR.md 缺失（可选）"
    fi

    # PRD 必填字段检查
    if [ -f "$planning_dir/PRD.md" ]; then
        local prd="$planning_dir/PRD.md"
        local sections=(
            "一句话定位"
            "目标用户画像"
            "核心价值主张"
            "MVP 范围"
            "成功指标"
            "商业模式"
            "假设与风险"
        )
        for sec in "${sections[@]}"; do
            if grep -q "$sec" "$prd"; then
                pass "PRD 含「$sec」段"
            else
                fail "PRD 缺失「$sec」段"
            fi
        done

        # draft 状态检查
        if grep -q "^status: draft" "$prd"; then
            pass "PRD status=draft（未审定，需龙哥审定后转 approved）"
        elif grep -q "^status: approved" "$prd"; then
            pass "PRD status=approved（已审定）"
        elif grep -q "^status: reviewing" "$prd"; then
            warning "PRD status=reviewing（审定中）"
        else
            warning "PRD frontmatter 缺 status 字段"
        fi

        # 商业模式 ≥2 候选项
        local candidates
        candidates=$(grep -c "^### 候选模式" "$prd" || true)
        if [ "$candidates" -ge 2 ]; then
            pass "PRD 商业模式段含 $candidates 个候选项（满足 ≥2）"
        else
            warning "PRD 商业模式段候选项 < 2（红线建议 ≥2，自用工具可标'自用，不卖'）"
        fi
    fi

    # ROADMAP 必填检查
    if [ -f "$planning_dir/ROADMAP.md" ]; then
        local rm="$planning_dir/ROADMAP.md"
        for v in V1 V2 V3; do
            if grep -q "**$v" "$rm" || grep -qE "^### $v" "$rm" || grep -qE "\\| \*\*$v" "$rm"; then
                pass "ROADMAP 包含 $v 段"
            else
                warning "ROADMAP 未明确包含 $v（建议覆盖 V1/V2/V3）"
            fi
        done
    fi
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
