#!/bin/bash
# lint.sh - 校验项目下所有 REQ 文件 frontmatter 完整性与一致性
# Usage: lint.sh <project>
#
# 检查项：
#   1. 必填字段：id / title / status / phase / priority / category / created / updated
#   2. id 必须 REQ-YYYYMMDD-NNN
#   3. status 必须 ∈ draft|reviewing|approved|implementing|done|deprecated
#   4. 文件名 == id
#   5. deprecated 必须有 merged_to 或 history reason 或 deprecated_reason
#   6. updated >= created
#
# 失败 exit 1，全部通过 exit 0

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 1 ] && { echo "Usage: $0 <project>"; exit 1; }

PROJECT="$1"
REQ_DIR="$WORKSPACE_ROOT/docs-repos/$PROJECT/requirements"
[ -d "$REQ_DIR" ] || { echo "ERROR: $REQ_DIR not found" >&2; exit 2; }

echo "[lint] 检查 $REQ_DIR"

python3 - "$REQ_DIR" <<'PYEOF'
import sys, os, re
from pathlib import Path
from datetime import datetime

req_dir = Path(sys.argv[1])

REQUIRED = ['id', 'title', 'status', 'phase', 'priority', 'category', 'created', 'updated']
VALID_STATUSES = {'draft', 'reviewing', 'approved', 'implementing', 'done', 'deprecated'}
ID_RE = re.compile(r'^REQ-\d{8}-\d{3}$')
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---\s*\n', re.DOTALL)

def parse_simple_yaml(fm_text):
    """极简 yaml 解析：只支持 key: value 顶层字段"""
    out = {}
    cur_key = None
    for raw in fm_text.split('\n'):
        line = raw.rstrip()
        if not line.strip():
            cur_key = None
            continue
        # 顶层 key: value
        m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)$', line)
        if m:
            k, v = m.group(1), m.group(2).strip()
            v = v.strip('"').strip("'")
            out[k] = v
            cur_key = k
    return out

def get_block_lines(fm_text, key):
    """获取以 'key:' 开头的整个 block 内容（包括嵌套）"""
    lines = fm_text.split('\n')
    out = []
    in_block = False
    for i, line in enumerate(lines):
        if re.match(rf'^{re.escape(key)}:\s*$', line.rstrip()) or re.match(rf'^{re.escape(key)}:\s*\[\]\s*$', line.rstrip()):
            in_block = True
            out.append(line)
            continue
        if in_block:
            if re.match(r'^[a-zA-Z_]', line):
                # 离开 block
                break
            out.append(line)
    return out

errors = []
warnings = []
total = 0

req_files = sorted(req_dir.glob('REQ-*.md'))
print(f"[lint] 扫描 {len(req_files)} 个 REQ 文件\n")

for f in req_files:
    total += 1
    file_id = f.stem  # 不含 .md
    rel = f.name
    text = f.read_text(encoding='utf-8')
    m = FRONTMATTER_RE.match(text)
    if not m:
        errors.append((rel, 'no_frontmatter', '缺 frontmatter'))
        continue
    fm = m.group(1)
    fields = parse_simple_yaml(fm)

    # 1. 必填
    for k in REQUIRED:
        v = fields.get(k, '').strip()
        if not v:
            errors.append((rel, 'missing_field', f'缺字段 {k}'))

    # 2. id 格式
    fid = fields.get('id', '')
    if fid and not ID_RE.match(fid):
        errors.append((rel, 'bad_id_format', f'id={fid} 不符合 REQ-YYYYMMDD-NNN'))

    # 3. status 合法性
    st = fields.get('status', '')
    if st and st not in VALID_STATUSES:
        errors.append((rel, 'bad_status', f'status={st} 非法'))

    # 4. 文件名 == id
    if fid and fid != file_id:
        errors.append((rel, 'id_mismatch', f'文件名={file_id} 与 id={fid} 不一致'))

    # 5. deprecated 必须有 merged_to 或 reason
    if st == 'deprecated':
        merged_to = fields.get('merged_to', '').strip()
        dep_reason = fields.get('deprecated_reason', '').strip()
        # 也检查 history 里是否有 reason: 关键字
        history_lines = get_block_lines(fm, 'history')
        history_has_reason = any('reason:' in ln or 'merged_to:' in ln for ln in history_lines)
        if not merged_to and not dep_reason and not history_has_reason:
            errors.append((rel, 'deprecated_no_reason',
                          'deprecated 但缺 merged_to / deprecated_reason / history.reason'))

    # 6. updated >= created
    c = fields.get('created', '')
    u = fields.get('updated', '')
    if c and u and DATE_RE.match(c) and DATE_RE.match(u):
        if u < c:
            errors.append((rel, 'date_inverted', f'updated={u} 早于 created={c}'))

    # 7. created/updated 格式
    if c and not DATE_RE.match(c):
        warnings.append((rel, 'date_format', f'created={c} 非 YYYY-MM-DD'))
    if u and not DATE_RE.match(u):
        warnings.append((rel, 'date_format', f'updated={u} 非 YYYY-MM-DD'))

# 报告
print("=" * 60)
print(f"  Lint 报告 - 共 {total} 个 REQ 文件")
print("=" * 60)
print(f"  ✓ 通过: {total - len({e[0] for e in errors})}")
print(f"  ✗ 错误: {len(errors)} 条 (涉及 {len({e[0] for e in errors})} 个文件)")
print(f"  ⚠ 警告: {len(warnings)} 条")
print()

if errors:
    print("─" * 60)
    print("❌ 错误列表（按类型分组）")
    print("─" * 60)
    from collections import defaultdict
    by_type = defaultdict(list)
    for rel, etype, msg in errors:
        by_type[etype].append((rel, msg))
    for etype, items in sorted(by_type.items()):
        print(f"\n[{etype}] ({len(items)} 条)")
        for rel, msg in items[:20]:
            print(f"  - {rel}: {msg}")
        if len(items) > 20:
            print(f"  ... 还有 {len(items)-20} 条")

if warnings:
    print()
    print("─" * 60)
    print("⚠️  警告列表")
    print("─" * 60)
    for rel, wtype, msg in warnings[:30]:
        print(f"  [{wtype}] {rel}: {msg}")
    if len(warnings) > 30:
        print(f"  ... 还有 {len(warnings)-30} 条")

print()
if errors:
    sys.exit(1)
else:
    print("✅ Lint 全部通过")
    sys.exit(0)
PYEOF
