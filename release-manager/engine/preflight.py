from __future__ import annotations

import copy
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .contracts import canonical_document_digest, compose_health_targets, validate_contract_and_policy, validate_state_record
from .errors import ContractError, ProcessError, StateError
from .ports import ProcessAdapter, invocation_fingerprint


SHA = re.compile(r"^[a-f0-9]{40}$")
SCHEMA_VERSION = "quanyu.ai/release-manager-preflight-status/v1alpha1"


class PreflightError(StateError):
    """A fail-closed, safe-to-display preflight failure."""


@dataclass(frozen=True)
class OperatorBinding:
    environment_id: str
    service_id: str
    repository: str
    policy_file: Path
    contract_file: Path
    state_file: Path
    lock_file: Path
    source_mirror: Path
    max_state_age_seconds: int = 86400
    trusted_owner_uids: tuple[int, ...] = (0,)


def _digest(value: Any) -> str:
    payload = value if isinstance(value, bytes) else json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def _safe_file(path: Path, owners: tuple[int, ...]) -> os.stat_result:
    try:
        meta = path.lstat()
    except OSError as error:
        raise PreflightError("registered authority file is unavailable") from error
    if stat.S_ISLNK(meta.st_mode) or not stat.S_ISREG(meta.st_mode):
        raise PreflightError("registered authority path is not a regular file")
    if meta.st_uid not in owners or stat.S_IMODE(meta.st_mode) & 0o022:
        raise PreflightError("registered authority file ownership or mode is unsafe")
    return meta


def _read_json(path: Path, owners: tuple[int, ...]) -> tuple[dict[str, Any], dict[str, Any]]:
    before = _safe_file(path, owners)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            payload = stream.read()
    except OSError as error:
        raise PreflightError("registered authority file cannot be read safely") from error
    after = _safe_file(path, owners)
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    opened_identity = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
    if identity != opened_identity or identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise PreflightError("registered authority file drifted during observation")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PreflightError("registered authority document is invalid JSON") from error
    if not isinstance(value, dict):
        raise PreflightError("registered authority document must be an object")
    return value, {"digest": _digest(payload), "device": before.st_dev, "inode": before.st_ino, "size": before.st_size, "mtimeNs": before.st_mtime_ns}


def _directory(path: Path, owners: tuple[int, ...]) -> Path:
    try:
        meta = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise PreflightError("immutable release directory is unavailable") from error
    if stat.S_ISLNK(meta.st_mode) or not stat.S_ISDIR(meta.st_mode) or meta.st_uid not in owners or stat.S_IMODE(meta.st_mode) & 0o022:
        raise PreflightError("immutable release directory ownership or mode is unsafe")
    return resolved


def _artifact_digest(release: Path, contract: dict[str, Any]) -> str:
    manifest = []
    for relative in contract["artifact"]["required"]:
        raw = release / relative
        try:
            meta = raw.lstat()
            resolved = raw.resolve(strict=True)
        except OSError as error:
            raise PreflightError("required release artifact is unavailable") from error
        if stat.S_ISLNK(meta.st_mode) or not stat.S_ISREG(meta.st_mode) or not resolved.is_relative_to(release):
            raise PreflightError("required release artifact is unsafe")
        try:
            content = resolved.read_bytes()
        except OSError as error:
            raise PreflightError("required release artifact cannot be read safely") from error
        manifest.append({"path": relative, "size": meta.st_size, "digest": _digest(content)})
    return _digest(manifest)


