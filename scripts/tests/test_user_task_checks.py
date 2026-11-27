import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class UserTaskChecks(unittest.TestCase):
    def test_short_readonly_task_needs_no_tracker_absolute_path_or_commit(self):
        with tempfile.TemporaryDirectory() as folder:
            task = Path(folder) / 'task.md'
            task.write_text('Read schema.prisma and explain why this user cannot complete the operation.')
            for script in ('check-task-desc.sh', 'pre-dispatch.sh'):
                result = subprocess.run(['bash', str(ROOT / 'dispatch-task/scripts' / script), str(task)], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            task.write_text('  \n')
            result = subprocess.run(['bash', str(ROOT / 'dispatch-task/scripts/pre-dispatch.sh'), str(task)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(shutil.which('jq'), 'existing deployment adapter requires jq')
    def test_target_check_does_not_probe_unrelated_environment_or_ssh(self):
        with tempfile.TemporaryDirectory() as folder:
            apps = Path(folder) / 'apps.json'; envs = Path(folder) / 'envs.json'
            apps.write_text(json.dumps({'apps': {'actual': {}}}))
            envs.write_text(json.dumps({'environments': {'demo': {}, 'unrelated': {'ssh_key': '/missing/key'}}}))
            command = ['bash', str(ROOT / 'deploy-app/scripts/doctor.sh'), '--target', 'actual', 'demo', str(apps), str(envs)]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            command[4] = 'unknown'
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_existing_planning_needs_no_fixed_headings_or_extra_documents(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            script = base / 'skills/planning/scripts/validate-planning.sh'
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'planning/scripts/validate-planning.sh', script)
            docs = base / 'docs-repos/actual/planning'
            docs.mkdir(parents=True)
            prd = docs / 'PRD.md'
            prd.write_text('Existing agreed goal: a teacher can find a class and correct its timetable.')
            command = ['bash', str(script), 'actual']
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(sorted(p.name for p in docs.iterdir()), ['PRD.md'])
            prd.write_text('')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    @unittest.skipUnless(shutil.which('jq'), 'existing archive adapter requires jq')
    def test_short_reason_preserves_real_field_validation_and_update(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            scripts = base / 'skills/project-mgmt/scripts'
            scripts.mkdir(parents=True)
            for name in ('set-field.sh', '_lib.sh'):
                shutil.copyfile(ROOT / 'project-mgmt/scripts' / name, scripts / name)
            project = base / 'knowledge-repos/projects/actual'
            project.mkdir(parents=True)
            profile = project / 'profile.json'
            profile.write_text(json.dumps({'display_name': 'Actual', 'stage': 'develop', 'priority': 'medium', 'health': 'yellow'}))
            command = ['bash', str(scripts / 'set-field.sh'), 'actual', 'health', 'green', '--reason', '已恢复']
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(profile.read_text())['health'], 'green')
            command[4] = 'invented'
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(json.loads(profile.read_text())['health'], 'green')

if __name__ == '__main__': unittest.main()
