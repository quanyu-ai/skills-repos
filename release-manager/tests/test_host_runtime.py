from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine.errors import SourceAttestationError, ToolchainError
from engine.host_runtime import GitSourceProvider, SubprocessLifecycleRunner


class HostRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.email", "test@example.invalid"], check=True)
        (self.source / "tracked.txt").write_text("original\n")
        subprocess.run(["git", "-C", str(self.source), "add", "tracked.txt"], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-q", "-m", "fixture"], check=True)
        self.sha = subprocess.run(["git", "-C", str(self.source), "rev-parse", "HEAD"],
                                  check=True, capture_output=True, text=True).stdout.strip()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_exact_git_source_attests_and_restores_tracked_files(self) -> None:
        destination = self.root / "candidate"
        workspace = GitSourceProvider(self.source / ".git", "owner/repo", (os.geteuid(),)).acquire("owner/repo", self.sha, destination)
        workspace.attest_sha(self.sha)
        (destination / "tracked.txt").write_text("changed\n")
        self.assertEqual(["tracked.txt"], workspace.changed_tracked())
        workspace.restore_tracked(["tracked.txt"])
        self.assertEqual([], workspace.changed_tracked())

    def test_source_identity_and_sha_are_not_caller_widenable(self) -> None:
        provider = GitSourceProvider(self.source / ".git", "owner/repo", (os.geteuid(),))
        for source, sha in (("other/repo", self.sha), ("owner/repo", "main")):
            with self.assertRaises(SourceAttestationError):
                provider.acquire(source, sha, self.root / f"bad-{len(source)}-{len(sha)}")

    def test_lifecycle_runner_uses_corepack_without_a_shell(self) -> None:
        runner = SubprocessLifecycleRunner(("/usr/bin", "/bin"))
        with patch("engine.host_runtime.shutil.which", return_value="/usr/bin/corepack"), \
                patch("engine.host_runtime.subprocess.run") as run:
            runner.frozen_install(self.root, "pnpm@9.15.4", {"HOME": str(self.root)})
            runner.run_action(self.root, {"packageScript": "build"}, {"HOME": str(self.root)})
        self.assertEqual(["/usr/bin/corepack", "pnpm@9.15.4", "install", "--frozen-lockfile"],
                         run.call_args_list[0].args[0])
        self.assertEqual(["/usr/bin/corepack", "pnpm@9.15.4", "run", "build"],
                         run.call_args_list[1].args[0])
        self.assertNotIn("shell", run.call_args_list[0].kwargs)

    def test_unavailable_package_manager_fails_closed(self) -> None:
        with patch("engine.host_runtime.shutil.which", return_value=None), self.assertRaises(ToolchainError):
            SubprocessLifecycleRunner(("/usr/bin",)).frozen_install(self.root, "pnpm@9.15.4", {})


if __name__ == "__main__":
    unittest.main()
