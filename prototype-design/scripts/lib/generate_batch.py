#!/usr/bin/env python3
"""generate_batch.py - Phase 2 批量生成原型 HTML（被 generate.sh 调用）"""
import os, sys, re, json, subprocess
from pathlib import Path
from datetime import datetime

# 从环境变量读取参数
STYLE = os.environ['GEN_STYLE']
PROJECT = os.environ['GEN_PROJECT']
DRY_RUN = os.environ['GEN_DRY_RUN'] == 'yes'
F_ROLE = os.environ.get('GEN_FILTER_ROLE', '')
F_REQ = os.environ.get('GEN_FILTER_REQ', '')
F_PHASE = os.environ.get('GEN_FILTER_PHASE', '')
REQ_MAP = Path(os.environ['GEN_REQ_MAP'])
PROTOTYPE_DIR = Path(os.environ['GEN_PROTOTYPE_DIR'])
PROJECT_DOCS = Path(os.environ['GEN_PROJECT_DOCS'])
BASE_TEMPLATE = Path(os.environ['GEN_BASE_TEMPLATE'])
BUSINESS_DIR = Path(os.environ['GEN_BUSINESS_DIR'])
WORKSPACE_ROOT = Path(os.environ['GEN_WORKSPACE_ROOT'])
SKILL_DIR = Path(os.environ['GEN_SKILL_DIR'])
BACK_REF = SKILL_DIR / 'scripts' / 'lib' / 'back_ref.py'

# 角色 -> 模块目录名
ROLE_TO_DIR = {
    '学院领导': '01-leader',
    '教师': '02-teacher',
    '辅导员': '03-counselor',
    '辅导员/班主任': '03-counselor',
    '学生': '04-student',
    '校友': '05-alumni',
    '系统管理员': '06-admin',
    '跨角色': '07-shared',
}

def slug_for_module(role, title):
    """从 title 提取英文/简短模块名"""
    # 去掉 "角色-" 前缀
    name = title
    for r in ROLE_TO_DIR.keys():
        if name.startswith(r + '-'):
            name = name[len(r)+1:]
            break
    # 去括号注释
    name = re.sub(r'[（(].*?[)）]', '', name)
    # 翻译关键词
    table = [
        ('个人中心', 'profile'),
        ('工作台', 'workspace'), ('今天页', 'today'),
        ('驾驶舱', 'dashboard'), ('看板', 'dashboard'), ('dashboard', 'dashboard'),
        ('详情', 'detail'), ('查看', 'detail'),
        ('列表', 'list'), ('管理', 'manage'),
        ('表单', 'form'), ('申请', 'apply'), ('上报', 'report'), ('编辑', 'edit'),
        ('审批', 'approval'), ('流程', 'flow'),
        ('日程', 'schedule'), ('督办', 'supervision'),
        ('考核', 'assessment'), ('评教', 'evaluation'),
        ('成果', 'achievement'), ('报表', 'report'),
        ('AI', 'ai'), ('助手', 'assistant'), ('画像', 'profile'),
        ('成长', 'growth'), ('雷达', 'radar'),
        ('就业', 'jobs'), ('双边', 'match'),
        ('心理', 'mental'), ('危机', 'crisis'),
        ('校友', 'alumni'), ('通讯录', 'directory'),
        ('数据', 'data'), ('一张表', 'one-sheet'),
        ('系统', 'system'), ('运行', 'runtime'),
        ('用户', 'user'), ('问题', 'issue'), ('排查', 'troubleshoot'),
        ('排班', 'schedule'), ('提交', 'submit'),
        ('材料', 'material'), ('中心', 'center'),
        ('发布', 'publish'), ('导师', 'mentor'),
        ('活动', 'activity'), ('损赠', 'donation'),
        ('计划', 'plan'), ('巍位', 'jobs'),
        ('预警', 'alert'), ('干预', 'intervention'),
        ('教学', 'teaching'), ('事故', 'incident'),
        ('充补', 'supplement'), ('生成', 'gen'),
        ('眼眼', 'one-glance'), ('看', 'view'),
    ]
    for cn, en in table:
        name = name.replace(cn, en + '-')
        # 只保留 ASCII 字母、数字、连字号和下划线；其余一律转为 -（避免引号、中文引号等協讯字符进文件名）
    name = re.sub(r'[^A-Za-z0-9_-]+', '-', name)
    name = re.sub(r'-+', '-', name).strip('-').lower()
    if not name:
        name = 'page'
    return name[:50]

