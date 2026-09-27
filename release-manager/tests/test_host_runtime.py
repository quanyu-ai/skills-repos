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
        self.root = Path(self.temp.name).resolve()
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

    def _assert_acquires(self, mirror: Path, name: str) -> None:
        destination = self.root / name
        workspace = GitSourceProvider(mirror, "owner/repo", (os.geteuid(),)).acquire("owner/repo", self.sha, destination)
        workspace.attest_sha(self.sha)
        (destination / "tracked.txt").write_text("changed\n")
        self.assertEqual(["tracked.txt"], workspace.changed_tracked())
        workspace.restore_tracked(["tracked.txt"])
        self.assertEqual([], workspace.changed_tracked())

    def test_exact_git_source_supports_bare_repository(self) -> None:
        self._assert_acquires(self.source / ".git", "candidate-bare")

    def test_exact_git_source_supports_non_bare_working_tree(self) -> None:
        self._assert_acquires(self.source, "candidate-worktree")

    def test_commit_attestation_uses_fixed_git_c_worktree_argv(self) -> None:
        real_run = subprocess.run
        calls = []

        def record(*args, **kwargs):
            calls.append(args[0])
            return real_run(*args, **kwargs)

        with patch("engine.host_runtime.subprocess.run", side_effect=record):
            GitSourceProvider(self.source, "owner/repo", (os.geteuid(),)).acquire(
                "owner/repo", self.sha, self.root / "candidate-argv")
        self.assertEqual([
            "/usr/bin/git", "-c", f"safe.directory={self.source}", "-C", str(self.source),
            "cat-file", "-e", f"{self.sha}^{{commit}}",
        ], calls[0])

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

    def test_wrong_layout_symlink_mode_and_owner_fail_closed(self) -> None:
        not_git = self.root / "not-git"
        not_git.mkdir()
        link = self.root / "mirror-link"
        link.symlink_to(self.source)
        unsafe_mode = self.root / "unsafe-mode"
        subprocess.run(["git", "clone", "-q", "--bare", str(self.source), str(unsafe_mode)], check=True)
        unsafe_mode.chmod(0o775)
        cases = (
            GitSourceProvider(not_git, "owner/repo", (os.geteuid(),)),
            GitSourceProvider(link, "owner/repo", (os.geteuid(),)),
            GitSourceProvider(unsafe_mode, "owner/repo", (os.geteuid(),)),
            GitSourceProvider(self.source, "owner/repo", (os.geteuid() + 1,)),
        )
        for index, provider in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(SourceAttestationError):
                provider.acquire("owner/repo", self.sha, self.root / f"rejected-{index}")

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
