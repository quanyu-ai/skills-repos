#!/usr/bin/env python3
# render_mapping.py — generate <project>/prototype/mapping.html
# Inputs (env): REQ_MAP_PATH, PROTO_META_PATH, OUT_PATH, PROJECT_NAME
import json, os, html, datetime, sys, pathlib

REQ_MAP_PATH    = os.environ["REQ_MAP_PATH"]
PROTO_META_PATH = os.environ["PROTO_META_PATH"]
OUT_PATH        = os.environ["OUT_PATH"]
PROJECT_NAME    = os.environ.get("PROJECT_NAME","project")

with open(REQ_MAP_PATH,encoding="utf-8") as f: req_map = json.load(f)
with open(PROTO_META_PATH,encoding="utf-8") as f: proto_meta = json.load(f)

requirements = req_map.get("requirements",{}) or {}
proto_index = {}
for m in (proto_meta.get("mappings") or []):
    rid = m.get("req_id")
    if rid: proto_index[rid] = m

# merge
rows = []
for rid, req in requirements.items():
    p = proto_index.get(rid, {})
    files = p.get("files") or []
    rows.append({
        "id": rid,
        "title": req.get("title","-"),
        "status": req.get("status","draft"),
        "phase": req.get("phase","-"),
        "priority": req.get("priority","-"),
        "role": req.get("role","-"),
        "source_doc": req.get("source_doc",""),
        "source_section": req.get("source_section",""),
        "files": files,
        "mapped": bool(files),
    })

# stats
total = len(rows)
mapped = sum(1 for r in rows if r["mapped"])
def count_by(key):
    d = {}
    for r in rows: d[r[key]] = d.get(r[key],0)+1
    return d
status_dist   = count_by("status")
phase_dist    = count_by("phase")
priority_dist = count_by("priority")
role_dist     = count_by("role")

ROLE_ORDER = ["学院领导","教师","辅导员/班主任","学生","校友","系统管理员"]
def role_sort_key(r):
    role = r
    return (ROLE_ORDER.index(role) if role in ROLE_ORDER else 99, role)

# group by role
roles_seen = []
for r in rows:
    if r["role"] not in roles_seen: roles_seen.append(r["role"])
roles_sorted = sorted(roles_seen, key=role_sort_key)

STATUS_STYLE = {
    "draft":         ("bg-gray-100 text-gray-600",     "草稿"),
    "reviewing":     ("bg-yellow-50 text-yellow-700",  "评审中"),
    "approved":      ("bg-blue-50 text-blue-700",      "已批准"),
    "implementing":  ("bg-green-100 text-green-700",   "实施中"),
    "done":          ("bg-emerald-200 text-emerald-800","已完成"),
    "deprecated":    ("bg-red-50 text-red-700 line-through","已废弃"),
}
PRIORITY_STYLE = {
    "P0": "bg-red-50 text-red-700 border border-red-200",
    "P1": "bg-amber-50 text-amber-700 border border-amber-200",
    "P2": "bg-gray-50 text-gray-600 border border-gray-200",
}
PHASE_STYLE = {
    "一阶段": "bg-sky-50 text-sky-700 border border-sky-200",
    "二阶段": "bg-violet-50 text-violet-700 border border-violet-200",
}
ROLE_ANCHOR = {
    "学院领导":"role-leader","教师":"role-teacher",
    "辅导员/班主任":"role-counselor","学生":"role-student",
    "校友":"role-alumni","系统管理员":"role-admin",
}
def anchor_of(role): return ROLE_ANCHOR.get(role, "role-" + role.replace("/","-"))

def esc(s): return html.escape(str(s) if s is not None else "")

def status_badge(s):
    cls, label = STATUS_STYLE.get(s, ("bg-gray-100 text-gray-600", s))
    return f'<span class="inline-block px-2 py-0.5 rounded-sm text-[11px] font-medium {cls}">{esc(s)}</span>'

