from __future__ import annotations

import hashlib
import json
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .contracts import validate_legacy_restore_descriptor
from .errors import ContractError


@dataclass(frozen=True)
class LoadedLegacyRestoreDescriptor:
    document: dict[str, Any]
    path: Path
    digest: str


def load_legacy_restore_descriptor(path: Path, expected_uid: int) -> LoadedLegacyRestoreDescriptor:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ContractError("legacy restore descriptor is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ContractError("legacy restore descriptor must be a regular non-symlink file")
    if metadata.st_uid != expected_uid or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
        raise ContractError("legacy restore descriptor ownership or permissions are unsafe")
    try:
        raw = path.read_bytes()
        document = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise ContractError("legacy restore descriptor is invalid") from error
    validate_legacy_restore_descriptor(document)
    digest = "sha256:" + hashlib.sha256(json.dumps(document, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return LoadedLegacyRestoreDescriptor(document, path.resolve(), digest)
