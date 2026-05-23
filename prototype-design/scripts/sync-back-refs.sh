#!/bin/bash
# sync-back-refs.sh - 把 prototype/meta/requirements-map.json 的所有 mapping
# 反向回填到对应 REQ 文件的 frontmatter.related_files.prototype
#
# 用法:
#   bash sync-back-refs.sh <project> [--dry-run]
#
# 退出码:
#   0 = 全部回填成功（或 dry-run 完成）
#   1 = 出错或 post-check 不一致

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
BACK_REF="$SKILL_DIR/scripts/lib/back_ref.py"

if [ $# -lt 1 ]; then
    echo "用法: bash sync-back-refs.sh <project> [--dry-run]"
    exit 2
fi

PROJECT="$1"
DRY_RUN="no"
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN="yes"; shift ;;
        *) echo "ERROR: 未知参数: $1"; exit 2 ;;
    esac
done

PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
META_MAP="$PROJECT_DOCS/prototype/meta/requirements-map.json"
REQ_DIR="$PROJECT_DOCS/requirements"

[ -f "$META_MAP" ] || { echo "ERROR: meta/requirements-map.json 不存在: $META_MAP"; exit 1; }
[ -d "$REQ_DIR" ] || { echo "ERROR: requirements 目录不存在: $REQ_DIR"; exit 1; }
[ -f "$BACK_REF" ] || { echo "ERROR: back_ref.py 不存在: $BACK_REF"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq 未安装"; exit 1; }

echo "[sync-back-refs] project=$PROJECT dry-run=$DRY_RUN"
echo "[sync-back-refs] 读取 mapping: $META_MAP"

# 用 jq 提取每条 mapping 的 req_id + files（files 是数组，可能有多个）
# 输出格式：<req_id>\t<file1>,<file2>,...
MAPPING_LINES=$(jq -r '.mappings[] | "\(.req_id)\t\(.files | join(","))"' "$META_MAP")

if [ -z "$MAPPING_LINES" ]; then
    echo "[sync-back-refs] meta map 内无任何 mapping，无需回填"
    exit 0
fi

TOTAL_MAPPINGS=0
TOTAL_REQS_TOUCHED=0
TOTAL_PATHS_ADDED=0
TOTAL_PATHS_SKIPPED=0
ERRORS=0

while IFS=$'\t' read -r REQ_ID FILES_CSV; do
    [ -z "$REQ_ID" ] && continue
    TOTAL_MAPPINGS=$((TOTAL_MAPPINGS + 1))

    REQ_FILE="$REQ_DIR/${REQ_ID}.md"
    if [ ! -f "$REQ_FILE" ]; then
        echo "  ✗ REQ 文件不存在: $REQ_FILE (mapping req_id=$REQ_ID 跳过)"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # 把 csv 拆成数组
    IFS=',' read -ra PATHS_ARR <<< "$FILES_CSV"

    if [ "$DRY_RUN" = "yes" ]; then
        echo "  [dry-run] $REQ_ID -> ${PATHS_ARR[*]}"
        # dry-run 也提示哪些已存在，并累计统计
        for p in "${PATHS_ARR[@]}"; do
            if python3 "$BACK_REF" check "$REQ_FILE" "$p" >/dev/null 2>&1; then
                echo "             已存在跳过: $p"
                TOTAL_PATHS_SKIPPED=$((TOTAL_PATHS_SKIPPED + 1))
            else
                echo "             将新增:    $p"
                TOTAL_PATHS_ADDED=$((TOTAL_PATHS_ADDED + 1))
            fi
        done
        continue
    fi

    # 真写
    OUT=$(python3 "$BACK_REF" write-multi "$REQ_FILE" "${PATHS_ARR[@]}" 2>&1) || {
        echo "  ✗ 写入失败 $REQ_ID: $OUT"
        ERRORS=$((ERRORS + 1))
        continue
    }
    # 解析输出 added=N skipped=M
    ADDED=$(echo "$OUT" | grep -oP 'added=\K\d+' || echo 0)
    SKIPPED=$(echo "$OUT" | grep -oP 'skipped=\K\d+' || echo 0)
    TOTAL_PATHS_ADDED=$((TOTAL_PATHS_ADDED + ADDED))
    TOTAL_PATHS_SKIPPED=$((TOTAL_PATHS_SKIPPED + SKIPPED))
    if [ "$ADDED" -gt 0 ]; then
        TOTAL_REQS_TOUCHED=$((TOTAL_REQS_TOUCHED + 1))
    fi
    echo "  ✓ $REQ_ID added=$ADDED skipped=$SKIPPED"
done <<< "$MAPPING_LINES"

echo ""
echo "[sync-back-refs] 统计："
echo "  扫描 mapping:    $TOTAL_MAPPINGS"
echo "  回填 REQ 数量:    $TOTAL_REQS_TOUCHED"
echo "  新增 prototype 路径: $TOTAL_PATHS_ADDED"
echo "  已存在跳过:       $TOTAL_PATHS_SKIPPED"
echo "  错误数:           $ERRORS"

if [ "$ERRORS" -gt 0 ]; then
    echo "[sync-back-refs] ✗ 有 $ERRORS 条 mapping 处理失败"
    exit 1
fi

if [ "$DRY_RUN" = "yes" ]; then
    echo "[sync-back-refs] ✓ dry-run 完成（未实际写入）"
    exit 0
fi

# === POST-CHECK ASSERTION ===
# 再扫一遍 mapping，每条 mapping 的所有 files 都必须能在对应 REQ 中 check 通过
echo ""
echo "[sync-back-refs] post-check assertion: 验证所有 mapping 已生效..."
ASSERT_FAIL=0
while IFS=$'\t' read -r REQ_ID FILES_CSV; do
    [ -z "$REQ_ID" ] && continue
    REQ_FILE="$REQ_DIR/${REQ_ID}.md"
    [ -f "$REQ_FILE" ] || continue
    IFS=',' read -ra PATHS_ARR <<< "$FILES_CSV"
    for p in "${PATHS_ARR[@]}"; do
        if ! python3 "$BACK_REF" check "$REQ_FILE" "$p" >/dev/null 2>&1; then
            echo "  ✗ ASSERTION FAILED: $REQ_ID 缺失 prototype 路径: $p"
            ASSERT_FAIL=$((ASSERT_FAIL + 1))
        fi
    done
done <<< "$MAPPING_LINES"

if [ "$ASSERT_FAIL" -gt 0 ]; then
    echo "[sync-back-refs] ✗ post-check 发现 $ASSERT_FAIL 个不一致项，请人工检查"
    exit 1
fi

echo "[sync-back-refs] ✓ post-check 通过：所有 mapping 已正确回填到 REQ"
exit 0
