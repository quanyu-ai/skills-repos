#!/usr/bin/env bash
# generate-mapping.sh — 通用：根据 requirements + prototype meta 生成需求-原型映射可视化 HTML
# 用法：bash generate-mapping.sh <project>
#   例：bash generate-mapping.sh smart-college
# 输出：docs-repos/<project>/prototype/mapping.html

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "[generate-mapping] usage: bash $0 <project>" >&2
  exit 2
fi

PROJECT="$1"
PROJECT_DIR="${WORKSPACE}/docs-repos/${PROJECT}"
REQ_MAP="${PROJECT_DIR}/requirements/requirements-map.json"
PROTO_META="${PROJECT_DIR}/prototype/meta/requirements-map.json"
OUT_FILE="${PROJECT_DIR}/prototype/mapping.html"

[[ -f "${REQ_MAP}" ]]    || { echo "[generate-mapping] FATAL: requirements map not found: ${REQ_MAP}" >&2; exit 3; }
[[ -f "${PROTO_META}" ]] || { echo "[generate-mapping] FATAL: prototype meta not found: ${PROTO_META}" >&2; exit 3; }

echo "[generate-mapping] project=${PROJECT}"
echo "[generate-mapping] req_map=${REQ_MAP}"
echo "[generate-mapping] proto_meta=${PROTO_META}"
echo "[generate-mapping] out=${OUT_FILE}"

REQ_MAP_PATH="${REQ_MAP}" PROTO_META_PATH="${PROTO_META}" \
OUT_PATH="${OUT_FILE}" PROJECT_NAME="${PROJECT}" \
python3 "${SCRIPT_DIR}/lib/render_mapping.py"

# 校验
SIZE=$(wc -c < "${OUT_FILE}")
LINES=$(wc -l < "${OUT_FILE}")
echo "[generate-mapping] generated: ${OUT_FILE}  (${SIZE} bytes, ${LINES} lines)"
if [[ "${SIZE}" -lt 5120 ]]; then
  echo "[generate-mapping] FATAL: mapping.html too small (${SIZE} < 5120 bytes)" >&2
  exit 4
fi
if [[ "${LINES}" -lt 100 ]]; then
  echo "[generate-mapping] FATAL: mapping.html too few lines (${LINES} < 100)" >&2
  exit 4
fi

echo "[generate-mapping] DONE"
