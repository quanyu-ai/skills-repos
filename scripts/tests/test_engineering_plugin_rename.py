"""Exercise rename adoption against isolated homes; never touch live Codex state."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class RenameAdoptionTest(unittest.TestCase):
    def run_adoption(self, home, installed=True, project=None):
        binary = home / 'bin'
        binary.mkdir(exist_ok=True)
        state = {'installed': [{'pluginId': 'quanyu-software-engineering@quanyu-skills',
                               'enabled': installed, 'version': json.loads((ROOT / '.codex-plugin/plugin.json').read_text())['version']}]}
        fake = binary / 'codex'
        fake.write_text('#!' + sys.executable + '\nprint(' + repr(json.dumps(state)) + ')\n')
        fake.chmod(0o700)
        env = dict(os.environ, HOME=str(home), PATH=str(binary) + os.pathsep + os.environ['PATH'])
        return subprocess.run([sys.executable, str(ROOT / 'scripts/adopt-engineering-plugin.py'),
                               '--plugin-root', str(ROOT)] + (['--project', str(project)] if project else []), env=env, capture_output=True, text=True)

    def test_only_current_alias_and_unrelated_settings_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            codex = home / '.codex'
            codex.mkdir()
            original = ('[plugins."quanyu-engineering@quanyu-skills"]\nenabled = true\n'
                        '[plugins."quanyu-software-engineering@quanyu-skills"]\nenabled = true\n'
                        '[plugins."quanyu-ui@quanyu-skills"]\nenabled = true\n'
                        '[[skills.config]]\npath = "/project/old/SKILL.md"\nenabled = false\n')
            config = codex / 'config.toml'
            config.write_text(original)
            old_cache = codex / 'plugins/cache/old'
            old_cache.mkdir(parents=True)
            (old_cache / 'keep').write_text('in-flight')
            result = self.run_adoption(home)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = tomllib.loads(original)
            expected['plugins']['quanyu-engineering@quanyu-skills']['enabled'] = False
            self.assertEqual(tomllib.loads(config.read_text()), expected)
            self.assertEqual((codex / 'shared-skills/quanyu-software-engineering').resolve(), ROOT)
            self.assertFalse((codex / 'shared-skills/quanyu-engineering').is_symlink())
            self.assertEqual((old_cache / 'keep').read_text(), 'in-flight')
            after = config.read_bytes()
            self.assertFalse((codex / 'backups').exists())
            self.assertEqual(self.run_adoption(home).returncode, 0)
            self.assertEqual(config.read_bytes(), after)
            self.assertFalse((codex / 'backups').exists())

    def test_uninstalled_target_does_not_disable_existing_plugin(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            codex = home / '.codex'
            codex.mkdir()
            config = codex / 'config.toml'
            original = '[plugins."quanyu-engineering@quanyu-skills"]\nenabled = true\n'
            config.write_text(original)
            result = self.run_adoption(home, installed=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), original)
            self.assertFalse((codex / 'shared-skills').exists())

    def test_project_old_texts_are_compressed_and_no_wrappers_regenerated(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary); project = home / 'project'; project.mkdir()
            old = project / '.agents/skills/planning'; old.mkdir(parents=True)
            content = '---\nname: planning\ndescription: old copy\n---\nOld instructions'
            (old / 'SKILL.md').write_text(content)
            history = project / '.agents/shared-skills-legacy/old'; history.mkdir(parents=True)
            (history / 'SKILL.md').write_text('historical instructions')
            result = self.run_adoption(home, project=project)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(old.exists())
            self.assertFalse(history.parent.exists())
            archives = list((project / '.agents/archives').glob('*.zip'))
            self.assertEqual(len(archives), 1)
            with zipfile.ZipFile(archives[0]) as packed:
                self.assertEqual(packed.read('.agents/skills/planning/SKILL.md').decode(), content)
            self.assertEqual(self.run_adoption(home, project=project).returncode, 0)
            self.assertEqual(list((project / '.agents/archives').glob('*.zip')), archives)


if __name__ == '__main__':
    unittest.main()