def priority_badge(p):
    cls = PRIORITY_STYLE.get(p, "bg-gray-50 text-gray-600 border border-gray-200")
    return f'<span class="inline-block px-1.5 py-0.5 rounded-sm text-[11px] font-mono {cls}">{esc(p)}</span>'

def phase_badge(ph):
    cls = PHASE_STYLE.get(ph, "bg-gray-50 text-gray-600 border border-gray-200")
    return f'<span class="inline-block px-1.5 py-0.5 rounded-sm text-[11px] {cls}">{esc(ph)}</span>'

def files_link(files):
    if not files: return '<span class="text-gray-400 text-xs">—</span>'
    parts = []
    for f in files:
        parts.append(f'<a href="{esc(f)}" class="text-xs text-blue-600 hover:text-blue-800 hover:underline font-mono break-all">{esc(f)}</a>')
    return '<div class="space-y-0.5">' + "".join(parts) + '</div>'


# build HTML
gen_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def stat_card(label, value, accent="text-gray-900"):
    return f'''<div class="border border-gray-300 rounded-sm bg-white px-4 py-3">
  <div class="text-[11px] text-gray-500 tracking-wide uppercase">{esc(label)}</div>
  <div class="text-2xl font-semibold mt-1 {accent}">{esc(value)}</div>
</div>'''

def dist_block(title, dist, badge_fn=None):
    items = []
    for k, v in sorted(dist.items(), key=lambda kv: (-kv[1], str(kv[0]))):
        if badge_fn:
            tag = badge_fn(k)
        else:
            tag = f'<span class="text-xs text-gray-700">{esc(k)}</span>'
        items.append(f'<div class="flex items-center justify-between border-b border-gray-200 py-1.5 last:border-b-0">{tag}<span class="text-xs font-mono text-gray-900">{v}</span></div>')
    return f'''<div class="border border-gray-300 rounded-sm bg-white px-4 py-3">
  <div class="text-[11px] text-gray-500 tracking-wide uppercase mb-2">{esc(title)}</div>
  <div>{"".join(items) if items else '<div class="text-xs text-gray-400">无数据</div>'}</div>
</div>'''

# nav top
nav_parts = []
for role in roles_sorted:
    count = role_dist.get(role, 0)
    nav_parts.append(
        f'<a class="text-xs text-gray-600 hover:text-black underline-offset-2 hover:underline" href="#{anchor_of(role)}">{esc(role)}<span class="ml-1 text-gray-400">({count})</span></a>'
    )
top_nav = " · ".join(nav_parts)

# stats cards
stats_html = f'''
<section class="mb-8">
  <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
    {stat_card("总需求数", total)}
    {stat_card("已映射原型", f"{mapped} / {total}", accent="text-green-700")}
    {stat_card("覆盖率", (f"{(mapped*100//total)}%" if total else "—"), accent="text-emerald-700")}
    {stat_card("角色数量", len(roles_sorted))}
  </div>
  <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3">
    {dist_block("状态分布", status_dist, status_badge)}
    {dist_block("阶段分布", phase_dist, phase_badge)}
    {dist_block("优先级分布", priority_dist, priority_badge)}
    {dist_block("角色分布", role_dist)}
  </div>
</section>
'''

