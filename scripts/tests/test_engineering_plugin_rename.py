"""Exercise rename adoption against isolated homes; never touch live Codex state."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RenameAdoptionTest(unittest.TestCase):
    def run_adoption(self, home, installed=True):
        binary = home / 'bin'
        binary.mkdir(exist_ok=True)
        state = {'installed': [{'pluginId': 'quanyu-software-engineering@quanyu-skills',
                               'enabled': installed, 'version': '1.1.0'}]}
        fake = binary / 'codex'
        fake.write_text('#!' + sys.executable + '\nprint(' + repr(json.dumps(state)) + ')\n')
        fake.chmod(0o700)
        env = dict(os.environ, HOME=str(home), PATH=str(binary) + os.pathsep + os.environ['PATH'])
        return subprocess.run([sys.executable, str(ROOT / 'scripts/adopt-engineering-plugin.py'),
                               '--plugin-root', str(ROOT)], env=env, capture_output=True, text=True)

    def test_rename_keeps_old_paths_and_preserves_other_settings(self):
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
            for name in ['quanyu-engineering', 'quanyu-software-engineering']:
                self.assertEqual((codex / 'shared-skills' / name).resolve(), ROOT)
            self.assertEqual((old_cache / 'keep').read_text(), 'in-flight')
            after = config.read_bytes()
            backups = list((codex / 'backups').iterdir())
            self.assertEqual(self.run_adoption(home).returncode, 0)
            self.assertEqual(config.read_bytes(), after)
            self.assertEqual(list((codex / 'backups').iterdir()), backups)

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


if __name__ == '__main__':
    unittest.main()
