#!/bin/bash
# set-status.sh - 修改 REQ 的 status，自动更新 history、updated，并 sync-map
# Usage:
#   set-status.sh <project> <REQ-id> <new-status>           # 单条
#   set-status.sh <project> --role <角色> <new-status>      # 按角色批量
#   set-status.sh <project> --phase <阶段> <new-status>     # 按阶段批量
#   set-status.sh <project> --all <new-status>              # 全部
#
# 改 deprecated 时强制要求二选一（任一即可）：
#   --merged-to <REQ-ID>   合并到的新 REQ
#   --reason "<原因>"      废弃原因（如 "已砍掉/客户撤回"）
#
# 例：
#   bash set-status.sh smart-college REQ-20260522-001 deprecated --merged-to REQ-20260523-001
#   bash set-status.sh smart-college REQ-20260522-002 deprecated --reason "客户撤回"

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

usage() {
    sed -n '2,16p' "$0"
    exit 1
}

[ $# -lt 3 ] && usage

PROJECT="$1"; shift
REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
MAP="$REQ_DIR/requirements-map.json"
[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found" >&2; exit 2; }

# 解析 mode
MODE=""
SELECTOR=""
NEW_STATUS=""
case "$1" in
    --role)
        MODE="role"; SELECTOR="$2"; NEW_STATUS="$3"
        [ $# -lt 3 ] && usage
        shift 3
        ;;
    --phase)
        MODE="phase"; SELECTOR="$2"; NEW_STATUS="$3"
        [ $# -lt 3 ] && usage
        shift 3
        ;;
    --all)
        MODE="all"; NEW_STATUS="$2"
        [ $# -lt 2 ] && usage
        shift 2
        ;;
    *)
        MODE="single"; SELECTOR="$1"; NEW_STATUS="$2"
        [ $# -lt 2 ] && usage
        shift 2
        ;;
esac

# 解析 deprecated 专用可选参数：--merged-to / --reason
MERGED_TO=""
DEP_REASON=""
while [ $# -gt 0 ]; do
    case "$1" in
        --merged-to) MERGED_TO="$2"; shift 2 ;;
        --reason)    DEP_REASON="$2"; shift 2 ;;
        *) echo "ERROR: 未知参数: $1" >&2; usage ;;
    esac
done

# 改 deprecated 时强制要求二选一
if [ "$NEW_STATUS" = "deprecated" ]; then
    if [ -z "$MERGED_TO" ] && [ -z "$DEP_REASON" ]; then
        echo "ERROR: 改 deprecated 必须传 --merged-to <REQ-ID> 或 --reason \"<原因>\" 二选一" >&2
        echo "       例：set-status.sh $PROJECT $SELECTOR deprecated --merged-to REQ-XXXX-NNN" >&2
        echo "       例：set-status.sh $PROJECT $SELECTOR deprecated --reason \"已砍掉\"" >&2
        exit 1
    fi
    # 若提供 --merged-to，校验 REQ-ID 格式
    if [ -n "$MERGED_TO" ]; then
        if ! [[ "$MERGED_TO" =~ ^REQ-[0-9]{8}-[0-9]{3}$ ]]; then
            echo "ERROR: --merged-to 格式应为 REQ-YYYYMMDD-NNN，传入: $MERGED_TO" >&2
            exit 1
        fi
    fi
fi

# 合法状态集合
VALID_STATUSES="draft reviewing approved implementing done deprecated"
is_valid_status() {
    local s="$1"
    for v in $VALID_STATUSES; do [ "$v" = "$s" ] && return 0; done
    return 1
}

# 状态机：from -> allowed-tos
# draft -> reviewing
# reviewing -> approved | draft
# approved -> implementing
# implementing -> done | deprecated
# 任何状态 -> deprecated
allowed_transition() {
    local from="$1" to="$2"
    [ "$from" = "$to" ] && return 0     # 幂等：相同状态视为合法（no-op）
    [ "$to" = "deprecated" ] && return 0
    case "$from" in
        draft)        [ "$to" = "reviewing" ] && return 0 ;;
        reviewing)    { [ "$to" = "approved" ] || [ "$to" = "draft" ]; } && return 0 ;;
        approved)     [ "$to" = "implementing" ] && return 0 ;;
        implementing) [ "$to" = "done" ] && return 0 ;;
        done)         return 1 ;;
        deprecated)   return 1 ;;
    esac
    return 1
}

