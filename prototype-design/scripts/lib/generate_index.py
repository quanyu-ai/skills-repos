#!/usr/bin/env python3
"""generate_index.py — render docs-repos/<project>/prototype/index.html
from requirements + prototype meta + versions + index-config.

Driven by env vars set by generate-index.sh:
  GENINDEX_PROJECT, GENINDEX_PROJECT_DIR, GENINDEX_REQ_MAP,
  GENINDEX_PROTO_META, GENINDEX_VERSIONS, GENINDEX_CONFIG,
  GENINDEX_CONFIG_TEMPLATE, GENINDEX_OUT
"""
import html
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

# --- env ---
PROJECT = os.environ["GENINDEX_PROJECT"]
PROJECT_DIR = Path(os.environ["GENINDEX_PROJECT_DIR"])
REQ_MAP_FILE = Path(os.environ["GENINDEX_REQ_MAP"])
PROTO_META_FILE = Path(os.environ["GENINDEX_PROTO_META"])
VERSIONS_FILE = Path(os.environ.get("GENINDEX_VERSIONS", "")) if os.environ.get("GENINDEX_VERSIONS") else None
CONFIG_FILE = Path(os.environ.get("GENINDEX_CONFIG", "")) if os.environ.get("GENINDEX_CONFIG") else None
CONFIG_TEMPLATE = Path(os.environ["GENINDEX_CONFIG_TEMPLATE"])
OUT_FILE = Path(os.environ["GENINDEX_OUT"])

DEFAULT_ACCENT_BG = {
    "gray": "bg-gray-50 border-gray-300",
    "slate": "bg-slate-50 border-slate-300",
    "zinc": "bg-zinc-50 border-zinc-300",
    "stone": "bg-stone-50 border-stone-300",
    "neutral": "bg-neutral-50 border-neutral-300",
    "blue": "bg-blue-50 border-blue-200",
    "green": "bg-green-50 border-green-200",
    "purple": "bg-purple-50 border-purple-200",
}
ROLE_BG_CYCLE = [
    "bg-slate-50 border-slate-300",
    "bg-zinc-50 border-zinc-300",
    "bg-stone-50 border-stone-300",
    "bg-neutral-50 border-neutral-300",
    "bg-gray-50 border-gray-300",
    "bg-slate-100 border-slate-400",
    "bg-zinc-100 border-zinc-400",
]

STATUS_COLOR = {
    "implementing": ("绿", "#16a34a", "#dcfce7"),
    "draft":        ("灰", "#6b7280", "#f3f4f6"),
    "approved":     ("蓝", "#2563eb", "#dbeafe"),
    "reviewing":    ("黄", "#ca8a04", "#fef9c3"),
    "deprecated":   ("红", "#dc2626", "#fee2e2"),
    "done":         ("绿", "#15803d", "#dcfce7"),
}

# --- helpers ---
def load_json(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))

def load_config():
    tmpl = load_json(CONFIG_TEMPLATE)
    if CONFIG_FILE and CONFIG_FILE.is_file():
        user = load_json(CONFIG_FILE)
        # shallow merge with template default
        merged = dict(tmpl)
        for k, v in user.items():
            merged[k] = v
        # display_name 模板里是 {{PROJECT}} 占位，若用户没改则替换
        if merged.get("display_name") == "{{PROJECT}}":
            merged["display_name"] = PROJECT
        return merged
    cfg = dict(tmpl)
    cfg["display_name"] = PROJECT
    return cfg

def extract_one_line_desc(req_id, req_record):
    """Try to read first non-empty paragraph from REQ markdown for short desc."""
    file_rel = req_record.get("file", "")
    if not file_rel:
        return ""
    # file is workspace-relative path like docs-repos/.../REQ-xxx.md
    p = PROJECT_DIR.parent.parent / file_rel
    if not p.is_file():
        return ""
    try:
        text = p.read_text(encoding="utf-8")
    except Exception:
        return ""
    # strip frontmatter
    m = re.match(r"^---\n.*?\n---\n", text, re.S)
    if m:
        text = text[m.end():]
    # find first H2/H3 段后的第一行非空文本，或第一段文本
    for line in text.splitlines():
        s = line.strip()
        if not s: continue
        if s.startswith("#"): continue
        if s.startswith("- ") or s.startswith("* "):
            return s.lstrip("-*").strip()[:40]
        return s[:40]
    return ""

