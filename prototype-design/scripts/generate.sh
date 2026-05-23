#!/bin/bash
# generate.sh - 主生成脚本 (Phase 2)
# 用法: bash generate.sh <style> <project> [--modules m1,m2] [--role <role>] [--req <REQ-id>] [--phase <一阶段|二阶段>] [--dry-run]
#
# Phase 2 升级：
#   - 批量生成所有过滤后 REQ（不再 head -1）
#   - 按 REQ 标题智能选业务模板（workspace / list / detail / form / dashboard / base）
#   - 填充真实占位数据
#   - 自动反向回填 + assertion 数量一致

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

if [ $# -lt 2 ]; then
    echo "用法: bash generate.sh <style> <project> [选项...]"
    echo ""
    echo "  <style>           wireframe / highfi / interactive"
    echo "  <project>         项目名"
    echo "  --modules <list>  仅生成指定模块（逗号分隔）（保留参数，暂未使用）"
    echo "  --role <role>     仅生成指定角色"
    echo "  --req <REQ-id>    仅生成指定 REQ"
    echo "  --phase <phase>   仅生成指定阶段（一阶段/二阶段）"
    echo "  --dry-run         只打印将生成的文件清单"
    exit 2
fi

STYLE="$1"
PROJECT="$2"
shift 2

FILTER_MODULES=""
FILTER_ROLE=""
FILTER_REQ=""
FILTER_PHASE=""
DRY_RUN="no"

while [ $# -gt 0 ]; do
    case "$1" in
        --modules) FILTER_MODULES="$2"; shift 2 ;;
        --role)    FILTER_ROLE="$2";    shift 2 ;;
        --req)     FILTER_REQ="$2";     shift 2 ;;
        --phase)   FILTER_PHASE="$2";   shift 2 ;;
        --dry-run) DRY_RUN="yes";       shift ;;
        *) echo "ERROR: 未知参数: $1"; exit 2 ;;
    esac
done

case "$STYLE" in
    wireframe|highfi|interactive) ;;
    *) echo "ERROR: <style> 必须是 wireframe / highfi / interactive"; exit 2 ;;
esac

PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
PROTOTYPE_DIR="$PROJECT_DOCS/prototype"
REQ_MAP="$PROJECT_DOCS/requirements/requirements-map.json"

[ -d "$PROTOTYPE_DIR" ] || { echo "ERROR: 原型目录不存在，请先运行 init.sh: $PROTOTYPE_DIR"; exit 1; }
[ -f "$REQ_MAP" ] || { echo "ERROR: requirements-map.json 不存在: $REQ_MAP"; exit 1; }

TPL_DIR="$SKILL_DIR/templates/$STYLE"
BASE_TEMPLATE="$TPL_DIR/base.html"
[ -f "$BASE_TEMPLATE" ] || { echo "ERROR: base 模板不存在: $BASE_TEMPLATE"; exit 1; }

# 业务模板目录（仅 wireframe 有，其他风格走 base）
BUSINESS_DIR="$TPL_DIR/business"

# 调用 python 主生成器
export GEN_STYLE="$STYLE"
export GEN_PROJECT="$PROJECT"
export GEN_DRY_RUN="$DRY_RUN"
export GEN_FILTER_ROLE="$FILTER_ROLE"
export GEN_FILTER_REQ="$FILTER_REQ"
export GEN_FILTER_PHASE="$FILTER_PHASE"
export GEN_REQ_MAP="$REQ_MAP"
export GEN_PROTOTYPE_DIR="$PROTOTYPE_DIR"
export GEN_PROJECT_DOCS="$PROJECT_DOCS"
export GEN_BASE_TEMPLATE="$BASE_TEMPLATE"
export GEN_BUSINESS_DIR="$BUSINESS_DIR"
export GEN_WORKSPACE_ROOT="$WORKSPACE_ROOT"
export GEN_SKILL_DIR="$SKILL_DIR"

python3 "$SKILL_DIR/scripts/lib/generate_batch.py"

# === 联动更新门户页（如存在 index-config.json 或包含默认模板就生成）===
if [ "$DRY_RUN" != "1" ] && [ -f "$SKILL_DIR/scripts/generate-index.sh" ]; then
  echo "[generate] linked: bash generate-index.sh $PROJECT"
  bash "$SKILL_DIR/scripts/generate-index.sh" "$PROJECT" || \
    echo "[generate] WARN: generate-index.sh 失败，请检查门户页生成是否缺少 meta" >&2
fi
