#!/usr/bin/env python3
"""Keep legacy project paths usable without a second enabled skill source."""
import argparse
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tomllib


def atomic_write(path, text):
    temporary = path.with_name(path.name + '.quanyu-tmp')
    temporary.write_text(text)
    temporary.chmod(path.stat().st_mode & 0o777 if path.exists() else 0o600)
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plugin-root', required=True, type=Path)
    parser.add_argument('--project', type=Path)
    args = parser.parse_args()
    plugin = args.plugin_root.resolve(strict=True)
    manifest = json.loads((plugin / '.codex-plugin/plugin.json').read_text())
    assert manifest['name'] in {'quanyu-engineering', 'quanyu-software-engineering'}
    skill_paths = {}
    for entry in manifest['skills']:
        source = (plugin / entry).resolve(strict=True)
        assert source.is_relative_to(plugin) and (source / 'SKILL.md').is_file()
        assert source.name not in skill_paths, 'Duplicate skill name: ' + source.name
        skill_paths[source.name] = source.relative_to(plugin)
    assert skill_paths, 'Empty skill manifest'
    status = json.loads(subprocess.check_output(
        ['codex', 'plugin', 'list', '--marketplace', 'quanyu-skills', '--json'], text=True))
    assert any(p['pluginId'] == manifest['name'] + '@quanyu-skills'
               and p['enabled'] and p['version'] == manifest['version']
               for p in status['installed']), 'Install and enable this plugin version first'
    codex_dir = Path.home() / '.codex'
    config = codex_dir / 'config.toml'
    if manifest['name'] == 'quanyu-software-engineering':
        # Rename without removing the old cache used by in-flight references.
        original_config = config.read_text() if config.exists() else ''
        parsed = tomllib.loads(original_config)
        legacy_id = 'quanyu-engineering@quanyu-skills'
        if parsed.get('plugins', {}).get(legacy_id, {}).get('enabled') is not False:
            section = '[plugins."' + legacy_id + '"]'
            match = re.search(r'(?m)^' + re.escape(section) + r'\s*$', original_config)
            if match:
                stop = re.search(r'(?m)^\[', original_config[match.end():])
                end = match.end() + stop.start() if stop else len(original_config)
                body = original_config[match.end():end]
                if re.search(r'(?m)^enabled\s*=', body):
                    body = re.sub(r'(?m)^enabled\s*=.*$', 'enabled = false', body, count=1)
                else:
                    body = '\nenabled = false\n' + body
                updated_config = original_config[:match.end()] + body + original_config[end:]
            else:
                updated_config = original_config.rstrip() + '\n\n' + section + '\nenabled = false\n'
            assert tomllib.loads(updated_config)['plugins'][legacy_id]['enabled'] is False
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
            backup = codex_dir / 'backups' / ('software-engineering-rename-' + stamp + '.toml')
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_text(original_config)
            backup.chmod(0o600)
            atomic_write(config, updated_config)
    alias_names = ['quanyu-engineering']
    if manifest['name'] == 'quanyu-software-engineering':
        alias_names.append('quanyu-software-engineering')
    for alias_name in alias_names:
        alias = codex_dir / 'shared-skills' / alias_name
        alias.parent.mkdir(parents=True, exist_ok=True)
        assert not alias.exists() or alias.is_symlink(), 'Do not replace an ordinary directory'
        pending = alias.with_name(alias.name + '.quanyu-tmp')
        pending.symlink_to(plugin, target_is_directory=True)
        os.replace(pending, alias)
    alias = codex_dir / 'shared-skills' / manifest['name']
    if not args.project:
        print(json.dumps({'sharedSource': str(alias), 'version': manifest['version']}))
        return
    project = args.project.resolve(strict=True)
    legacy_root = project / '.agents/skills'
    chosen = [(name, relative) for name, relative in skill_paths.items()
              if (legacy_root / name / 'SKILL.md').exists()]
    if not chosen:
        print('No legacy copies in this project; plugin already supplies the shared skills')
        return
    for name, _ in chosen:
        path = legacy_root / name
        assert path.is_dir() and not path.is_symlink(), 'Unexpected legacy directory: ' + str(path)
        header = (path / 'SKILL.md').read_text().split('---', 2)
        assert len(header) == 3 and ('name: ' + name) in header[1], str(path)
    config = codex_dir / 'config.toml'
    original = config.read_text() if config.exists() else ''
    identity = hashlib.sha256(str(project).encode()).hexdigest()[:16]
    begin = '# BEGIN quanyu-engineering legacy paths ' + identity
    end = '# END quanyu-engineering legacy paths ' + identity
    updated = original
    if begin in updated:
        start = updated.index(begin)
        stop = updated.index(end, start) + len(end)
        updated = updated[:start] + updated[stop:]
    block = '\n' + begin + '\n'
    for name, _ in chosen:
        block += '\n[[skills.config]]\npath = ' + json.dumps(
            str(legacy_root / name / 'SKILL.md'), ensure_ascii=False) + '\nenabled = false\n'
    updated = updated.rstrip() + '\n' + block + '\n' + end + '\n'
    tomllib.loads(updated)
    if updated == original and all(
            '<!-- quanyu-engineering legacy reference; do not edit shared skills here -->'
            in (legacy_root / name / 'SKILL.md').read_text() for name, _ in chosen):
        print('Legacy references already adopted; no new backup or project changes')
        return
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    archive = project / '.agents/shared-skills-legacy' / stamp
    archive.mkdir(parents=True, exist_ok=False)
    backup = codex_dir / 'backups' / ('quanyu-engineering-' + stamp + '-' + identity + '.toml')
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_text(original)
    backup.chmod(0o600)
    for name, relative in chosen:
        old = legacy_root / name
        source = alias / relative
        marker = '<!-- quanyu-engineering legacy reference; do not edit shared skills here -->'
        if marker not in (old / 'SKILL.md').read_text():
            shutil.move(str(old), str(archive / name))
            old.mkdir()
        (old / 'SKILL.md').write_text(
            '---\nname: ' + name + '\ndescription: 共享插件技能的旧路径兼容入口；不独立启用。\n---\n\n'
            + marker + '\n\n此路径只为既有引用保留。执行本技能前读取共享插件原文：\n\n'
            + '[' + name + '](' + str(source / 'SKILL.md') + ')\n\n'
            + '使用 ' + manifest['name'] + ':' + name + '；项目专属规则仍读取当前项目 AGENTS.md。\n')
        for child in source.iterdir():
            if child.name != 'SKILL.md' and not (old / child.name).exists():
                (old / child.name).symlink_to(child, target_is_directory=child.is_dir())
    atomic_write(config, updated)
    print(json.dumps({'project': str(project), 'legacyPathsDisabled': len(chosen),
                      'sharedSource': str(alias), 'archive': str(archive)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
