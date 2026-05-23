#!/usr/bin/env bash
# generate-index.sh — 通用：根据 requirements + prototype meta + versions + index-config
# 自动生成项目门户页 prototype/index.html
#
# 用法：bash generate-index.sh <project>
#   例：bash generate-index.sh smart-college
#
# 输入：
#   docs-repos/<project>/requirements/requirements-map.json         （必需）
#   docs-repos/<project>/prototype/meta/requirements-map.json       （必需）
#   docs-repos/<project>/prototype/meta/versions.json               （可选）
#   docs-repos/<project>/prototype/meta/index-config.json           （可选，缺失走默认）
#
# 输出：
#   docs-repos/<project>/prototype/index.html
#
# Assertion：
#   - 文件 > 8KB
#   - 包含版本切换器
#   - 包含至少 1 个角色块
#   - 总需求数与 requirements-map.json 一致

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "[generate-index] usage: bash $0 <project>" >&2
  exit 2
fi

PROJECT="$1"
PROJECT_DIR="${WORKSPACE}/docs-repos/${PROJECT}"
REQ_MAP="${PROJECT_DIR}/requirements/requirements-map.json"
PROTO_META="${PROJECT_DIR}/prototype/meta/requirements-map.json"
VERSIONS_FILE="${PROJECT_DIR}/prototype/meta/versions.json"
INDEX_CONFIG="${PROJECT_DIR}/prototype/meta/index-config.json"
CONFIG_TEMPLATE="${SKILL_DIR}/templates/shared/index-config.template.json"
OUT_FILE="${PROJECT_DIR}/prototype/index.html"

[[ -f "${REQ_MAP}" ]]   || { echo "[generate-index] FATAL: requirements map not found: ${REQ_MAP}" >&2; exit 3; }
[[ -f "${PROTO_META}" ]] || { echo "[generate-index] FATAL: prototype meta not found: ${PROTO_META}" >&2; exit 3; }

echo "[generate-index] project=${PROJECT}"
echo "[generate-index] req_map=${REQ_MAP}"
echo "[generate-index] proto_meta=${PROTO_META}"
[[ -f "${VERSIONS_FILE}" ]] && echo "[generate-index] versions=${VERSIONS_FILE}" || echo "[generate-index] versions=(none)"
if [[ -f "${INDEX_CONFIG}" ]]; then
  echo "[generate-index] index-config=${INDEX_CONFIG}"
else
  echo "[generate-index] index-config=(missing, will use template defaults)"
fi
echo "[generate-index] out=${OUT_FILE}"

export GENINDEX_PROJECT="${PROJECT}"
export GENINDEX_PROJECT_DIR="${PROJECT_DIR}"
export GENINDEX_REQ_MAP="${REQ_MAP}"
export GENINDEX_PROTO_META="${PROTO_META}"
export GENINDEX_VERSIONS="${VERSIONS_FILE}"
export GENINDEX_CONFIG="${INDEX_CONFIG}"
export GENINDEX_CONFIG_TEMPLATE="${CONFIG_TEMPLATE}"
export GENINDEX_OUT="${OUT_FILE}"

python3 "${SCRIPT_DIR}/lib/generate_index.py"

# === Assertions ===
SIZE=$(wc -c < "${OUT_FILE}")
if [[ "${SIZE}" -lt 8192 ]]; then
  echo "[generate-index] FATAL: index.html too small (${SIZE} < 8192 bytes)" >&2
  exit 4
fi

if ! grep -q 'id="version-switcher"' "${OUT_FILE}"; then
  echo "[generate-index] FATAL: version switcher missing" >&2
  exit 4
fi

ROLE_BLOCKS=$(grep -c 'class="role-section' "${OUT_FILE}" || true)
if [[ "${ROLE_BLOCKS}" -lt 1 ]]; then
  echo "[generate-index] FATAL: no role-section block found" >&2
  exit 4
fi

# 一致性校验：总需求数标记
TOTAL_REQ_EXPECTED=$(python3 -c "import json,os; m=json.load(open(os.environ['GENINDEX_REQ_MAP'])); print(m['stats']['total'])")
if ! grep -q "data-stat-total-req=\"${TOTAL_REQ_EXPECTED}\"" "${OUT_FILE}"; then
  echo "[generate-index] FATAL: total req count mismatch in HTML (expected ${TOTAL_REQ_EXPECTED})" >&2
  exit 4
fi

echo "[generate-index] OK size=${SIZE} role_blocks=${ROLE_BLOCKS} total_req=${TOTAL_REQ_EXPECTED}"
echo "[generate-index] DONE -> ${OUT_FILE}"