def _assert_authority(authority: dict[str, Any], slot: str, state: dict[str, Any], contract: dict[str, Any], policy: dict[str, Any], owners: tuple[int, ...]) -> dict[str, Any]:
    if authority.get("restorable") is not True:
        raise PreflightError(f"{slot} authority is not restorable")
    handle = authority["handle"]
    sha = authority["releaseSha"]
    identity = handle["identity"]
    if handle.get("releaseSha") != sha or authority["attestation"].get("sourceSha") != sha or authority["attestation"].get("runtimeSha") != sha:
        raise PreflightError(f"{slot} SHA attribution mismatch")
    if identity.get("environmentId") != state["environmentId"] or identity.get("serviceId") != state["serviceId"] or identity.get("namespace") != policy["process"]["namespace"]:
        raise PreflightError(f"{slot} ProcessHandle identity mismatch")
    expected = {
        "releaseContract": canonical_document_digest(contract),
        "environmentPolicy": canonical_document_digest(policy),
        "build": _digest(policy["build"]),
        "runtime": _digest({"runtime": policy["runtime"], "network": policy["network"], "secrets": policy["secrets"]}),
    }
    if handle.get("configurationDigests") != expected:
        raise PreflightError(f"{slot} configuration digest mismatch")
    release = _directory(Path(authority["releasePath"]), owners)
    runtime = handle["runtime"]
    try:
        executable = Path(runtime["executable"]).resolve(strict=True)
        cwd = Path(runtime["cwd"]).resolve(strict=True)
    except OSError as error:
        raise PreflightError(f"{slot} runtime is not recoverable") from error
    if not executable.is_file() or not cwd.is_dir() or not executable.is_relative_to(release) or not cwd.is_relative_to(release):
        raise PreflightError(f"{slot} runtime escapes its immutable release")
    if handle.get("invocationFingerprint") != invocation_fingerprint(str(executable), runtime["args"], str(cwd)):
        raise PreflightError(f"{slot} invocation fingerprint mismatch")
    artifact_digest = _artifact_digest(release, contract)
    if authority.get("artifactDigest") != artifact_digest:
        raise PreflightError(f"{slot} artifact attribution mismatch")
    return {"releaseSha": sha, "releasePathDigest": _digest(str(release)), "processHandleDigest": _digest(handle), "artifactDigest": artifact_digest, "configurationDigests": expected}