def pick_template(title):
    """根据 title 关键词选择业务模板"""
    t = title
    # 优先级判断
    if any(k in t for k in ['工作台', '今天页']):
        return 'workspace'
    if any(k in t for k in ['驾驶舱', '看板', 'dashboard', 'Dashboard']):
        return 'dashboard'
    if any(k in t for k in ['详情']):
        return 'detail'
    if any(k in t for k in ['表单', '申请', '上报', '编辑']):
        return 'form'
    if any(k in t for k in ['列表', '管理', '中心', '台账', '档案', '通讯录']):
        return 'list'
    return 'base'

def load_template(tpl_name):
    """加载业务模板 main 区"""
    if tpl_name == 'base':
        return None  # 用 base.html 整体
    p = BUSINESS_DIR / f'{tpl_name}.html'
    if not p.is_file():
        return None
    return p.read_text(encoding='utf-8')

def _collect_role_pages(role, role_dir, role_pages_arg):
    """合并 3 个数据源得到该角色目录下的完整页面列表。
    源 A：本次过滤匹配的 REQ（role_pages_arg：[(filename, title), ...]）
    源 B：扫描 PROTOTYPE_DIR/modules/<role_dir>/*.html
    源 C：meta/requirements-map.json 中 role 等于该角色的所有条目 files
    返回 [(filename, title), ...]，按文件名字母序排序，url 去重。
    """
    # key: filename -> title
    merged = {}
    # 源 A
    for fn, title in (role_pages_arg or []):
        if fn and fn not in merged:
            merged[fn] = title
    # 源 B：扫目录
    dir_path = PROTOTYPE_DIR / 'modules' / role_dir
    if dir_path.is_dir():
        for p in dir_path.iterdir():
            if p.is_file() and p.suffix == '.html':
                merged.setdefault(p.name, p.stem)
    # 源 C：mapping —— 仅用于为已存在 fname 美化 title，不引入未生成的页面（避免 404）
    META_MAP_LOCAL = PROTOTYPE_DIR / 'meta' / 'requirements-map.json'
    if META_MAP_LOCAL.is_file():
        try:
            meta_local = json.loads(META_MAP_LOCAL.read_text(encoding='utf-8'))
            for entry in meta_local.get('mappings', []):
                if entry.get('role') != role:
                    continue
                for rel in entry.get('files', []):
                    if rel.startswith(f'modules/{role_dir}/'):
                        fn = os.path.basename(rel)
                        if fn in merged:
                            merged[fn] = entry.get('title', merged[fn])
        except Exception:
            pass
    # 排序
    return sorted(merged.items(), key=lambda x: x[0])


def render_sidebar(role, role_dir, all_pages, current_file):
    """生成 sidebar HTML，列出该角色所有页面（合并扫目录 + mapping 去重）"""
    full_pages = _collect_role_pages(role, role_dir, all_pages)
    items = []
    for fname, title in full_pages:
        active = (fname == current_file)
        cls = 'sidebar-active block py-2 px-3 bg-gray-100 border border-gray-300 text-gray-900' if active else 'sidebar-inactive block py-2 px-3 text-gray-600 hover:bg-gray-50'
        label = re.sub(r'^.*?-', '', title, count=1) if '-' in title else title
        items.append(f'            <a href="{fname}" class="{cls}">{label}</a>')
    return "\n".join(items)

def get_existing_prototype_files(req_file):
    """从 REQ frontmatter 读取已登记的 related_files.prototype。返回 list[str]"""
    if not req_file.is_file():
        return []
    text = req_file.read_text(encoding='utf-8')
    m = re.match(r'^---\s*\n(.*?)\n---\s*\n', text, re.DOTALL)
    if not m:
        return []
    fm = m.group(1)
    lines = fm.split('\n')
    files = []
    in_proto = False
    base_indent = None
    for line in lines:
        if re.match(r'^\s+prototype:\s*$', line) or re.match(r'^\s+prototype:\s*\[\]\s*$', line):
            in_proto = True
            m2 = re.match(r'^(\s+)prototype:', line)
            base_indent = len(m2.group(1)) if m2 else 0
            continue
        if in_proto:
            m3 = re.match(r'^(\s+)-\s+(.+?)\s*$', line)
            if m3 and len(m3.group(1)) > (base_indent or 0):
                files.append(m3.group(2).strip().strip('"').strip("'"))
                continue
            # 遇到同级或更外层字段，退出
            if re.match(r'^\s*[a-zA-Z_]', line) and 'prototype' not in line:
                in_proto = False
    return files

