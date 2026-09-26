#!/usr/bin/env python3
"""Client for the fixed Demo managed transport; never opens a shell."""
from __future__ import annotations

import json
import hashlib
import os
import stat
import subprocess
from pathlib import Path
from typing import Any

from gateway import SHA, _request

HOST = "8.138.118.28"
IDENTITY = Path("/Users/Cloud/.ssh/deploy_local")
KNOWN_HOSTS = Path("/Users/Cloud/.ssh/release_demo_known_hosts")
USER = "release-runner"
OPERATOR_SHA = "e0ccf99ddc3b33d881d8942ae86602d7c96883e8"


def _safe_file(path: Path, mode: int) -> None:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != mode or info.st_uid != os.geteuid():
        raise RuntimeError("managed transport file metadata is unsafe")


def ssh_argv(identity: Path = IDENTITY, known_hosts: Path = KNOWN_HOSTS) -> list[str]:
    _safe_file(identity, 0o600)
    _safe_file(known_hosts, 0o600)
    return ["/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={known_hosts}", "-o", f"IdentityFile={identity}",
            "-o", "IdentitiesOnly=yes", "-o", "ClearAllForwardings=yes", "-o", "RequestTTY=no",
            "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "CanonicalizeHostname=no",
            "-o", "PermitLocalCommand=no",
            f"{USER}@{HOST}", "release-runner"]


def invoke(request: dict[str, str]) -> dict[str, Any]:
    canonical = json.dumps(_request(json.dumps(request).encode()), sort_keys=True, separators=(",", ":")).encode()
    completed = subprocess.run(ssh_argv(), input=canonical, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               check=False, timeout=330, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError("transport returned invalid evidence")
    expected_digest = f"sha256:{hashlib.sha256(canonical).hexdigest()}"
    if (completed.returncode != 0 or set(value) != {"schemaVersion", "requestDigest", "operatorSha", "mode", "exitCode", "result"}
            or value["schemaVersion"] != "quanyu.ai/managed-release-transport-evidence/v1"
            or value["requestDigest"] != expected_digest or value["operatorSha"] != OPERATOR_SHA
            or value["mode"] != request["mode"] or value["exitCode"] != 0 or not isinstance(value["result"], dict)):
        raise RuntimeError("managed transport evidence did not match the request authority")
    return value