is_valid_status "$NEW_STATUS" || {
    echo "ERROR: 非法目标状态 '$NEW_STATUS'，合法值: $VALID_STATUSES" >&2
    exit 1
}

# 收集目标文件列表
collect_targets() {
    case "$MODE" in
        single)
            local f="$REQ_DIR/$SELECTOR.md"
            [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
            echo "$f"
            ;;
        role|phase)
            [ -f "$MAP" ] || { echo "ERROR: $MAP 不存在，请先 sync-map.sh" >&2; exit 1; }
            local key
            [ "$MODE" = "role" ] && key="role" || key="phase"
            jq -r --arg sel "$SELECTOR" --arg key "$key" \
                '.requirements | to_entries[] | select(.value[$key] == $sel) | .value.file' "$MAP" \
              | while read -r rel; do
                  [ -n "$rel" ] && echo "$WORKSPACE_ROOT/$rel"
                done
            ;;
        all)
            ls "$REQ_DIR"/REQ-*.md 2>/dev/null
            ;;
    esac
}

mapfile -t TARGETS < <(collect_targets)
[ "${#TARGETS[@]}" -eq 0 ] && { echo "ERROR: 未匹配到任何 REQ" >&2; exit 1; }

echo "[set-status] 目标数: ${#TARGETS[@]}，新状态: $NEW_STATUS，模式: $MODE${SELECTOR:+ ($SELECTOR)}"

