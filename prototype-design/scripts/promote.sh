#!/bin/bash
# promote.sh - 把当前原型升级为正式版本
# Usage: bash promote.sh <project> <new-version>
#
# 动作:
#   1. 调用 archive.sh
#   2. 更新 meta/version.json 写入当前版本号
#   3. 在 meta/revisions.md 加一条 "升级到 <new-version>" 记录

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 2 ] && { echo "Usage: $0 <project> <new-version>" >&2; exit 1; }

PROJECT="$1"
VERSION="$2"
DATE_TAG="$(date +%Y%m%d)"
DATE_HUMAN="$(date +%Y-%m-%d)"

PROTO_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/prototype"
[ -d "$PROTO_DIR" ] || { echo "ERROR: $PROTO_DIR not found" >&2; exit 2; }

echo "[promote] Step 1/3 - 归档原型..."
bash "$SKILL_DIR/scripts/archive.sh" "$PROJECT" "$VERSION"

echo ""
echo "[promote] Step 2/3 - 更新 meta/version.json..."
VERSION_JSON="$PROTO_DIR/meta/version.json"
mkdir -p "$PROTO_DIR/meta"

python3 - "$VERSION_JSON" "$VERSION" "$DATE_HUMAN" "$DATE_TAG" <<'PYEOF'
import sys, json, os
path, version, date, tag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as fp:
        data = json.load(fp)
else:
    data = {"current": None, "history": []}

# 防止历史里出现重复 archived 记录
hist = data.get("history") or []
new_entry = {"version": version, "archived": True, "date": date, "archive_dir": f"_archive/{version}-{tag}/"}
hist.insert(0, new_entry)
data["history"] = hist
data["current"] = version

with open(path, 'w', encoding='utf-8') as fp:
    json.dump(data, fp, ensure_ascii=False, indent=2)
PYEOF

echo "[promote] meta/version.json 已更新: current = $VERSION"

echo ""
echo "[promote] Step 3/3 - 追加 revisions.md..."
REVISIONS="$PROTO_DIR/meta/revisions.md"
TMP_LOG="$(mktemp)"
NEW_ENTRY="## ${VERSION} (${DATE_HUMAN}) - 升级到正式版本

- 类型: promote
- 归档目录: \`_archive/${VERSION}-${DATE_TAG}/\`

"
if [ -f "$REVISIONS" ]; then
    FIRST_LINE="$(head -1 "$REVISIONS")"
    if [[ "$FIRST_LINE" == \#* ]]; then
        {
            echo "$FIRST_LINE"
            echo ""
            echo "$NEW_ENTRY"
            tail -n +2 "$REVISIONS"
        } > "$TMP_LOG"
    else
        {
            echo "$NEW_ENTRY"
            cat "$REVISIONS"
        } > "$TMP_LOG"
    fi
    mv "$TMP_LOG" "$REVISIONS"
else
    cat > "$REVISIONS" <<EOF
# 原型版本记录 - $PROJECT

$NEW_ENTRY
EOF
fi

echo ""
echo "═════════════════════════════════════"
echo "  原型 Promote 完成: $PROJECT → $VERSION"
echo "═════════════════════════════════════"
echo "  current = $VERSION"
echo "  归档目录: docs-repos/$PROJECT/prototype/_archive/${VERSION}-${DATE_TAG}/"
echo "═════════════════════════════════════"
