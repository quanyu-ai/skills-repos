#!/usr/bin/env python3
"""Forced-command gateway. It validates a tiny envelope and execs registered operators only."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

REGISTRY = Path("/etc/quanyu/release-manager/transport-registry.v1.json")
SHA = re.compile(r"^[0-9a-f]{40}$")
REQUEST_KEYS = {"environment", "application", "sha", "mode"}
MODES = {"preflight", "deploy", "attest"}
SENSITIVE_KEYS = {"password", "token", "privatekey", "secret", "secretvalue", "clientsecret",
                  "apikey", "authorization", "accesstoken", "databaseurl", "connectionstring"}
READ_ONLY_KEYS = {"schemaVersion", "operator", "version", "buildDigest", "observedAt", "decision", "scope",
                  "environmentId", "serviceId", "repository", "policy", "contract", "apiVersion", "application",
                  "digest", "fileDigest", "stateStore", "generation", "recordDigest", "updatedAt", "ageSeconds",
                  "current", "previous", "releaseSha", "releasePathDigest", "processHandleDigest", "artifactDigest",
                  "configurationDigests", "releaseContract", "environmentPolicy", "build", "runtime", "live",
                  "runningSha", "adapter", "kind", "instanceId", "identity", "namespace", "adapterId", "pid",
                  "processStartId", "linux", "bootId", "startTicks", "health", "internal", "public",
                  "evidenceDigest", "candidate", "provided", "sha", "reachable", "mutationProof",
                  "stateBeforeDigest", "stateAfterDigest", "unchanged", "code"}
DEPLOY_KEYS = {"schemaVersion", "decision", "attemptId", "releaseSha", "artifactDigest", "stateGeneration", "transitionDigest"}


class GatewayError(RuntimeError):
    pass


def _safe_json(path: Path, trusted_uids: tuple[int, ...] = (0,)) -> dict[str, Any]:
    before = path.lstat()
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise GatewayError("registry is not a regular non-symlink file")
    if before.st_uid not in trusted_uids or before.st_mode & 0o022:
        raise GatewayError("registry owner or mode is unsafe")
    parent = path.parent
    while parent != parent.parent:
        metadata = parent.lstat()
        if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid not in {*trusted_uids, 0} or metadata.st_mode & 0o022:
            raise GatewayError("registry parent directory is unsafe")
        parent = parent.parent
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        current = os.fstat(handle.fileno())
        if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
            raise GatewayError("registry identity changed")
        raw = handle.read(1024 * 1024 + 1)
    after = path.lstat()
    if len(raw) > 1024 * 1024 or (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size) != (
        after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size
    ):
        raise GatewayError("registry drifted during read")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise GatewayError("registry must be an object")
    return value


def _open_program(path: Path, owner_uid: int) -> tuple[int, str]:
    info = path.lstat()
    if (not path.is_absolute() or path.resolve(strict=True) != path or not stat.S_ISREG(info.st_mode)
            or info.st_uid != owner_uid or info.st_mode & 0o022 or not info.st_mode & 0o100):
        raise GatewayError("registered executable metadata is unsafe")
    parent = path.parent
    while parent != parent.parent:
        metadata = parent.lstat()
        if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid not in {0, owner_uid} or metadata.st_mode & 0o022:
            raise GatewayError("registered executable directory is unsafe")
        parent = parent.parent
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    current = os.fstat(fd)
    if (current.st_dev, current.st_ino, current.st_uid, current.st_mode) != (info.st_dev, info.st_ino, info.st_uid, info.st_mode):
        os.close(fd)
        raise GatewayError("registered executable identity changed")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return fd, digest.hexdigest()


def _tree_digest(root: Path, owner_uid: int) -> str:
    if not root.is_absolute() or root.resolve(strict=True) != root or not root.is_dir():
        raise GatewayError("operator installation root is unsafe")
    root_info = root.lstat()
    if root_info.st_uid != owner_uid or root_info.st_mode & 0o022:
        raise GatewayError("operator installation root metadata is unsafe")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            raise GatewayError("operator installation contains forbidden bytecode cache")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o022:
            raise GatewayError("operator installation tree metadata is unsafe")
        if path.is_dir():
            continue
        if not stat.S_ISREG(info.st_mode):
            raise GatewayError("operator installation contains a non-regular file")
        digest.update(relative.encode() + b"\0" + f"{stat.S_IMODE(info.st_mode):04o}".encode() + b"\0")
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(65536), b""):
                digest.update(chunk)
    return digest.hexdigest()


def _binding(registry: dict[str, Any], request: dict[str, str], registry_owner_uid: int) -> tuple[dict[str, Any], int, dict[str, Any]]:
    if set(registry) != {"schemaVersion", "bindings"} or registry["schemaVersion"] != "quanyu.ai/release-transport-registry/v1":
        raise GatewayError("registry schema is invalid")
    bindings = registry["bindings"]
    if not isinstance(bindings, list):
        raise GatewayError("registry bindings are invalid")
    matches = [item for item in bindings if isinstance(item, dict) and item.get("environment") == request["environment"] and item.get("application") == request["application"]]
    if len(matches) != 1:
        raise GatewayError("authority binding is not unique")
    item = matches[0]
    if set(item) != {"environment", "application", "repository", "operatorSha", "operatorManifest", "installRoot", "allowDeploy", "commands"}:
        raise GatewayError("binding schema is invalid")
    if not SHA.fullmatch(str(item["operatorSha"])) or not isinstance(item["allowDeploy"], bool):
        raise GatewayError("binding authority is invalid")
    manifest = _safe_json(Path(item["operatorManifest"]), (registry_owner_uid,))
    if (set(manifest) != {"schemaVersion", "sourceSha", "installTreeDigest", "gatewayDigest", "commandDigests", "deployAuthority"}
            or manifest["schemaVersion"] != "quanyu.ai/release-manager-install/v1"
            or manifest["sourceSha"] != item["operatorSha"]
            or manifest["deployAuthority"] != "release-manager/engine/core.py:ReleaseEngine"
            or not isinstance(manifest["commandDigests"], dict) or set(manifest["commandDigests"]) != MODES):
        raise GatewayError("installed operator identity does not match registry")
    if manifest["installTreeDigest"] != f"sha256:{_tree_digest(Path(item['installRoot']), registry_owner_uid)}":
        raise GatewayError("installed operator tree does not match manifest")
    commands = item["commands"]
    if not isinstance(commands, dict) or set(commands) != MODES:
        raise GatewayError("mode bindings are incomplete")
    command = commands[request["mode"]]
    if (not isinstance(command, list) or not command or any(not isinstance(part, str) or not part for part in command)
            or any("/" in part or part.startswith("-") for part in command[1:])):
        raise GatewayError("registered command is invalid")
    expected_operation = "deploy" if request["mode"] == "deploy" else "preflight-status"
    if command[1:] != [expected_operation]:
        raise GatewayError("mode is not bound to the canonical operation")
    executable = Path(command[0])
    install_root = Path(item["installRoot"])
    if install_root not in executable.parents:
        raise GatewayError("registered command is outside the measured installation")
    fd, digest = _open_program(executable, registry_owner_uid)
    if manifest["commandDigests"][request["mode"]] != f"sha256:{digest}":
        os.close(fd)
        raise GatewayError("registered command digest does not match installation manifest")
    if request["mode"] == "deploy" and not item["allowDeploy"]:
        os.close(fd)
        raise GatewayError("deploy is not enabled by host authority")
    return item, fd, manifest


def _request(raw: bytes) -> dict[str, str]:
    if len(raw) > 4096:
        raise GatewayError("request is too large")
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != REQUEST_KEYS or any(not isinstance(value[k], str) for k in REQUEST_KEYS):
        raise GatewayError("request schema is invalid")
    if value["mode"] not in MODES or not SHA.fullmatch(value["sha"]):
        raise GatewayError("request mode or SHA is invalid")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", value["environment"]):
        raise GatewayError("environment is invalid")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", value["application"]):
        raise GatewayError("application is invalid")
    return value


def _contains_secret(value: Any) -> bool:
    if isinstance(value, dict):
        return any(re.sub(r"[^a-z]", "", str(key).lower()) in SENSITIVE_KEYS or _contains_secret(item)
                   for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_secret(item) for item in value)
    if isinstance(value, str):
        lowered = value.lower()
        return any(marker in lowered for marker in ("-----begin private key-----", "postgresql://", "mysql://", "mongodb://",
                                                    "redis://", "bearer ")) or bool(re.fullmatch(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", value))
    return False


def _validate_evidence_schema(mode: str, value: Any, install_root: Path, owner_uid: int) -> None:
    if not isinstance(value, dict):
        raise GatewayError("operator returned invalid evidence")
    version = value.get("schemaVersion")
    if mode in {"preflight", "attest"}:
        if version == "quanyu.ai/release-manager-preflight-error/v1":
            schema_name = "preflight-error.schema.json"
        elif version == "quanyu.ai/release-manager-preflight-status/v1alpha1":
            schema_name = "preflight-status.schema.json"
        else:
            raise GatewayError("operator returned an unsupported read-only schema")
    else:
        if version != "quanyu.ai/release-manager-deploy-result/v1":
            raise GatewayError("operator returned an unsupported deploy schema")
        schema_name = "deploy-result.schema.json"
    validator_path = install_root / "scripts" / "validate.py"
    schema_path = install_root / "schemas" / schema_name
    validator_fd, _ = _open_program(validator_path, owner_uid)
    source = b""
    while True:
        chunk = os.read(validator_fd, 65536)
        if not chunk:
            break
        source += chunk
    os.close(validator_fd)
    schema = _safe_json(schema_path, (owner_uid,))
    namespace = {"__file__": str(validator_path), "__name__": "release_transport_schema_validator"}
    try:
        exec(compile(source, str(validator_path), "exec"), namespace)
        namespace["validate_schema"](value, schema)
    except Exception as exc:
        raise GatewayError("operator evidence schema validation failed") from exc


def invoke(raw: bytes, registry_path: Path = REGISTRY, *, trusted_owner_uid: int = 0) -> dict[str, Any]:
    request = _request(raw)
    registry = _safe_json(registry_path, (trusted_owner_uid,))
    binding, executable_fd, manifest = _binding(registry, request, trusted_owner_uid)
    proc_executable = f"/proc/self/fd/{executable_fd}"
    command = [proc_executable, *binding["commands"][request["mode"]][1:],
               "--environment-id", request["environment"], "--service-id", request["application"],
               "--expected-repository", binding["repository"], "--expected-candidate-sha", request["sha"]]
    try:
        completed = subprocess.run(command, executable=proc_executable, pass_fds=(executable_fd,),
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   check=False, timeout=300,
                                   env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8",
                                        "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": ""})
    finally:
        os.close(executable_fd)
    try:
        result = json.loads(completed.stdout)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise GatewayError("operator returned invalid evidence") from exc
    _validate_evidence_schema(request["mode"], result, Path(binding["installRoot"]), trusted_owner_uid)
    if _contains_secret(result):
        raise GatewayError("operator returned forbidden sensitive output")
    digest = hashlib.sha256(json.dumps(request, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"schemaVersion": "quanyu.ai/managed-release-transport-evidence/v1", "requestDigest": f"sha256:{digest}",
            "operatorSha": binding["operatorSha"], "installTreeDigest": manifest["installTreeDigest"],
            "gatewayDigest": manifest["gatewayDigest"],
            "operatorEntrypointDigest": manifest["commandDigests"][request["mode"]],
            "mode": request["mode"], "exitCode": completed.returncode,
            "result": result}


def main() -> int:
    try:
        original = os.environ.get("SSH_ORIGINAL_COMMAND", "")
        if original not in {"", "release-runner"} or os.environ.get("SSH_TTY"):
            raise GatewayError("interactive or arbitrary command use is forbidden")
        evidence = invoke(sys.stdin.buffer.read(4097))
    except Exception:
        evidence = {"schemaVersion": "quanyu.ai/managed-release-transport-error/v1",
                    "decision": "FAIL_CLOSED", "code": "MANAGED_TRANSPORT_AUTHORITY_UNPROVEN"}
        print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
        return 2
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    return 0 if evidence["exitCode"] == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
