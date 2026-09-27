"""Narrow, fail-closed publication of one reviewed commit into a registered mirror."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


SHA = re.compile(r"^[0-9a-f]{40}$")
ENVIRONMENT = "smart-college-demo"
APPLICATION = "smart-college-web"
REPOSITORY = "quanyu-ai/proj-code-smart-college"
CANONICAL_URL = "git@github.com:quanyu-ai/proj-code-smart-college.git"
PULL_REQUEST = 29
MERGED_AT = "2026-09-26T14:18:54Z"
EXPECTED_SHA = "06c5d26c54b3dbce528766eb3fcf44b72432efbf"
EXPECTED_TREE = "abe957be9dcf979e420eab018a2720ffd636177c"
EXPECTED_PARENT = "f967d1e3642b8357270cec79d3326da977d1e87d"
EXPECTED_SUBJECT = "feat: close the meeting resolution lifecycle (#29)"
EXPECTED_COMMITTER_EPOCH = "1790432334"
FINAL_REF = f"refs/quanyu/managed-publications/{EXPECTED_SHA}"
TEMP_REF = f"refs/quanyu/managed-publications-tmp/{EXPECTED_SHA}"


class SourcePublicationError(RuntimeError):
    pass


@dataclass(frozen=True)
class SourcePublicationBinding:
    environment_id: str
    service_id: str
    repository: str
    source_mirror: Path
    state_file: Path
    lock_file: Path
    trusted_owner_uids: tuple[int, ...]
    identity_file: Path
    known_hosts_file: Path


def _safe_file_digest(path: Path, trusted_uids: tuple[int, ...]) -> str:
    before = path.lstat()
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode)
            or before.st_uid not in trusted_uids or before.st_mode & 0o022):
        raise SourcePublicationError("registered authority file metadata is unsafe")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    value = hashlib.sha256()
    with os.fdopen(fd, "rb") as handle:
        opened = os.fstat(handle.fileno())
        for chunk in iter(lambda: handle.read(65536), b""):
            value.update(chunk)
    after = path.lstat()
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if identity != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) or identity != (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
    ):
        raise SourcePublicationError("registered authority file drifted during read")
    return f"sha256:{value.hexdigest()}"


def _safe_repository(path: Path, trusted_uids: tuple[int, ...]) -> Path:
    try:
        resolved = path.resolve(strict=True)
        info = path.lstat()
    except OSError as exc:
        raise SourcePublicationError("registered source mirror is unavailable") from exc
    if (not path.is_absolute() or resolved != path or not stat.S_ISDIR(info.st_mode)
            or stat.S_ISLNK(info.st_mode) or info.st_uid not in trusted_uids or info.st_mode & 0o022):
        raise SourcePublicationError("registered source mirror metadata is unsafe")
    git_dir = resolved / "objects"
    if not git_dir.is_dir():
        git_dir = resolved / ".git" / "objects"
    try:
        git_info = git_dir.lstat()
    except OSError as exc:
        raise SourcePublicationError("registered source mirror is not a Git repository") from exc
    if (stat.S_ISLNK(git_info.st_mode) or not stat.S_ISDIR(git_info.st_mode)
            or git_info.st_uid not in trusted_uids or git_info.st_mode & 0o022):
        raise SourcePublicationError("registered source mirror Git metadata is unsafe")
    return resolved


def _run(argv: list[str], *, env: dict[str, str], input_bytes: bytes | None = None,
         timeout: int = 120) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(argv, input=input_bytes, stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
                              timeout=timeout, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise SourcePublicationError("fixed Git operation failed") from exc


def _safe_credential_file(path: Path, *, owners: tuple[int, ...], mode: int) -> Path:
    resolved = path.resolve(strict=True)
    info = path.lstat()
    if (not path.is_absolute() or resolved != path or stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)
            or info.st_uid not in owners or stat.S_IMODE(info.st_mode) != mode
            or not re.fullmatch(r"/[A-Za-z0-9._/-]+", str(path))):
        raise SourcePublicationError("registered source credential metadata is unsafe")
    return resolved


def _git_env(binding: SourcePublicationBinding) -> dict[str, str]:
    identity = _safe_credential_file(binding.identity_file, owners=(os.geteuid(),), mode=0o400)
    known_hosts = _safe_credential_file(binding.known_hosts_file, owners=binding.trusted_owner_uids, mode=0o444)
    ssh_command = (f"/usr/bin/ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes "
        f"-o UserKnownHostsFile={known_hosts} -o IdentityFile={identity} -o IdentitiesOnly=yes "
        "-o ClearAllForwardings=yes -o RequestTTY=no -o ProxyCommand=none -o ProxyJump=none "
        "-o CanonicalizeHostname=no -o PermitLocalCommand=no")
    return {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false", "GIT_SSH_COMMAND": ssh_command,
            "GIT_SSH_VARIANT": "ssh"}


def _git(repository: Path, args: list[str], env: dict[str, str], *, input_bytes: bytes | None = None,
         expected: tuple[int, ...] = (0,)) -> bytes:
    completed = _run(["/usr/bin/git", "-c", f"safe.directory={repository}", "-C", str(repository), *args],
                     env=env, input_bytes=input_bytes)
    if completed.returncode not in expected:
        raise SourcePublicationError("fixed Git operation did not prove authority")
    return completed.stdout.strip()


def _ref(repository: Path, name: str, env: dict[str, str]) -> str | None:
    completed = _run(["/usr/bin/git", "-c", f"safe.directory={repository}", "-C", str(repository),
                      "rev-parse", "--verify", name], env=env)
    if completed.returncode == 1 or completed.returncode == 128:
        return None
    if completed.returncode != 0:
        raise SourcePublicationError("registered mirror ref lookup failed")
    value = completed.stdout.decode("ascii", "strict").strip()
    if not SHA.fullmatch(value):
        raise SourcePublicationError("registered mirror returned an invalid object identity")
    return value


def _attest_commit(repository: Path, ref: str, env: dict[str, str]) -> None:
    sha = _git(repository, ["rev-parse", "--verify", f"{ref}^{{commit}}"], env).decode()
    tree = _git(repository, ["show", "-s", "--format=%T", sha], env).decode()
    raw_commit = _git(repository, ["cat-file", "-p", sha], env).decode()
    parents = [line.removeprefix("parent ") for line in raw_commit.splitlines() if line.startswith("parent ")]
    subject = _git(repository, ["show", "-s", "--format=%s", sha], env).decode()
    committed_at = _git(repository, ["show", "-s", "--format=%ct", sha], env).decode()
    if (sha != EXPECTED_SHA or tree != EXPECTED_TREE or parents != [EXPECTED_PARENT]
            or subject != EXPECTED_SUBJECT or committed_at != EXPECTED_COMMITTER_EPOCH):
        raise SourcePublicationError("canonical GitHub PR provenance does not match frozen authority")


def publish(binding: SourcePublicationBinding, environment_id: str, service_id: str,
            repository: str, sha: str, *, temporary_directory: Callable[..., Any] = tempfile.TemporaryDirectory) -> dict[str, Any]:
    if (environment_id, service_id, repository, sha) != (ENVIRONMENT, APPLICATION, REPOSITORY, EXPECTED_SHA):
        raise SourcePublicationError("publication request is outside the frozen authority")
    if not SHA.fullmatch(sha) or (binding.environment_id, binding.service_id, binding.repository) != (
        ENVIRONMENT, APPLICATION, REPOSITORY
    ):
        raise SourcePublicationError("operator binding does not match frozen publication authority")
    mirror = _safe_repository(binding.source_mirror, binding.trusted_owner_uids)
    state_before = _safe_file_digest(binding.state_file, binding.trusted_owner_uids)
    env = _git_env(binding)
    lock_info = binding.lock_file.lstat()
    if (stat.S_ISLNK(lock_info.st_mode) or not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid not in binding.trusted_owner_uids or lock_info.st_mode & 0o022):
        raise SourcePublicationError("registered lock metadata is unsafe")
    lock_fd = os.open(binding.lock_file, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        before = _ref(mirror, FINAL_REF, env)
        if before not in (None, EXPECTED_SHA):
            raise SourcePublicationError("immutable publication ref conflicts with authority")
        if before is None:
            with temporary_directory(prefix="managed-source-publication-") as name:
                quarantine = Path(name).resolve()
                init = _run(["/usr/bin/git", "init", "--bare", "--quiet", str(quarantine)], env=env)
                if init.returncode != 0:
                    raise SourcePublicationError("publication quarantine initialization failed")
                fetched = _run(["/usr/bin/git", "-c", "credential.helper=", "-C", str(quarantine),
                                "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--depth=1",
                                CANONICAL_URL, f"+{EXPECTED_SHA}:{TEMP_REF}"], env=env, timeout=240)
                if fetched.returncode != 0:
                    raise SourcePublicationError("canonical GitHub provenance could not be fetched")
                _attest_commit(quarantine, TEMP_REF, env)
                imported = _run(["/usr/bin/git", "-c", f"safe.directory={mirror}", "-C", str(mirror),
                                 "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--force",
                                 f"file://{quarantine}", f"+{TEMP_REF}:{TEMP_REF}"], env=env, timeout=240)
                if imported.returncode != 0 or _ref(mirror, TEMP_REF, env) != EXPECTED_SHA:
                    raise SourcePublicationError("verified object import failed")
                transaction = (f"start\ncreate {FINAL_REF} {EXPECTED_SHA}\n"
                               f"delete {TEMP_REF} {EXPECTED_SHA}\nprepare\ncommit\n").encode()
                _git(mirror, ["update-ref", "--stdin"], env, input_bytes=transaction)
        after = _ref(mirror, FINAL_REF, env)
        if after != EXPECTED_SHA:
            raise SourcePublicationError("published ref attestation failed")
        _attest_commit(mirror, FINAL_REF, env)
        state_after = _safe_file_digest(binding.state_file, binding.trusted_owner_uids)
        if state_after != state_before:
            raise SourcePublicationError("State Store changed during source publication")
    finally:
        os.close(lock_fd)
    receipt = {"schemaVersion": "quanyu.ai/managed-source-publication-receipt/v1",
               "decision": "PASS", "environmentId": ENVIRONMENT, "serviceId": APPLICATION,
               "repository": REPOSITORY, "requestedSha": EXPECTED_SHA, "publishedRef": FINAL_REF,
               "publishedSha": EXPECTED_SHA, "tree": EXPECTED_TREE,
               "provenance": {"provider": "github.com", "pullRequest": PULL_REQUEST,
                              "mergedAt": MERGED_AT, "mergeCommit": EXPECTED_SHA,
                              "commitSubject": EXPECTED_SUBJECT,
                              "credentialSource": "registered-read-only-deploy-key"},
               "mutationProof": {"stateBeforeDigest": state_before, "stateAfterDigest": state_after,
                                 "stateUnchanged": True, "refBefore": before, "refAfter": after,
                                 "idempotent": before == EXPECTED_SHA}}
    receipt["receiptDigest"] = "sha256:" + hashlib.sha256(json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return receipt