class PreflightStatusOperator:
    def __init__(self, binding: OperatorBinding, adapter: ProcessAdapter, *, now: Callable[[], datetime] | None = None) -> None:
        self.binding = binding
        self.adapter = adapter
        self.now = now or (lambda: datetime.now(timezone.utc))

    def observe(self, environment_id: str, service_id: str, expected_repository: str, candidate_sha: str | None = None) -> dict[str, Any]:
        binding = self.binding
        if (environment_id, service_id, expected_repository) != (binding.environment_id, binding.service_id, binding.repository):
            raise PreflightError("requested identity is not registered")
        if candidate_sha is not None and not SHA.fullmatch(candidate_sha):
            raise PreflightError("candidate SHA must be an exact lowercase commit SHA")
        _safe_file(binding.lock_file, binding.trusted_owner_uids)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            lock_fd = os.open(binding.lock_file, flags)
        except OSError as error:
            raise PreflightError("registered State Store lock cannot be opened safely") from error
        with os.fdopen(lock_fd, "rb") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_SH)
            try:
                result = self._observe_locked(candidate_sha)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        return result

    def _observe_locked(self, candidate_sha: str | None) -> dict[str, Any]:
        binding = self.binding
        policy, policy_file = _read_json(binding.policy_file, binding.trusted_owner_uids)
        contract, contract_file = _read_json(binding.contract_file, binding.trusted_owner_uids)
        state, state_before = _read_json(binding.state_file, binding.trusted_owner_uids)
        try:
            validate_contract_and_policy(contract, policy)
            validate_state_record(state)
        except (ContractError, KeyError) as error:
            raise PreflightError("authority document schema or semantics are invalid") from error
        if policy["metadata"]["environmentId"] != binding.environment_id or policy["metadata"]["serviceId"] != binding.service_id or state["environmentId"] != binding.environment_id or state["serviceId"] != binding.service_id:
            raise PreflightError("authority document identity mismatch")
        if state.get("status") != "managed" or "current" not in state or "previous" not in state:
            raise PreflightError("State Store lacks exact current and previous managed authorities")
        observed_at = self.now().astimezone(timezone.utc)
        try:
            updated = datetime.strptime(state["updatedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (KeyError, ValueError) as error:
            raise PreflightError("State Store timestamp is invalid") from error
        age = (observed_at - updated).total_seconds()
        if age < 0 or age > binding.max_state_age_seconds:
            raise PreflightError("State Store authority is stale")
        policy_digest = canonical_document_digest(policy)
        contract_digest = canonical_document_digest(contract)
        if state.get("environmentPolicyDigest") != policy_digest or state.get("releaseContractDigest") != contract_digest or state["attempt"].get("environmentPolicyDigest") != policy_digest or state["attempt"].get("releaseContractDigest") != contract_digest:
            raise PreflightError("Policy or Release Contract digest mismatch")
        if state["current"]["generation"] != state["generation"] or state["previous"]["generation"] >= state["current"]["generation"] or state["previous"]["releaseSha"] == state["current"]["releaseSha"]:
            raise PreflightError("State Store generation or rollback authority is invalid")
        current = _assert_authority(state["current"], "current", state, contract, policy, binding.trusted_owner_uids)
        previous = _assert_authority(state["previous"], "previous", state, contract, policy, binding.trusted_owner_uids)
        try:
            inventory = self.adapter.inventory(binding.environment_id, binding.service_id, policy["process"]["namespace"])
            if len(inventory) != 1:
                raise PreflightError("expected one exact live process authority")
            live = self.adapter.resolve_persisted(state["current"]["handle"])
        except ProcessError as error:
            raise PreflightError("live process authority cannot be re-observed exactly") from error
        if live.record["identity"] != state["current"]["handle"]["identity"] or live.record["runtime"] != state["current"]["handle"]["runtime"] or live.record["releaseSha"] != state["current"]["releaseSha"]:
            raise PreflightError("live process identity differs from persisted ProcessHandle")
        if inventory[0].record["identity"] != live.record["identity"]:
            raise PreflightError("process inventory is ambiguous")
        observer = getattr(self.adapter, "observe_preflight", None)
        if observer is None:
            raise PreflightError("process adapter does not implement the read-only preflight interface")
        try:
            health = observer(live, state["current"]["releaseSha"], compose_health_targets(contract, policy))
        except ProcessError as error:
            raise PreflightError("fresh runtime or health attestation failed") from error
        expected_targets = list(compose_health_targets(contract, policy))
        health_pass = (
            health.get("releaseSha") == state["current"]["releaseSha"]
            and health.get("processStartId") == live.record["identity"]["processStartId"]
            and [item.get("target") for item in health.get("health", [])] == expected_targets
            and len(health.get("health", [])) == 2
            and all(item.get("statusClass") in contract["health"]["acceptedStatusClasses"] for item in health["health"])
        )
        if not health_pass:
            raise PreflightError("fresh runtime or health attestation failed")
        candidate = {"provided": candidate_sha is not None, "sha": candidate_sha, "reachable": None}
        if candidate_sha is not None:
            mirror = _directory(binding.source_mirror, binding.trusted_owner_uids)
            try:
                completed = subprocess.run(["git", "-C", str(mirror), "cat-file", "-e", f"{candidate_sha}^{{commit}}"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False, env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
            except (OSError, subprocess.TimeoutExpired) as error:
                raise PreflightError("candidate source lookup failed closed") from error
            candidate["reachable"] = completed.returncode == 0
            if not candidate["reachable"]:
                raise PreflightError("candidate is unreachable in the registered source mirror")
        state_after_doc, state_after = _read_json(binding.state_file, binding.trusted_owner_uids)
        if state_after_doc != state or state_after != state_before:
            raise PreflightError("State Store drifted during observation")
        observed = observed_at.strftime("%Y-%m-%dT%H:%M:%SZ")
        linux = live.record["identity"]["processStartId"].rsplit(":", 1)
        if len(linux) != 2 or not linux[1].isdigit():
            raise PreflightError("live process lacks Linux boot/start evidence")
        return {
            "schemaVersion": SCHEMA_VERSION,
            "operator": {"version": "1.0.0", "buildDigest": _digest(Path(__file__).read_bytes())},
            "observedAt": observed,
            "decision": "PASS",
            "scope": {"environmentId": binding.environment_id, "serviceId": binding.service_id, "repository": binding.repository},
            "policy": {"apiVersion": policy["apiVersion"], "digest": policy_digest, "fileDigest": policy_file["digest"]},
            "contract": {"apiVersion": contract["apiVersion"], "application": contract["metadata"]["application"], "digest": contract_digest, "fileDigest": contract_file["digest"]},
            "stateStore": {"apiVersion": state["apiVersion"], "generation": state["generation"], "recordDigest": state_before["digest"], "updatedAt": state["updatedAt"], "ageSeconds": int(age)},
            "current": current,
            "previous": previous,
            "live": {"runningSha": live.record["releaseSha"], "repository": binding.repository, "processHandleDigest": _digest(live.record), "adapter": copy.deepcopy(live.record["adapter"]), "identity": copy.deepcopy(live.record["identity"]), "linux": {"bootId": linux[0], "startTicks": int(linux[1])}},
            "health": {"observedAt": observed, "internal": "pass", "public": "pass", "evidenceDigest": _digest(health)},
            "candidate": candidate,
            "mutationProof": {"stateBeforeDigest": state_before["digest"], "stateAfterDigest": state_after["digest"], "unchanged": True},
        }
