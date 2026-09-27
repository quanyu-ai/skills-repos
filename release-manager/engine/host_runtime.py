from __future__ import annotations

import re
import shutil
import stat
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
    PRISMA_GENERATE_DATABASE_URL = "postgresql://127.0.0.1:1/release_manager_build?connect_timeout=1"

    def __init__(self, trusted_path: tuple[str, ...], toolchain: dict[str, str],
                 trusted_owner_uids: tuple[int, ...]) -> None:
        self.trusted_path = trusted_path
        if set(toolchain) != {"packageManager", "nodeExecutable", "corepackProgram", "corepackHome",
                             "prismaGenerateDatabaseUrl"}:
            raise ToolchainError("registered package manager toolchain is invalid")
        self.package_manager = toolchain["packageManager"]
        self.node = self._safe_program(Path(toolchain["nodeExecutable"]), trusted_owner_uids)
        self.corepack = self._safe_program(Path(toolchain["corepackProgram"]), trusted_owner_uids)
        self.corepack_home = self._safe_directory(Path(toolchain["corepackHome"]), trusted_owner_uids)
        if toolchain["prismaGenerateDatabaseUrl"] != self.PRISMA_GENERATE_DATABASE_URL:
            raise ToolchainError("registered Prisma generation environment is invalid")
        self.prisma_generate_database_url = toolchain["prismaGenerateDatabaseUrl"]
        self._package_managers: dict[Path, str] = {}

    @staticmethod
    def _safe_program(path: Path, trusted_owner_uids: tuple[int, ...]) -> str:
        try:
            metadata = path.lstat()
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise ToolchainError("registered toolchain program is unavailable") from error
        if (not path.is_absolute() or resolved != path or stat.S_ISLNK(metadata.st_mode)
                or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in trusted_owner_uids
                or metadata.st_mode & 0o022 or not metadata.st_mode & stat.S_IXUSR):
            raise ToolchainError("registered toolchain program metadata is unsafe")
        parent = path.parent
        while parent != parent.parent:
            info = parent.lstat()
            if (stat.S_ISLNK(info.st_mode) or info.st_uid not in {*trusted_owner_uids, 0}
                    or info.st_mode & 0o022):
                raise ToolchainError("registered toolchain parent metadata is unsafe")
            parent = parent.parent
        return str(path)

    @staticmethod
    def _safe_directory(path: Path, trusted_owner_uids: tuple[int, ...]) -> str:
        try:
            metadata = path.lstat()
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise ToolchainError("registered toolchain directory is unavailable") from error
        if (not path.is_absolute() or resolved != path or stat.S_ISLNK(metadata.st_mode)
                or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in trusted_owner_uids
                or metadata.st_mode & 0o022):
            raise ToolchainError("registered toolchain directory metadata is unsafe")
        return str(path)

    def _run(self, root: Path, argv: list[str], env: dict[str, str]) -> None:
        clean = dict(env)
        clean["PATH"] = ":".join(self.trusted_path)
        clean["LANG"] = "C.UTF-8"
        clean["COREPACK_HOME"] = self.corepack_home
        try:
            subprocess.run(argv, cwd=root, env=clean, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ToolchainError("typed lifecycle action failed") from error

    def frozen_install(self, root: Path, package_manager: str, env: dict[str, str]) -> None:
        name, _, version = package_manager.partition("@")
        if package_manager != self.package_manager or name not in {"pnpm", "npm", "yarn"} or not version:
            raise ToolchainError("pinned package manager runtime is unavailable")
        flags = {"pnpm": ["install", "--frozen-lockfile"], "npm": ["ci"],
                 "yarn": ["install", "--immutable"]}[name]
        self._run(root, [self.node, self.corepack, package_manager, *flags], env)
        self._package_managers[root.resolve()] = package_manager

    def run_action(self, root: Path, action: dict[str, Any], env: dict[str, str]) -> None:
        action_env = dict(env)
        if "packageScript" in action:
            package_manager = self._package_managers.get(root.resolve())
            if not package_manager:
                raise ToolchainError("package script lacks an attested package manager")
            argv = [self.node, self.corepack, package_manager, "run", action["packageScript"]]
            if action["packageScript"] == "db:generate":
                action_env["DATABASE_URL"] = self.prisma_generate_database_url
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
        self._run(root, argv, action_env)
