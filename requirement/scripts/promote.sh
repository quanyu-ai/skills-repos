#!/bin/bash
# promote.sh - 把当前状态升级为正式版本
# Usage: bash promote.sh <project> <new-version>
#
# 动作:
#   1. 调用 archive.sh 备份当前为 <new-version>
#   2. 给所有 REQ-*.md frontmatter 设置/更新 version: <new-version>
#   3. 在 history 字段加一条记录
#   4. 输出汇报

set -e

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 2 ] && { echo "Usage: $0 <project> <new-version>" >&2; exit 1; }

PROJECT="$1"
VERSION="$2"
DATE_HUMAN="$(date +%Y-%m-%d)"

REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found" >&2; exit 2; }

echo "[promote] Step 1/3 - 归档当前为 $VERSION..."
bash "$SKILL_DIR/scripts/archive.sh" "$PROJECT" "$VERSION"

echo ""
echo "[promote] Step 2/3 - 更新 REQ frontmatter (version + history)..."

UPDATED=0
shopt -s nullglob
for f in "$REQ_DIR"/REQ-*.md; do
    python3 - "$f" "$VERSION" "$DATE_HUMAN" <<'PYEOF'
import sys, re, os
path, version, date = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as fp:
    text = fp.read()

m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
if not m:
    sys.exit(0)

fm = m.group(1)
body = text[m.end():]

# 处理 version 字段
if re.search(r'^version:\s*.*$', fm, re.MULTILINE):
    fm = re.sub(r'^version:\s*.*$', f'version: {version}', fm, count=1, flags=re.MULTILINE)
else:
    # 在 updated: 之后插入
    if re.search(r'^updated:\s*.*$', fm, re.MULTILINE):
        fm = re.sub(r'(^updated:\s*.*$)', rf'\1\nversion: {version}', fm, count=1, flags=re.MULTILINE)
    else:
        fm = fm + f'\nversion: {version}'

# 处理 history 字段
hist_entry = f'  - {{ version: {version}, action: promoted, date: {date} }}'
if re.search(r'^history:', fm, re.MULTILINE):
    # 在 history: 行下插入新条目（在最前）
    fm = re.sub(
        r'^(history:\s*)$',
        rf'\1\n{hist_entry}',
        fm, count=1, flags=re.MULTILINE
    )
else:
    fm = fm + f'\nhistory:\n{hist_entry}'

new_text = f'---\n{fm}\n---\n{body}'
with open(path, 'w', encoding='utf-8') as fp:
    fp.write(new_text)
PYEOF
    UPDATED=$((UPDATED+1))
done
shopt -u nullglob

echo "[promote] 已更新 $UPDATED 条 REQ"
echo ""
echo "[promote] Step 3/3 - 完成"
echo "═════════════════════════════════════"
echo "  Promote 完成: $PROJECT → $VERSION"
echo "═════════════════════════════════════"
echo "  归档目录: docs-repos/$PROJECT/requirements/_archive/${VERSION}-$(date +%Y%m%d)/"
echo "  更新条目: $UPDATED"
echo "  日期: $DATE_HUMAN"
echo "═════════════════════════════════════"
