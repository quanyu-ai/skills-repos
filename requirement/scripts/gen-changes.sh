#!/bin/bash
# gen-changes.sh - 生成两个版本的需求变更对照表
# Usage: gen-changes.sh <project> <from-version> <to-version>
# 例: gen-changes.sh smart-college v3.0 v4.0
#
# 逻辑：
#   1. 读 _archive/<from-version>-*/requirements-map.json 作为旧版基准
#   2. 读 当前 requirements-map.json 作为新版基准
#   3. 对比：deprecated / added / modified / unchanged
#   4. 输出 markdown 到 reviews/CHANGES-<from>-to-<to>.md

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 3 ] && { echo "Usage: $0 <project> <from-version> <to-version>"; exit 1; }

PROJECT="$1"
FROM_VER="$2"
TO_VER="$3"

PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
REQ_DIR="$PROJECT_DOCS/requirements"
ARCHIVE_DIR="$REQ_DIR/_archive"

[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found" >&2; exit 2; }

# 找旧版归档目录
OLD_DIR=""
if [ -d "$ARCHIVE_DIR" ]; then
    # 匹配 <from>-* 模式（如 v3.0-20260522 或 v3.0-2026-05-22-xxx）
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        OLD_DIR="$d"
        break
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type d -name "${FROM_VER}-*" | sort)
fi

if [ -z "$OLD_DIR" ]; then
    echo "ERROR: 未找到旧版归档目录 $ARCHIVE_DIR/${FROM_VER}-*" >&2
    echo "       请先用 archive.sh 归档：bash skills/requirement/scripts/archive.sh $PROJECT $FROM_VER" >&2
    exit 1
fi

OLD_MAP="$OLD_DIR/requirements-map.json"
NEW_MAP="$REQ_DIR/requirements-map.json"

[ -f "$OLD_MAP" ] || { echo "ERROR: 旧版 map 缺失: $OLD_MAP" >&2; exit 1; }
[ -f "$NEW_MAP" ] || { echo "ERROR: 新版 map 缺失: $NEW_MAP" >&2; exit 1; }

REVIEWS_DIR="$PROJECT_DOCS/reviews"
mkdir -p "$REVIEWS_DIR"
OUT="$REVIEWS_DIR/CHANGES-${FROM_VER}-to-${TO_VER}.md"

echo "[gen-changes] 对比 $OLD_MAP  ⇄  $NEW_MAP"
echo "[gen-changes] 输出 → $OUT"

# 用 python 做实际对比（避免 jq 复杂转义）
python3 - "$OLD_MAP" "$NEW_MAP" "$REQ_DIR" "$PROJECT" "$FROM_VER" "$TO_VER" "$OUT" <<'PYEOF'
import json, sys, os, re
from pathlib import Path
from datetime import datetime

old_map_path, new_map_path, req_dir, project, fv, tv, out = sys.argv[1:8]

with open(old_map_path, encoding='utf-8') as f:
    old = json.load(f)
with open(new_map_path, encoding='utf-8') as f:
    new = json.load(f)

old_reqs = old.get('requirements', {})
new_reqs = new.get('requirements', {})

old_ids = set(old_reqs.keys())
new_ids = set(new_reqs.keys())

deprecated_ids = sorted(old_ids - new_ids)
added_ids = sorted(new_ids - old_ids)
common_ids = sorted(old_ids & new_ids)

# 对比 common 中哪些字段变了
COMPARE_FIELDS = ['title', 'status', 'phase', 'priority', 'category', 'role']
modified = []
unchanged = []
for rid in common_ids:
    o = old_reqs[rid]
    n = new_reqs[rid]
    diffs = []
    for k in COMPARE_FIELDS:
        if o.get(k) != n.get(k):
            diffs.append((k, o.get(k), n.get(k)))
    if diffs:
        modified.append((rid, diffs))
    else:
        unchanged.append(rid)

# 读 deprecated REQ 的 merged_to（需读旧文件——但旧文件已归档）
FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---', re.DOTALL)

def read_frontmatter_field(path, key):
    if not os.path.isfile(path):
        return None
    try:
        text = Path(path).read_text(encoding='utf-8')
    except Exception:
        return None
    m = FRONTMATTER_RE.match(text)
    if not m:
        return None
    fm = m.group(1)
    # 简单按行查 key:
    for line in fm.split('\n'):
        line_s = line.rstrip()
        m2 = re.match(rf'^{re.escape(key)}:\s*(.*)$', line_s)
        if m2:
            val = m2.group(1).strip().strip('"').strip("'")
            return val
    return None

