from __future__ import annotations

import copy
import hashlib
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from .errors import ProcessError, SourceAttestationError


class SourceWorkspace(Protocol):
    root: Path

    def attest_sha(self, expected: str) -> None: ...
    def changed_tracked(self) -> list[str]: ...
    def restore_tracked(self, paths: list[str]) -> None: ...


class SourceProvider(Protocol):
    def acquire(self, source: str, sha: str, destination: Path) -> SourceWorkspace: ...


class LifecycleRunner(Protocol):
    def frozen_install(self, root: Path, package_manager: str, env: dict[str, str]) -> None: ...
    def run_action(self, root: Path, action: dict[str, Any], env: dict[str, str]) -> None: ...


@dataclass(frozen=True)
class AdapterHandle:
    record: dict[str, Any]
    _issuer: str


class ProcessAdapter(Protocol):
    def validate_policy(self, policy: dict[str, Any]) -> None: ...
    def inventory(self, environment_id: str, service_id: str, namespace: str) -> list[AdapterHandle]: ...
    def observe_legacy(self, spec: dict[str, Any]) -> AdapterHandle: ...
    def resolve_persisted(self, record: dict[str, Any]) -> AdapterHandle: ...
    def assert_replaceable(self, current: AdapterHandle, candidate: dict[str, Any]) -> None: ...
    def stop_exact(self, handle: AdapterHandle) -> None: ...
    def delete_exact(self, handle: AdapterHandle) -> None: ...
    def await_absent(self, handle: AdapterHandle) -> None: ...
    def start_candidate(self, spec: dict[str, Any]) -> AdapterHandle: ...
    def attest(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]: ...
    def restore(self, handle: AdapterHandle) -> AdapterHandle: ...
    def persist(self, handle: AdapterHandle) -> dict[str, Any]: ...
    def assert_handle(self, handle: AdapterHandle) -> None: ...


class FakeWorkspace:
    def __init__(self, root: Path, sha: str, baseline: dict[str, bytes]) -> None:
        self.root = root
        self.sha = sha
        self._baseline = baseline

    def attest_sha(self, expected: str) -> None:
        if self.sha != expected:
            raise SourceAttestationError(f"source SHA mismatch: expected {expected}, got {self.sha}")

    def changed_tracked(self) -> list[str]:
        changed = []
        for relative, original in self._baseline.items():
            path = self.root / relative
            if not path.is_file() or path.read_bytes() != original:
                changed.append(relative)
        return sorted(changed)

    def restore_tracked(self, paths: list[str]) -> None:
        for relative in paths:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(self._baseline[relative])


class FakeSourceProvider:
    """Deterministic exact-SHA source abstraction for tests; it performs no network I/O."""

    def __init__(self, source_root: Path, sha: str, reported_sha: str | None = None) -> None:
        self.source_root = source_root
        self.sha = sha
        self.reported_sha = reported_sha or sha
        self.acquisitions = 0

    def acquire(self, source: str, sha: str, destination: Path) -> FakeWorkspace:
        self.acquisitions += 1
        if sha != self.sha:
            raise SourceAttestationError("requested SHA unavailable")
        shutil.copytree(self.source_root, destination, symlinks=True)
        baseline = {
            str(path.relative_to(destination)): path.read_bytes()
            for path in destination.rglob("*")
            if path.is_file()
        }
        return FakeWorkspace(destination, self.reported_sha, baseline)


class FakeLifecycleRunner:
    def __init__(self) -> None:
        self.events: list[tuple[str, Any]] = []
        self.fail_on: str | None = None
        self.mutate: dict[str, bytes] = {}
        self.outputs: list[str] = []

    def _check(self, phase: str) -> None:
        if self.fail_on == phase:
            raise RuntimeError(f"injected lifecycle failure: {phase}")

    def frozen_install(self, root: Path, package_manager: str, env: dict[str, str]) -> None:
        self._check("install")
        self.events.append(("frozen-install", {"packageManager": package_manager, "env": copy.deepcopy(env)}))

    def run_action(self, root: Path, action: dict[str, Any], env: dict[str, str]) -> None:
        phase = action.get("packageScript") or action.get("argv", ["unknown"])[0]
        self._check(phase)
        self.events.append(("action", {"action": copy.deepcopy(action), "env": copy.deepcopy(env)}))
        for relative in self.outputs:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("generated\n", encoding="utf-8")
        for relative, content in self.mutate.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)


def invocation_fingerprint(executable: str, args: list[str], cwd: str) -> str:
    payload = json.dumps({"executable": executable, "args": args, "cwd": cwd}, sort_keys=True).encode()
    return "sha256:" + hashlib.sha256(payload).hexdigest()