# tables per role
tables_html = []
for role in roles_sorted:
    role_rows = sorted([r for r in rows if r["role"] == role], key=lambda x: x["id"])
    count = len(role_rows)
    role_mapped = sum(1 for r in role_rows if r["mapped"])
    trs = []
    for r in role_rows:
        title_cell = f'<div class="font-medium text-gray-900">{esc(r["title"])}</div>'
        if r["source_section"] or r["source_doc"]:
            src = f'{esc(r.get("source_section",""))}'
            if r.get("source_doc"):
                src = f'{esc(r["source_section"])} · {esc(r["source_doc"])}' if r["source_section"] else esc(r["source_doc"])
        else:
            src = "—"
        trs.append(f'''<tr class="border-t border-gray-300 hover:bg-gray-50">
  <td class="px-3 py-2 align-top font-mono text-xs text-gray-700 whitespace-nowrap">{esc(r["id"])}</td>
  <td class="px-3 py-2 align-top">{title_cell}</td>
  <td class="px-3 py-2 align-top whitespace-nowrap">{priority_badge(r["priority"])}</td>
  <td class="px-3 py-2 align-top whitespace-nowrap">{phase_badge(r["phase"])}</td>
  <td class="px-3 py-2 align-top whitespace-nowrap">{status_badge(r["status"])}</td>
  <td class="px-3 py-2 align-top">{files_link(r["files"])}</td>
  <td class="px-3 py-2 align-top text-xs text-gray-500">{src}</td>
</tr>''')
    tables_html.append(f'''
<section id="{anchor_of(role)}" class="mb-10 scroll-mt-16">
  <header class="flex items-baseline justify-between mb-3 pb-2 border-b border-gray-400">
    <h2 class="text-lg font-semibold tracking-wide">{esc(role)}</h2>
    <div class="text-xs text-gray-500">共 {count} 条需求 · 已映射 {role_mapped} / {count}</div>
  </header>
  <div class="overflow-x-auto border border-gray-300 rounded-sm bg-white">
    <table class="min-w-full text-sm">
      <thead class="bg-gray-50 text-gray-600 text-xs uppercase tracking-wide">
        <tr>
          <th class="px-3 py-2 text-left font-medium">REQ ID</th>
          <th class="px-3 py-2 text-left font-medium">标题</th>
          <th class="px-3 py-2 text-left font-medium">优先级</th>
          <th class="px-3 py-2 text-left font-medium">阶段</th>
          <th class="px-3 py-2 text-left font-medium">状态</th>
          <th class="px-3 py-2 text-left font-medium">原型链接</th>
          <th class="px-3 py-2 text-left font-medium">来源章节</th>
        </tr>
      </thead>
      <tbody class="text-gray-800">{"".join(trs)}</tbody>
    </table>
  </div>
</section>''')

content_html = stats_html + "".join(tables_html)

doc = f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(PROJECT_NAME)} · 需求-原型映射可视化</title>
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="_shared/styles.css">
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; }}
  .scroll-mt-16 {{ scroll-margin-top: 4rem; }}
</style>
</head>
<body class="bg-white text-gray-900">
<header class="border-b border-gray-300 bg-white sticky top-0 z-10">
  <div class="max-w-6xl mx-auto px-6 py-4">
    <div class="flex items-baseline justify-between flex-wrap gap-2">
      <div>
        <h1 class="text-xl font-bold tracking-wide">{esc(PROJECT_NAME)} · 需求-原型映射可视化</h1>
        <p class="text-xs text-gray-500 mt-1">REQ ↔ Prototype 全景对照表 · 共 {total} 条需求 / 已映射 {mapped} 条</p>
      </div>
      <nav class="text-xs space-x-2 max-w-3xl text-right">{top_nav}</nav>
    </div>
  </div>
</header>
<main class="max-w-6xl mx-auto px-6 py-6">
{content_html}
</main>
<footer class="border-t border-gray-300 mt-8 bg-gray-50">
  <div class="max-w-6xl mx-auto px-6 py-4 text-xs text-gray-500 flex flex-wrap items-center justify-between gap-2">
    <div>生成时间 {gen_time} · 数据来源：requirements/requirements-map.json + prototype/meta/requirements-map.json</div>
    <div><a href="./" class="underline hover:text-gray-900">← 返回总览</a></div>
  </div>
</footer>
</body>
</html>
'''

pathlib.Path(OUT_PATH).parent.mkdir(parents=True, exist_ok=True)
with open(OUT_PATH,"w",encoding="utf-8") as f: f.write(doc)

# stdout summary
print(f"[render_mapping] wrote {OUT_PATH}")
print(f"[render_mapping] requirements={total}, mapped={mapped}, roles={len(roles_sorted)}")
print(f"[render_mapping] status_dist={status_dist}")
print(f"[render_mapping] phase_dist={phase_dist}")
print(f"[render_mapping] priority_dist={priority_dist}")
print(f"[render_mapping] role_dist={role_dist}")
