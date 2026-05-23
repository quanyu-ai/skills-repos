#!/bin/bash
# diff-against-requirements.sh - 需求-原型差异检测
# Usage: diff-against-requirements.sh <project>
#
# 比对：
#   - requirements/requirements-map.json   (活跃需求)
#   - prototype/meta/requirements-map.json (原型映射)
#
# 输出：
#   - REQ 存在但无原型 → 需要新建
#   - 原型存在但 REQ 已 deprecated → 应归档
#   - REQ.updated 晚于原型 generated_at → 可能需要更新
#
# 退出码：0=无差异，1=有差异（CI 可据此报警）

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

[ $# -lt 1 ] && { echo "Usage: $0 <project>"; exit 2; }

PROJECT="$1"
PROJECT_DOCS="$WORKSPACE_ROOT/docs-repos/$PROJECT"
REQ_MAP="$PROJECT_DOCS/requirements/requirements-map.json"
META_MAP="$PROJECT_DOCS/prototype/meta/requirements-map.json"

[ -f "$REQ_MAP" ] || { echo "ERROR: $REQ_MAP not found" >&2; exit 2; }
[ -f "$META_MAP" ] || { echo "ERROR: $META_MAP not found" >&2; exit 2; }

echo "[diff] 比对 $PROJECT"
echo "  REQ map  : $REQ_MAP"
echo "  Proto map: $META_MAP"
echo ""

python3 - "$REQ_MAP" "$META_MAP" "$PROJECT" <<'PYEOF'
import json, sys
from datetime import datetime

req_path, meta_path, project = sys.argv[1:4]

with open(req_path, encoding='utf-8') as f:
    reqs_data = json.load(f)
with open(meta_path, encoding='utf-8') as f:
    meta_data = json.load(f)

reqs = reqs_data.get('requirements', {})
mappings = meta_data.get('mappings', [])

# 索引：req_id -> mapping
proto_by_id = {}
for m in mappings:
    proto_by_id[m['req_id']] = m

# 活跃 REQ（非 deprecated）
active_reqs = {rid: info for rid, info in reqs.items() if info.get('status') != 'deprecated'}
deprecated_reqs = {rid: info for rid, info in reqs.items() if info.get('status') == 'deprecated'}

# 1. REQ 存在但无原型
missing_proto = []
for rid, info in sorted(active_reqs.items()):
    if rid not in proto_by_id:
        missing_proto.append((rid, info))

# 2. 原型存在但 REQ 已 deprecated（或 REQ 已删）
stale_proto = []
for rid, m in sorted(proto_by_id.items()):
    if rid not in reqs:
        stale_proto.append((rid, m, 'REQ_DELETED'))
    elif rid in deprecated_reqs:
        stale_proto.append((rid, m, 'REQ_DEPRECATED'))

# 3. REQ 更新时间晚于原型生成时间
outdated_proto = []
def parse_dt(s):
    if not s: return None
    s = s.strip()
    for fmt in ('%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%d'):
        try:
            return datetime.strptime(s[:19], fmt[:19] if 'T' in s else fmt)
        except Exception:
            continue
    return None

for rid, info in sorted(active_reqs.items()):
    if rid not in proto_by_id:
        continue
    m = proto_by_id[rid]
    req_upd = parse_dt(info.get('updated', ''))
    proto_gen = parse_dt(m.get('generated_at', ''))
    if req_upd and proto_gen and req_upd > proto_gen:
        outdated_proto.append((rid, info, m, req_upd, proto_gen))

print("=" * 72)
print(f"  原型 vs 需求 差异报告 - {project}")
print("=" * 72)
print(f"  活跃 REQ      : {len(active_reqs)}")
print(f"  原型映射      : {len(mappings)}")
print(f"  Deprecated REQ: {len(deprecated_reqs)}")
print()

# Section 1
print("─" * 72)
print(f"❶ 缺原型的 REQ ({len(missing_proto)} 条)")
print("─" * 72)
if missing_proto:
    print(f"{'REQ ID':22s} {'角色':16s} {'阶段':8s} {'标题'}")
    for rid, info in missing_proto[:60]:
        role = (info.get('role') or '-')[:14]
        phase = (info.get('phase') or '-')[:6]
        title = info.get('title') or ''
        print(f"  {rid:20s} {role:16s} {phase:8s} {title}")
    if len(missing_proto) > 60:
        print(f"  ... 还有 {len(missing_proto)-60} 条")
    # 建议命令
    print()
    print("  💡 建议命令（按角色批量生成）:")
    roles = sorted({info.get('role','') for _, info in missing_proto if info.get('role')})
    for r in roles:
        cnt = sum(1 for _, i in missing_proto if i.get('role')==r)
        print(f"     bash skills/prototype-design/scripts/generate.sh wireframe {project} --role \"{r}\"   # {cnt} 条")
else:
    print("  ✅ 所有活跃 REQ 都已有原型")
print()

# Section 2
print("─" * 72)
print(f"❷ 应归档的原型 ({len(stale_proto)} 条 - REQ 已 deprecated 或不存在)")
print("─" * 72)
if stale_proto:
    for rid, m, reason in stale_proto[:40]:
        files = ', '.join(m.get('files', []))
        print(f"  [{reason:18s}] {rid:20s} {files}")
    if len(stale_proto) > 40:
        print(f"  ... 还有 {len(stale_proto)-40} 条")
    print()
    print("  💡 建议：手动确认后删除或迁移至 prototype/_archive/")
else:
    print("  ✅ 无过期原型")
print()

# Section 3
print("─" * 72)
print(f"❸ 可能过时的原型 ({len(outdated_proto)} 条 - REQ.updated > 原型 generated_at)")
print("─" * 72)
if outdated_proto:
    for rid, info, m, ru, pg in outdated_proto[:30]:
        title = (info.get('title') or '')[:40]
        print(f"  {rid:20s} REQ={ru.date()} > Proto={pg.date()}  {title}")
    if len(outdated_proto) > 30:
        print(f"  ... 还有 {len(outdated_proto)-30} 条")
    print()
    print("  💡 建议：跑 generate.sh 时显式 --req <ID> 重新生成（或先确认变更内容）")
else:
    print("  ✅ 无过时原型")
print()

# 汇总
print("=" * 72)
diff_total = len(missing_proto) + len(stale_proto) + len(outdated_proto)
if diff_total == 0:
    print(f"✅ 完美：无差异")
    sys.exit(0)
else:
    print(f"⚠️  共 {diff_total} 项差异（缺原型 {len(missing_proto)} + 过期 {len(stale_proto)} + 可能过时 {len(outdated_proto)}）")
    sys.exit(1)
PYEOF