def role_dir_of(file_path):
    # modules/01-leader/foo.html -> 01-leader
    parts = file_path.split("/")
    if len(parts) >= 2 and parts[0] == "modules":
        return parts[1]
    return ""

def human_status(s):
    return STATUS_COLOR.get(s, ("灰", "#6b7280", "#f3f4f6"))

def esc(s):
    return html.escape(str(s) if s is not None else "")

# --- main render ---
def main():
    req_map = load_json(REQ_MAP_FILE)
    proto_meta = load_json(PROTO_META_FILE)
    versions = None
    if VERSIONS_FILE and VERSIONS_FILE.is_file():
        try:
            versions = load_json(VERSIONS_FILE)
        except Exception:
            versions = None
    cfg = load_config()

    stats = req_map.get("stats", {})
    total_req = int(stats.get("total", 0))
    by_status = stats.get("by_status", {})
    by_role_req = stats.get("by_role", {})

    requirements = req_map.get("requirements", {})
    exclude_deprecated = cfg.get("exclude_deprecated_reqs", True)
    exclude_dirs = set(cfg.get("exclude_dirs") or [])
    role_aliases = dict(cfg.get("role_aliases") or {})

    # Build cards: role -> [ {file, title, desc, status, basename} ]
    role_cards = defaultdict(list)
    seen_files = set()
    for entry in proto_meta.get("mappings", []):
        req_id = entry.get("req_id", "")
        req = requirements.get(req_id, {})
        status = req.get("status", "draft")
        if exclude_deprecated and status == "deprecated":
            continue
        role = entry.get("role") or req.get("role") or "其他"
        role = role_aliases.get(role, role)
        # title 优先 mapping 自带，否则 req 标题
        raw_title = entry.get("title") or req.get("title") or req_id
        # 去掉"角色-"前缀，让卡片更简洁
        title = re.sub(r"^[^-]{1,8}-", "", raw_title)
        files = entry.get("files") or []
        for f in files:
            if not f or f in seen_files:
                continue
            # exclude_dirs 过滤（按路径包含）
            if any(d and d in f for d in exclude_dirs):
                continue
            seen_files.add(f)
            desc = extract_one_line_desc(req_id, req) if req else ""
            role_cards[role].append({
                "file": f,
                "title": title,
                "desc": desc,
                "status": status,
                "req_id": req_id,
                "basename": f.rsplit("/", 1)[-1],
            })

    # 角色排序
    order = list(cfg.get("role_order") or [])
    icons = dict(cfg.get("role_icons") or {})
    default_icon = icons.get("默认", "📄")
    role_dir_map = dict(cfg.get("role_dir_map") or {})

    ordered_roles = []
    for r in order:
        if r in role_cards:
            ordered_roles.append(r)
    # 追加未在 order 中但有内容的角色
    for r in sorted(role_cards.keys()):
        if r not in ordered_roles:
            ordered_roles.append(r)

    total_proto = sum(len(v) for v in role_cards.values())

    # 状态分布迷你统计
    status_parts = []
    for s, n in sorted(by_status.items(), key=lambda x: -x[1]):
        _, fg, bg = human_status(s)
        status_parts.append(f'<span class="inline-block px-2 py-0.5 rounded text-xs mr-1 mb-1" style="background:{bg};color:{fg}">{esc(s)} {n}</span>')
    status_html = "".join(status_parts) or '<span class="text-gray-400 text-xs">—</span>'

    # 当前版本
    current_ver = "current"
    if versions and versions.get("versions"):
        for v in versions["versions"]:
            if v.get("is_current"):
                current_ver = v.get("version", "current")
                break
    elif versions and versions.get("current"):
        current_ver = versions.get("current") or "current"

    # 角色 slug 映射：优先取目录名（更稳定），fallback 到序号
    def role_slug(role_name, default_idx):
        d = role_dir_map.get(role_name, "")
        if not d and role_cards.get(role_name):
            d = role_dir_of(role_cards[role_name][0]["file"])
        if d:
            # 01-leader -> leader
            m = re.match(r"^\d+-(.+)$", d)
            return m.group(1) if m else d
        return f"role-{default_idx}"

    # 顶部导航
    nav_parts = []
    for r in ordered_roles:
        n = len(role_cards[r])
        anchor = role_slug(r, ordered_roles.index(r))
        ic = icons.get(r, default_icon)
        nav_parts.append(
            f'<a class="toc-link text-gray-600 hover:text-black" href="#{anchor}">{ic} {esc(r)}'
            f'<span class="ml-1 text-gray-400">({n})</span></a>'
        )
    nav_html = ' · '.join(nav_parts)

    # 角色块
    sections = []
    for idx, r in enumerate(ordered_roles):
        cards = role_cards[r]
        anchor = role_slug(r, idx)
        ic = icons.get(r, default_icon)
        dir_hint = role_dir_map.get(r, "")
        if not dir_hint and cards:
            dir_hint = role_dir_of(cards[0]["file"])
        bg = ROLE_BG_CYCLE[idx % len(ROLE_BG_CYCLE)]
        card_html_parts = []
        for c in cards:
            _, fg, bgc = human_status(c["status"])
            desc_html = ""
            if c["desc"]:
                desc_html = f'<div class="text-xs text-gray-500 mt-1 leading-relaxed line-clamp-2">{esc(c["desc"])}</div>'
            card_html_parts.append(
                f'<a href="{esc(c["file"])}" class="page-card block border border-gray-300 bg-white px-4 py-3 rounded-sm">'
                f'<div class="flex items-start justify-between gap-2">'
                f'<div class="text-sm font-medium text-gray-900 flex-1">{esc(c["title"])}</div>'
                f'<span class="text-[10px] px-1.5 py-0.5 rounded shrink-0" style="background:{bgc};color:{fg}">{esc(c["status"])}</span>'
                f'</div>'
                f'{desc_html}'
                f'<div class="text-[10px] text-gray-400 mt-2 font-mono truncate" title="{esc(c["req_id"])}">{esc(c["basename"])}</div>'
                f'</a>'
            )
        sections.append(
            f'<section id="{anchor}" class="role-section {bg} border rounded-md p-5">'
            f'<header class="flex items-baseline justify-between mb-4 pb-3 border-b border-gray-300">'
            f'<h2 class="text-lg font-semibold tracking-wide"><span class="text-xl mr-2">{ic}</span>{esc(r)}'
            f'<span class="ml-2 text-xs text-gray-500 font-normal">{esc(dir_hint)}/</span></h2>'
            f'<span class="text-xs text-gray-500">共 {len(cards)} 页</span>'
            f'</header>'
            f'<div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">'
            + "".join(card_html_parts) +
            f'</div></section>'
        )
    sections_html = "\n".join(sections)

    # footer links
    footer_parts = []
    for link in cfg.get("footer_links") or []:
        url = (link.get("url") or "").strip()
        label = link.get("label") or url
        if not url:
            continue
        footer_parts.append(
            f'<a href="{esc(url)}" class="underline hover:text-gray-900">{esc(label)}</a>'
        )
    footer_html = " · ".join(footer_parts) or '<span class="text-gray-400">无</span>'

    display_name = cfg.get("display_name") or PROJECT
    slogan = cfg.get("slogan") or ""
    n_roles = len(ordered_roles)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    html_out = HTML_TEMPLATE.format(
        title=esc(display_name),
        display_name=esc(display_name),
        slogan=esc(slogan),
        total_req=total_req,
        total_proto=total_proto,
        n_roles=n_roles,
        status_html=status_html,
        current_ver=esc(current_ver),
        nav_html=nav_html,
        sections_html=sections_html,
        footer_html=footer_html,
        now=now,
        project=esc(PROJECT),
    )

    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text(html_out, encoding="utf-8")
    print(f"[generate_index] wrote {OUT_FILE} ({len(html_out)} bytes)")
    print(f"[generate_index] total_req={total_req} total_proto={total_proto} roles={n_roles}")


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>{title} · 项目门户</title>
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="_shared/styles.css">
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }}
  .page-card {{ transition: all .15s ease; }}
  .page-card:hover {{ transform: translateY(-2px); box-shadow: 0 4px 12px rgba(0,0,0,.08); border-color: #555; }}
  .role-section {{ scroll-margin-top: 80px; }}
  .toc-link {{ transition: color .15s ease; }}
  .toc-link:hover {{ color: #000; }}
  .line-clamp-2 {{ display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }}
</style>
</head>
<body class="bg-white text-gray-900">

<!-- 版本切换器（自动从 meta/versions.json 加载） -->
<div id="version-switcher" style="position:fixed;top:8px;right:8px;z-index:9999;background:#fff;border:1px solid #d1d5db;padding:4px 10px;font-size:12px;border-radius:2px;box-shadow:0 1px 3px rgba(0,0,0,.06);">
  <span style="color:#6b7280;">版本：</span>
  <select id="version-select" style="background:#fff;border:0;color:#374151;font-size:12px;outline:none;cursor:pointer;" onchange="(function(v){{if(v==='current'){{location.href=(window.__VS_BASE__||'/')+'';}}else{{location.href=(window.__VS_BASE__||'/')+'archive/'+v+'/index.html';}}}})(this.value)">
    <option value="current">当前版本</option>
  </select>
</div>
<script>
(function(){{
  var p = location.pathname;
  var m = p.match(/^(.*?)\/archive\/[^\/]+\//);
  window.__VS_BASE__ = m ? (m[1] + '/') : '/';
  fetch(window.__VS_BASE__ + 'meta/versions.json').then(function(r){{return r.ok?r.json():null;}}).then(function(data){{
    if(!data || !data.versions) return;
    var sel = document.getElementById('version-select');
    if(!sel) return;
    var curArchive = p.match(/\/archive\/([^\/]+)\//);
    var curVer = curArchive ? curArchive[1] : 'current';
    data.versions.slice().filter(function(v){{return !v.is_current;}}).sort(function(a,b){{return (a.version<b.version)?1:-1;}}).forEach(function(v){{
      var opt = document.createElement('option');
      opt.value = v.version;
      opt.textContent = v.label ? v.label : ('历史版本 ' + v.version);
      sel.appendChild(opt);
    }});
    sel.value = curVer;
  }}).catch(function(){{}});
}})();
</script>

<header class="border-b border-gray-300 bg-white sticky top-0 z-10">
  <div class="max-w-6xl mx-auto px-6 py-5">
    <div class="flex items-baseline justify-between flex-wrap gap-3">
      <div>
        <h1 class="text-2xl font-bold tracking-wide">{display_name} · 原型门户</h1>
        <p class="text-sm text-gray-500 mt-1">
          <span data-stat-total-req="{total_req}">总需求 <strong class="text-gray-900">{total_req}</strong></span>
          ·
          <span>总原型 <strong class="text-gray-900">{total_proto}</strong></span>
          ·
          <span><strong class="text-gray-900">{n_roles}</strong> 角色全覆盖</span>
          <span class="ml-2 text-gray-400">{slogan}</span>
        </p>
      </div>
      <nav class="text-xs text-gray-500 space-x-2 flex flex-wrap gap-y-1">{nav_html}</nav>
    </div>
  </div>
</header>

<main class="max-w-6xl mx-auto px-6 py-8 space-y-6">

<!-- 顶部统计卡片 -->
<section class="grid grid-cols-2 md:grid-cols-4 gap-3">
  <div class="border border-green-200 bg-green-50 rounded-md p-4">
    <div class="text-xs text-green-700">总需求数</div>
    <div class="text-2xl font-bold text-green-800 mt-1">{total_req}</div>
  </div>
  <div class="border border-blue-200 bg-blue-50 rounded-md p-4">
    <div class="text-xs text-blue-700">总原型数</div>
    <div class="text-2xl font-bold text-blue-800 mt-1">{total_proto}</div>
  </div>
  <div class="border border-gray-200 bg-gray-50 rounded-md p-4">
    <div class="text-xs text-gray-700 mb-1">状态分布</div>
    <div class="leading-tight">{status_html}</div>
  </div>
  <div class="border border-purple-200 bg-purple-50 rounded-md p-4">
    <div class="text-xs text-purple-700">当前版本</div>
    <div class="text-2xl font-bold text-purple-800 mt-1">{current_ver}</div>
  </div>
</section>

{sections_html}

</main>

<footer class="border-t border-gray-300 mt-12 bg-gray-50">
  <div class="max-w-6xl mx-auto px-6 py-6 text-xs text-gray-500 flex flex-wrap items-center justify-between gap-2">
    <div>
      <span>项目 <code class="text-gray-700">{project}</code></span>
      <span class="mx-2">·</span>
      <span>生成时间 {now}</span>
      <span class="mx-2">·</span>
      <span>by skills/prototype-design/scripts/generate-index.sh</span>
    </div>
    <div class="space-x-3">{footer_html}</div>
  </div>
</footer>
</body>
</html>
"""


if __name__ == "__main__":
    main()