# 提取 frontmatter status
get_status() {
    awk '
        BEGIN { in_fm=0 }
        /^---$/ { if (in_fm) exit; in_fm=1; next }
        in_fm && /^status:[[:space:]]/ {
            sub(/^status:[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print; exit
        }
    ' "$1"
}

get_version() {
    awk '
        BEGIN { in_fm=0 }
        /^---$/ { if (in_fm) exit; in_fm=1; next }
        in_fm && /^version:[[:space:]]/ {
            sub(/^version:[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print; exit
        }
    ' "$1"
}

# Step 1: dry-run 校验所有目标的状态转换
echo "[set-status] Step 1/3 - 校验状态机..."
DRYRUN_FAILED=0
declare -a SKIP_LIST
declare -a CHANGE_LIST
for f in "${TARGETS[@]}"; do
    cur=$(get_status "$f")
    if [ -z "$cur" ]; then
        echo "  ✗ $(basename "$f"): 无 status 字段" >&2
        DRYRUN_FAILED=1
        continue
    fi
    if [ "$cur" = "$NEW_STATUS" ]; then
        SKIP_LIST+=("$f")
        continue
    fi
    if ! allowed_transition "$cur" "$NEW_STATUS"; then
        echo "  ✗ $(basename "$f"): $cur → $NEW_STATUS 不是合法转换" >&2
        DRYRUN_FAILED=1
        continue
    fi
    CHANGE_LIST+=("$f")
done

if [ $DRYRUN_FAILED -ne 0 ]; then
    echo "[set-status] ✗ 状态机校验失败，已回滚（未改动任何文件）" >&2
    exit 1
fi

echo "  待变更: ${#CHANGE_LIST[@]}，已是目标状态(跳过): ${#SKIP_LIST[@]}"

# Step 2: 真改
echo "[set-status] Step 2/3 - 写入 frontmatter..."
TODAY=$(date +%Y-%m-%d)
CHANGED=0
for f in "${CHANGE_LIST[@]}"; do
    cur=$(get_status "$f")
    ver=$(get_version "$f")
    [ -z "$ver" ] && ver="unversioned"
    python3 - "$f" "$cur" "$NEW_STATUS" "$TODAY" "$ver" "$MERGED_TO" "$DEP_REASON" <<'PYEOF'
import sys, re
path, old, new, today, ver, merged_to, reason = sys.argv[1:8]
with open(path, 'r', encoding='utf-8') as fp:
    text = fp.read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
if not m:
    sys.exit("ERROR: no frontmatter in " + path)
fm = m.group(1)
body = text[m.end():]

# 更新 status
if re.search(r'^status:\s*.*$', fm, re.MULTILINE):
    fm = re.sub(r'^status:\s*.*$', f'status: {new}', fm, count=1, flags=re.MULTILINE)
else:
    sys.exit("ERROR: status field missing in " + path)

# 更新 updated
if re.search(r'^updated:\s*.*$', fm, re.MULTILINE):
    fm = re.sub(r'^updated:\s*.*$', f'updated: {today}', fm, count=1, flags=re.MULTILINE)
else:
    fm = fm + f'\nupdated: {today}'

# deprecated 专用字段写入
if new == 'deprecated':
    if merged_to:
        if re.search(r'^merged_to:\s*.*$', fm, re.MULTILINE):
            fm = re.sub(r'^merged_to:\s*.*$', f'merged_to: {merged_to}', fm, count=1, flags=re.MULTILINE)
        else:
            fm = fm + f'\nmerged_to: {merged_to}'
    if reason:
        # 用 deprecated_reason 字段保存原因，避免与其他字段混淆
        # 用双引号包裹，转义双引号
        reason_safe = reason.replace('"', '\\"')
        if re.search(r'^deprecated_reason:\s*.*$', fm, re.MULTILINE):
            fm = re.sub(r'^deprecated_reason:\s*.*$', f'deprecated_reason: "{reason_safe}"', fm, count=1, flags=re.MULTILINE)
        else:
            fm = fm + f'\ndeprecated_reason: "{reason_safe}"'

# 追加 history
lines = fm.split('\n')
h_idx = None
for i, line in enumerate(lines):
    if re.match(r'^history:\s*$', line) or re.match(r'^history:\s*\[\]\s*$', line):
        h_idx = i
        break

# 拼 history entry
entry_extra = ''
if new == 'deprecated':
    if merged_to:
        entry_extra = f', merged_to: {merged_to}'
    elif reason:
        reason_inline = reason.replace('"', '\\"')
        entry_extra = f', reason: "{reason_inline}"'

if h_idx is None:
    fm = fm + f'\nhistory:\n  - {{ version: {ver}, action: status_changed, from: {old}, to: {new}, date: {today}{entry_extra} }}'
else:
    indent = '  '
    for j in range(h_idx + 1, len(lines)):
        line = lines[j]
        if line.strip() == '':
            continue
        m2 = re.match(r'^(\s*)-\s', line)
        if m2:
            cand = m2.group(1)
            # 强制缩进至少 2 空格（避免 column-0 list item 导致 YAML 损坏）
            indent = cand if len(cand) >= 2 else '  '
            break
        if re.match(r'^[a-zA-Z_]', line):
            break
    entry = f'{indent}- {{ version: {ver}, action: status_changed, from: {old}, to: {new}, date: {today}{entry_extra} }}'
    if re.match(r'^history:\s*\[\]\s*$', lines[h_idx]):
        lines[h_idx] = 'history:'
    lines.insert(h_idx + 1, entry)
    fm = '\n'.join(lines)

with open(path, 'w', encoding='utf-8') as fp:
    fp.write(f'---\n{fm}\n---\n{body}')
PYEOF
    CHANGED=$((CHANGED+1))
done
echo "  ✓ 已改: $CHANGED"

# Step 3: sync-map
echo "[set-status] Step 3/3 - 重建索引..."
bash "$SKILL_DIR/scripts/sync-map.sh" "$PROJECT" >/dev/null
echo "  ✓ sync-map 完成"

# Post-check assertion: 验证 map 里所有变更过的 REQ status 确实是新值
echo "[set-status] Post-check..."
for f in "${CHANGE_LIST[@]}"; do
    id=$(basename "$f" .md)
    map_status=$(jq -r --arg id "$id" '.requirements[$id].status // "MISSING"' "$MAP")
    if [ "$map_status" != "$NEW_STATUS" ]; then
        echo "  ✗ ASSERT FAIL: $id 在 map 里 status=$map_status，期望 $NEW_STATUS" >&2
        exit 1
    fi
done
echo "  ✓ 一致性 OK"

echo ""
echo "═════════════════════════════════════"
echo "  set-status 完成: $PROJECT"
echo "  变更: $CHANGED 条 → $NEW_STATUS"
echo "  跳过(已是目标状态): ${#SKIP_LIST[@]}"
echo "═════════════════════════════════════"