# 优先读归档文件里的 merged_to
old_archive_dir = os.path.dirname(old_map_path)
new_reqs_dir = req_dir

def find_req_file(rid):
    # 优先新目录（如果还在）
    p1 = os.path.join(new_reqs_dir, f"{rid}.md")
    if os.path.isfile(p1):
        return p1
    p2 = os.path.join(old_archive_dir, f"{rid}.md")
    if os.path.isfile(p2):
        return p2
    return None

# 生成 markdown
lines = []
lines.append(f"# {project} 需求变更对照：{fv} → {tv}")
lines.append("")
lines.append(f"> 自动生成于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
lines.append(f"> 旧版基准：`{os.path.relpath(old_map_path, start=os.path.dirname(out))}`")
lines.append(f"> 新版基准：`{os.path.relpath(new_map_path, start=os.path.dirname(out))}`")
lines.append("")
lines.append("## 总览")
lines.append("")
lines.append(f"| 类别 | 数量 |")
lines.append(f"|------|------|")
lines.append(f"| 旧版总数 | {len(old_ids)} |")
lines.append(f"| 新版总数 | {len(new_ids)} |")
lines.append(f"| 新增 (added) | {len(added_ids)} |")
lines.append(f"| 删除/废弃 (deprecated) | {len(deprecated_ids)} |")
lines.append(f"| 修改 (modified) | {len(modified)} |")
lines.append(f"| 未变 (unchanged) | {len(unchanged)} |")
lines.append("")

# ------- 综合表 -------
lines.append("## 变更对照表")
lines.append("")
lines.append(f"| {fv} ID | 状态 | 处理 | {tv} ID | 备注 |")
lines.append("|---------|------|------|---------|------|")

# deprecated
for rid in deprecated_ids:
    o = old_reqs[rid]
    title = (o.get('title') or '').replace('|', '\\|')
    # 查 merged_to
    req_path = find_req_file(rid)
    merged_to = read_frontmatter_field(req_path, 'merged_to') if req_path else None
    reason = read_frontmatter_field(req_path, 'deprecated_reason') if req_path else None
    if merged_to:
        action = "合并/迁移"
        new_id_str = merged_to
        note = f"原 `{title}`"
    elif reason:
        action = "废弃"
        new_id_str = "—"
        note = f"原 `{title}`，原因：{reason}"
    else:
        action = "废弃/未知"
        new_id_str = "—"
        note = f"原 `{title}`（建议补 merged_to/deprecated_reason）"
    lines.append(f"| {rid} | deprecated | {action} | {new_id_str} | {note} |")

# added
for rid in added_ids:
    n = new_reqs[rid]
    title = (n.get('title') or '').replace('|', '\\|')
    source_review = ''
    req_path = find_req_file(rid)
    if req_path:
        source_review = read_frontmatter_field(req_path, 'source_review') or ''
    note_bits = [f"新增 `{title}`"]
    if source_review:
        note_bits.append(f"来源：{source_review}")
    lines.append(f"| — | added | 新建 | {rid} | {' / '.join(note_bits)} |")

# modified
for rid, diffs in modified:
    o = old_reqs[rid]; n = new_reqs[rid]
    title = (n.get('title') or '').replace('|', '\\|')
    diff_str = "; ".join([f"{k}: `{ov}` → `{nv}`" for k, ov, nv in diffs])
    diff_str = diff_str.replace('|', '\\|')
    lines.append(f"| {rid} | modified | 修改 | {rid} | {title}：{diff_str} |")

lines.append("")
lines.append("## 未变需求（仅列 ID）")
lines.append("")
if unchanged:
    chunk = ', '.join(f"`{x}`" for x in unchanged)
    lines.append(chunk)
else:
    lines.append("_无_")
lines.append("")

Path(out).write_text("\n".join(lines), encoding='utf-8')

print(f"  added={len(added_ids)} deprecated={len(deprecated_ids)} modified={len(modified)} unchanged={len(unchanged)}")
PYEOF

# Assertion
[ -f "$OUT" ] || { echo "ERROR: 输出文件未生成: $OUT" >&2; exit 1; }
LINES_CNT=$(wc -l < "$OUT")
if [ "$LINES_CNT" -lt 10 ]; then
    echo "ERROR: 输出文件行数异常 ($LINES_CNT)，可能生成失败" >&2
    exit 1
fi

echo "[gen-changes] ✓ 生成完成: $OUT ($LINES_CNT 行)"
