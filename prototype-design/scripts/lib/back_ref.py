#!/usr/bin/env python3
"""
back_ref.py - 通用工具：把 prototype 路径回写到 REQ 文件的 frontmatter.related_files.prototype

用法（命令行）：
    python3 back_ref.py write <REQ_FILE> <PROTOTYPE_PATH>
        把 PROTOTYPE_PATH 追加到 REQ_FILE.frontmatter.related_files.prototype
        如果已经在列表中则不重复添加，幂等
        同时更新 updated 字段，并在 history 加一条 prototype_linked 记录
        成功 exit 0；如果写入后验证失败 exit 1

    python3 back_ref.py check <REQ_FILE> <PROTOTYPE_PATH>
        仅检查 REQ_FILE.frontmatter.related_files.prototype 是否包含 PROTOTYPE_PATH
        包含 exit 0；不包含 exit 1

    python3 back_ref.py write-multi <REQ_FILE> <PROTOTYPE_PATH1> [PROTOTYPE_PATH2...]
        批量写多个路径
"""

import sys
import os
import re
import datetime
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML 未安装，请先 pip install pyyaml", file=sys.stderr)
    sys.exit(2)


FRONTMATTER_RE = re.compile(r'^---\s*\n(.*?)\n---\s*\n(.*)$', re.DOTALL)


def parse_req_file(req_file: Path):
    """返回 (frontmatter_dict, body_str)；frontmatter 解析失败抛异常"""
    text = req_file.read_text(encoding='utf-8')
    m = FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError(f"REQ 文件无合法 frontmatter: {req_file}")
    fm_text, body = m.group(1), m.group(2)
    fm = yaml.safe_load(fm_text)
    if not isinstance(fm, dict):
        raise ValueError(f"frontmatter 不是 dict: {req_file}")
    return fm, body


def dump_req_file(req_file: Path, fm: dict, body: str):
    """把 frontmatter + body 写回文件。保持 yaml 块风格"""
    # 用 default_flow_style=False, 允许 None 值
    fm_text = yaml.safe_dump(
        fm,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
        width=200,
    )
    # 去掉 yaml anchors/aliases（&id001 / *id001）——上面已用独立对象避免，这里作为双保险进一步禁用
    # （yaml 本身没提供 SafeDumper 禁用 anchor 的简洁开关，依赖上面的对象独立性）
    out = f"---\n{fm_text}---\n{body}"
    req_file.write_text(out, encoding='utf-8')


def ensure_related_files(fm: dict):
    """确保 related_files.prototype 是 list 结构"""
    if 'related_files' not in fm or fm['related_files'] is None:
        fm['related_files'] = {}
    if not isinstance(fm['related_files'], dict):
        fm['related_files'] = {}
    rf = fm['related_files']
    if 'prototype' not in rf or rf['prototype'] is None:
        rf['prototype'] = []
    if not isinstance(rf['prototype'], list):
        # 旧数据可能是字符串，转成 list
        rf['prototype'] = [rf['prototype']] if rf['prototype'] else []
    return rf['prototype']


def ensure_history(fm: dict):
    if 'history' not in fm or fm['history'] is None:
        fm['history'] = []
    if not isinstance(fm['history'], list):
        fm['history'] = []
    return fm['history']


def write_paths(req_file: Path, paths: list) -> dict:
    """
    把 paths 全部追加到 REQ.related_files.prototype（已存在的跳过）
    返回统计 {'added': N, 'skipped': M, 'paths_after': [...]}
    """
    fm, body = parse_req_file(req_file)
    proto = ensure_related_files(fm)
    history = ensure_history(fm)

    today = datetime.date.today()  # 仅用于下面记录需要；注意所有实际写入 fm 的 date 都要单独新建避免 yaml anchor
    version = fm.get('version', 'v1.0')

    added = 0
    skipped = 0
    new_added_paths = []

    for p in paths:
        if p in proto:
            skipped += 1
        else:
            proto.append(p)
            added += 1
            new_added_paths.append(p)

    if added > 0:
        fm['updated'] = datetime.date.today()
        # 每个新增路径都加一条 history（独立 date 实例避免 yaml anchor）
        for p in new_added_paths:
            history.append({
                'version': version,
                'action': 'prototype_linked',
                'file': p,
                'date': datetime.date.today(),
            })

    dump_req_file(req_file, fm, body)

    # 写完后立刻 re-read 验证
    fm2, _ = parse_req_file(req_file)
    rf2 = fm2.get('related_files', {})
    proto2 = rf2.get('prototype', []) if isinstance(rf2, dict) else []
    for p in paths:
        if p not in proto2:
            raise RuntimeError(
                f"ASSERTION FAILED: 写完后 {req_file} 的 related_files.prototype 仍不包含 {p}"
            )

    return {
        'added': added,
        'skipped': skipped,
        'paths_after': proto2,
    }


def check_paths(req_file: Path, paths: list) -> tuple:
    """返回 (all_present: bool, missing: list)"""
    fm, _ = parse_req_file(req_file)
    rf = fm.get('related_files') or {}
    if not isinstance(rf, dict):
        rf = {}
    proto = rf.get('prototype') or []
    if not isinstance(proto, list):
        proto = [proto]
    missing = [p for p in paths if p not in proto]
    return (len(missing) == 0, missing)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    cmd = sys.argv[1]
    req_file = Path(sys.argv[2])
    if not req_file.is_file():
        print(f"ERROR: REQ 文件不存在: {req_file}", file=sys.stderr)
        sys.exit(2)

    if cmd == 'write':
        if len(sys.argv) != 4:
            print("用法: write <REQ_FILE> <PROTOTYPE_PATH>", file=sys.stderr)
            sys.exit(2)
        path = sys.argv[3]
        stats = write_paths(req_file, [path])
        print(f"OK: {req_file.name} added={stats['added']} skipped={stats['skipped']} "
              f"prototype={stats['paths_after']}")
        sys.exit(0)

    elif cmd == 'write-multi':
        if len(sys.argv) < 4:
            print("用法: write-multi <REQ_FILE> <PATH1> [PATH2...]", file=sys.stderr)
            sys.exit(2)
        paths = sys.argv[3:]
        stats = write_paths(req_file, paths)
        print(f"OK: {req_file.name} added={stats['added']} skipped={stats['skipped']} "
              f"prototype={stats['paths_after']}")
        sys.exit(0)

    elif cmd == 'check':
        if len(sys.argv) != 4:
            print("用法: check <REQ_FILE> <PROTOTYPE_PATH>", file=sys.stderr)
            sys.exit(2)
        path = sys.argv[3]
        ok, missing = check_paths(req_file, [path])
        if ok:
            print(f"OK: {req_file.name} 已包含 {path}")
            sys.exit(0)
        else:
            print(f"MISSING: {req_file.name} 的 related_files.prototype 不包含: {missing}",
                  file=sys.stderr)
            sys.exit(1)

    else:
        print(f"ERROR: 未知命令: {cmd}", file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
