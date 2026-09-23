from __future__ import annotations

import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Iterator

from .contracts import validate_state_record
from .errors import StateError


class GenerationConflict(StateError):
    pass


class AtomicStateStore:
    def __init__(self, state_file: Path, lock_file: Path, fault: Callable[[str], None] | None = None) -> None:
        self.state_file = state_file
        self.lock_file = lock_file
        self.fault = fault or (lambda _point: None)

    @contextmanager
    def locked(self) -> Iterator[None]:
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_file.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def load(self) -> dict[str, Any] | None:
        if not self.state_file.exists():
            return None
        try:
            record = json.loads(self.state_file.read_text(encoding="utf-8"))
            validate_state_record(record)
            return record
        except (json.JSONDecodeError, OSError) as error:
            raise StateError(f"invalid persisted state: {error}") from error

    def commit(self, expected_generation: int, record: dict[str, Any]) -> dict[str, Any]:
        current = self.load()
        actual = 0 if current is None else current["generation"]
        if actual != expected_generation:
            raise GenerationConflict(f"expected generation {expected_generation}, found {actual}")
        if record["generation"] != expected_generation + 1:
            raise GenerationConflict("new record generation must increase exactly once")
        validate_state_record(record)
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(record, indent=2, sort_keys=True) + "\n"
        fd, temporary = tempfile.mkstemp(prefix=".state-", suffix=".json", dir=self.state_file.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            self.fault("after-temp-fsync")
            os.replace(temporary, self.state_file)
            self.fault("after-replace")
            directory_fd = os.open(self.state_file.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return record