def compose_page(req_id, title, role, role_dir, all_pages_in_role, current_file):
    """组装最终 HTML：用 base.html 作为外壳，把业务模板填入 main 区"""
    tpl_name = pick_template(title)
    business = load_template(tpl_name)

    base_html = BASE_TEMPLATE.read_text(encoding='utf-8')

    # 简化 title（去角色前缀）
    display_title = title
    if title.startswith(role + '-'):
        display_title = title[len(role)+1:]

    # 替换通用占位
    out = base_html.replace('{{TITLE}}', display_title)
    out = out.replace('{{REQ_ID}}', req_id)
    out = out.replace('{{ROLE}}', role)
    out = out.replace('{{PROJECT}}', PROJECT)
    out = out.replace('{{STYLE}}', STYLE)

    # 重构 <aside> sidebar：替换整个 <nav>...</nav> 内的链接
    sidebar_html = render_sidebar(role, role_dir, all_pages_in_role, current_file)
    nav_pattern = re.compile(r'(<nav class="space-y-2 text-sm">)(.*?)(</nav>)', re.DOTALL)
    def _sub_nav(m):
        return f'{m.group(1)}\n            <div class="text-gray-500 text-xs uppercase mb-2">{role} 菜单</div>\n{sidebar_html}\n        {m.group(3)}'
    out, n_sub = nav_pattern.subn(_sub_nav, out, count=1)
    if n_sub == 0:
        # fallback：尝试匹配现 base.html 中的 <nav> 块
        pass

    # 替换 <main> 区内容（如果有业务模板）
    if business:
        # 把业务模板自身的占位先替换
        b = business.replace('{{TITLE}}', display_title)
        b = b.replace('{{REQ_ID}}', req_id)
        b = b.replace('{{ROLE}}', role)
        b = b.replace('{{PROJECT}}', PROJECT)
        b = b.replace('{{STYLE}}', STYLE)
        # 替换 base.html 中 <main>...</main> 的内容
        main_pattern = re.compile(r'(<main class="flex-1 p-6">)(.*?)(</main>)', re.DOTALL)
        def _sub_main(m):
            # 保留 breadcrumb，更换正文
            breadcrumb = f'<div class="wireframe-breadcrumb text-sm text-gray-500 mb-4">首页 → {role} → {display_title}</div>'
            return f'{m.group(1)}\n        {breadcrumb}\n{b}\n    {m.group(3)}'
        out, n_main = main_pattern.subn(_sub_main, out, count=1)
        if n_main == 0:
            print(f"WARN: <main> 块未匹配，REQ {req_id} 退化为 base 占位", file=sys.stderr)

    return out, tpl_name

