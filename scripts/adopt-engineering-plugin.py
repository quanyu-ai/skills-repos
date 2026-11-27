#!/usr/bin/env python3
"""Adopt one current engineering source and retire obsolete project copies."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tomllib
import zipfile


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
    assert manifest['name'] == 'quanyu-software-engineering', 'Use the current plugin, not its retired name'
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
        # Keep only the current enabled name; no compatibility source is created.
        original_config = config.read_text() if config.exists() else ''
        parsed = tomllib.loads(original_config)
        legacy_id = 'quanyu-engineering@quanyu-skills'
        if parsed.get('plugins', {}).get(legacy_id, {}).get('enabled') is True:
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
            atomic_write(config, updated_config)
    legacy_alias = codex_dir / 'shared-skills/quanyu-engineering'
    if legacy_alias.is_symlink():
        legacy_alias.unlink()
    elif legacy_alias.exists():
        raise ValueError('Inspect the non-symlink legacy alias before retiring it')
    alias = codex_dir / 'shared-skills' / manifest['name']
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
    raw_history = project / '.agents/shared-skills-legacy'
    if not chosen and not raw_history.exists():
        print('Only the current plugin supplies these shared skills; no copies to retire')
        return
    targets = []
    for name, _ in chosen:
        path = legacy_root / name
        assert path.is_dir() and not path.is_symlink(), 'Unexpected legacy directory: ' + str(path)
        header = (path / 'SKILL.md').read_text().split('---', 2)
        assert len(header) == 3 and ('name: ' + name) in header[1], str(path)
        targets.append(path)
    if raw_history.exists():
        assert raw_history.is_dir() and not raw_history.is_symlink()
        targets.append(raw_history)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    archive = project / '.agents/archives' / ('retired-engineering-skills-' + stamp + '.zip')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as packed:
        for target in targets:
            for child in target.rglob('*'):
                name = str(child.relative_to(project))
                if child.is_symlink():
                    packed.writestr(name + '.symlink', str(child.readlink()))
                elif child.is_file():
                    packed.writestr(name, child.read_bytes())
    with zipfile.ZipFile(archive) as packed:
        assert packed.testzip() is None, 'Archive verification failed; originals retained'
        for target in targets:
            for child in target.rglob('*'):
                if child.is_file() and not child.is_symlink():
                    assert packed.read(str(child.relative_to(project))) == child.read_bytes()
    original = config.read_text() if config.exists() else ''
    retired_paths = {str(legacy_root / name / 'SKILL.md') for name, _ in chosen}
    def remove_retired(block):
        value = tomllib.loads(block.group(0))['skills']['config'][0]
        return '' if value.get('path') in retired_paths else block.group(0)
    updated = re.sub(r'(?ms)^\[\[skills\.config\]\][^\n]*\n.*?(?=^\[|\Z)', remove_retired, original)
    tomllib.loads(updated)
    for target in targets:
        shutil.rmtree(target)
    if updated != original:
        atomic_write(config, updated)
    print(json.dumps({'project': str(project), 'retiredCopies': len(chosen),
                      'sharedSource': str(alias), 'compressedHistory': str(archive)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
