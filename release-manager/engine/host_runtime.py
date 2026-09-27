from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .errors import SourceAttestationError, ToolchainError
from .source_publication import SourcePublicationError, _safe_repository


class GitWorkspace:
    def __init__(self, root: Path, git: str = "/usr/bin/git") -> None:
        self.root = root
        self.git = git

    def _run(self, *args: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.git, "-C", str(self.root), *args], check=True,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, text=True,
            env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
                 "GIT_CONFIG_GLOBAL": "/dev/null"},
        )

    def attest_sha(self, expected: str) -> None:
        actual = self._run("rev-parse", "--verify", "HEAD^{commit}", capture=True).stdout.strip()
        if actual != expected:
            raise SourceAttestationError("checked-out source SHA mismatch")

    def changed_tracked(self) -> list[str]:
        output = self._run("diff", "--name-only", "--no-ext-diff", "HEAD", "--", capture=True).stdout
        return sorted({line for line in output.splitlines() if line})

    def restore_tracked(self, paths: list[str]) -> None:
        if paths:
            self._run("restore", "--source=HEAD", "--staged", "--worktree", "--", *paths)


class GitSourceProvider:
    def __init__(self, mirror: Path, repository: str, trusted_owner_uids: tuple[int, ...],
                 git: str = "/usr/bin/git") -> None:
        self.mirror = mirror
        self.repository = repository
        self.trusted_owner_uids = trusted_owner_uids
        self.git = git

    def acquire(self, source: str, sha: str, destination: Path) -> GitWorkspace:
        if source != self.repository or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise SourceAttestationError("source authority mismatch")
        try:
            mirror = _safe_repository(self.mirror, self.trusted_owner_uids)
        except SourcePublicationError as error:
            raise SourceAttestationError("source mirror layout is unsafe") from error
        if destination.exists():
            raise SourceAttestationError("source mirror or destination is unsafe")
        environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_CONFIG_GLOBAL": "/dev/null"}
        try:
            subprocess.run([self.git, "-c", f"safe.directory={mirror}", "-C", str(mirror),
                            "cat-file", "-e", f"{sha}^{{commit}}"],
                           check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, env=environment)
            subprocess.run([self.git, "clone", "--no-checkout", "--shared", "--", str(mirror), str(destination)],
                           check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, env=environment)
            workspace = GitWorkspace(destination, self.git)
            workspace._run("checkout", "--detach", "--force", sha, "--")
            workspace.attest_sha(sha)
            return workspace
        except (OSError, subprocess.CalledProcessError) as error:
            raise SourceAttestationError("exact source acquisition failed") from error


class SubprocessLifecycleRunner:
    def __init__(self, trusted_path: tuple[str, ...]) -> None:
        self.trusted_path = trusted_path
        self._package_managers: dict[Path, str] = {}

    def _run(self, root: Path, argv: list[str], env: dict[str, str]) -> None:
        clean = dict(env)
        clean["PATH"] = ":".join(self.trusted_path)
        clean["LANG"] = "C.UTF-8"
        try:
            subprocess.run(argv, cwd=root, env=clean, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ToolchainError("typed lifecycle action failed") from error

    def frozen_install(self, root: Path, package_manager: str, env: dict[str, str]) -> None:
        name, _, version = package_manager.partition("@")
        corepack = shutil.which("corepack", path=":".join(self.trusted_path))
        if not corepack or name not in {"pnpm", "npm", "yarn"} or not version:
            raise ToolchainError("pinned package manager runtime is unavailable")
        flags = {"pnpm": ["install", "--frozen-lockfile"], "npm": ["ci"],
                 "yarn": ["install", "--immutable"]}[name]
        self._run(root, [corepack, package_manager, *flags], env)
        self._package_managers[root.resolve()] = package_manager

    def run_action(self, root: Path, action: dict[str, Any], env: dict[str, str]) -> None:
        if "packageScript" in action:
            package_manager = self._package_managers.get(root.resolve())
            corepack = shutil.which("corepack", path=":".join(self.trusted_path))
            if not package_manager or not corepack:
                raise ToolchainError("package script lacks an attested package manager")
            argv = [corepack, package_manager, "run", action["packageScript"]]
        else:
            raw = list(action["argv"])
            executable = raw[0]
            if "/" in executable:
                candidate = ((root / executable) if not Path(executable).is_absolute() else Path(executable)).resolve(strict=True)
                if not candidate.is_relative_to(root.resolve()) and candidate.parent.as_posix() not in self.trusted_path:
                    raise ToolchainError("lifecycle executable escapes trusted roots")
                executable = str(candidate)
            else:
                resolved = shutil.which(executable, path=":".join(self.trusted_path))
                if not resolved:
                    raise ToolchainError("lifecycle executable is unavailable")
                executable = resolved
            argv = [executable, *raw[1:]]
        self._run(root, argv, env)