def main():
    if not REQ_MAP.is_file():
        print(f"ERROR: {REQ_MAP} not found", file=sys.stderr)
        sys.exit(1)

    data = json.loads(REQ_MAP.read_text(encoding='utf-8'))
    reqs = data.get('requirements', {})

    # 过滤
    matched = []
    for rid, info in reqs.items():
        if F_REQ and rid != F_REQ:
            continue
        if F_ROLE and info.get('role', '') != F_ROLE:
            continue
        if F_PHASE and info.get('phase', '') != F_PHASE:
            continue
        # 跳过 deprecated
        if info.get('status') == 'deprecated':
            continue
        matched.append((rid, info))

    matched.sort(key=lambda x: x[0])
    print(f"[generate] 风格: {STYLE}  项目: {PROJECT}  匹配需求: {len(matched)} 条")

    if not matched:
        print("WARN: 过滤后无匹配需求")
        sys.exit(0)

    # 预计算每个角色下所有页面名（按已匹配 REQ 算）
    role_pages = {}  # role_dir -> [(filename, title), ...]
    plan = []  # [(rid, info, role_dir, filename, tpl_name)]
    for rid, info in matched:
        role = info.get('role') or '跨角色'
        role_dir = ROLE_TO_DIR.get(role, '07-shared')
        # 优先从 REQ frontmatter 读已登记的原型文件名
        req_file = PROJECT_DOCS / 'requirements' / f'{rid}.md'
        existing = get_existing_prototype_files(req_file)
        # 取第一个指向本角色目录的
        reuse_fn = None
        for p in existing:
            if p.startswith(f'modules/{role_dir}/'):
                reuse_fn = os.path.basename(p)
                break
        if reuse_fn:
            filename = reuse_fn
        else:
            slug = slug_for_module(role, info.get('title', rid))
            filename = f'{slug}.html'
            # 防同角色 slug 撞
            existing_fn = [p[0] for p in role_pages.get(role_dir, [])]
            if filename in existing_fn:
                filename = f'{slug}-{rid.split("-")[-1]}.html'
        role_pages.setdefault(role_dir, []).append((filename, info.get('title', rid)))
        tpl = pick_template(info.get('title', ''))
        plan.append((rid, info, role_dir, filename, tpl))

    if DRY_RUN:
        print("\n[dry-run] 将生成的需求 (按 角色/文件名):")
        by_role = {}
        for rid, info, rd, fn, tpl in plan:
            by_role.setdefault(rd, []).append((rid, fn, tpl, info.get('title', '')))
        for rd in sorted(by_role.keys()):
            print(f"\n  modules/{rd}/")
            for rid, fn, tpl, title in by_role[rd]:
                print(f"    - {fn:35s}  [{tpl:9s}]  {rid}  {title}")
        print(f"\n[dry-run] 合计 {len(plan)} 个文件")
        sys.exit(0)

    # 真生成
    META_MAP = PROTOTYPE_DIR / 'meta' / 'requirements-map.json'
    if META_MAP.is_file():
        meta = json.loads(META_MAP.read_text(encoding='utf-8'))
    else:
        meta = {"project": PROJECT, "style": STYLE, "updated": "", "mappings": []}

    # 现有 mappings 索引（按 req_id）
    existing_map = {m['req_id']: m for m in meta.get('mappings', [])}

    written = 0
    skipped_existing = 0
    new_files = []
    template_counts = {}
    for rid, info, role_dir, filename, tpl_name in plan:
        title = info.get('title', '')
        role = info.get('role') or '跨角色'
        out_dir = PROTOTYPE_DIR / 'modules' / role_dir
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = out_dir / filename
        rel = f'modules/{role_dir}/{filename}'

        # 保护已有 45 页：如果文件已存在且已在 mapping，则不覆盖（除非 --req 显式指定该 REQ）
        if out_path.exists() and rid in existing_map and not F_REQ:
            skipped_existing += 1
            continue

        html, tpl_used = compose_page(rid, title, role, role_dir, role_pages[role_dir], filename)
        out_path.write_text(html, encoding='utf-8')
        new_files.append(rel)
        template_counts[tpl_used] = template_counts.get(tpl_used, 0) + 1
        written += 1

        # 反向回填
        req_file = PROJECT_DOCS / 'requirements' / f'{rid}.md'
        if req_file.is_file():
            r = subprocess.run(['python3', str(BACK_REF), 'write', str(req_file), rel],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            if r.returncode != 0:
                print(f"WARN: back_ref write failed for {rid}: {r.stderr}", file=sys.stderr)
            # check
            r2 = subprocess.run(['python3', str(BACK_REF), 'check', str(req_file), rel],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            if r2.returncode != 0:
                print(f"ERROR: back_ref check failed for {rid} -> {rel}", file=sys.stderr)
                sys.exit(1)

        # 更新 meta map
        now = datetime.now().isoformat(timespec='seconds')
        if rid in existing_map:
            entry = existing_map[rid]
            if rel not in entry.get('files', []):
                entry.setdefault('files', []).append(rel)
            entry['generated_at'] = now
        else:
            entry = {
                'req_id': rid, 'title': title, 'role': role,
                'files': [rel], 'generated_at': now
            }
            meta['mappings'].append(entry)
            existing_map[rid] = entry

    meta['style'] = STYLE
    meta['updated'] = datetime.now().isoformat(timespec='seconds')
    META_MAP.parent.mkdir(parents=True, exist_ok=True)
    META_MAP.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')

    # revisions.md
    revs = PROTOTYPE_DIR / 'meta' / 'revisions.md'
    with revs.open('a', encoding='utf-8') as fp:
        fp.write(f"\n## {datetime.now().isoformat(timespec='seconds')} - 生成 [{STYLE}] Phase2\n\n")
        fp.write(f"- 过滤: role={F_ROLE}, phase={F_PHASE}, req={F_REQ}\n")
        fp.write(f"- 匹配: {len(matched)} 条  新生成: {written}  跳过已存在: {skipped_existing}\n")
        fp.write(f"- 业务模板分布: {template_counts}\n")

    print(f"[generate] ✅ 完成：新生成 {written}，跳过已存在 {skipped_existing}")
    print(f"[generate] 业务模板分布：{template_counts}")

    # Assertion: meta 中所有过滤后 REQ 都已映射
    target_ids = {rid for rid, _ in matched}
    mapped_ids = {m['req_id'] for m in meta['mappings']}
    missing = target_ids - mapped_ids
    if missing:
        print(f"ERROR: ASSERT FAIL - 以下 REQ 未在 meta map: {sorted(missing)[:5]}...", file=sys.stderr)
        sys.exit(1)
    print(f"[generate] ✅ Assertion OK: meta 中已包含全部 {len(target_ids)} 个过滤后 REQ 映射")

if __name__ == '__main__':
    main()
