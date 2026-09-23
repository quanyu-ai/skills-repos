from __future__ import annotations

import json
from pathlib import Path

from .errors import StateError

SPEC = Path(__file__).resolve().parents[1] / "spec" / "state-machines.json"


class StateMachine:
    def __init__(self, name: str) -> None:
        machines = json.loads(SPEC.read_text(encoding="utf-8"))["machines"]
        if name not in machines:
            raise StateError(f"unknown state machine: {name}")
        spec = machines[name]
        self.name = name
        self.state = spec["initial"]
        self.terminal = set(spec["terminal"])
        self.allowed = {tuple(item) for item in spec["transitions"]}
        self.trace: list[tuple[str, str, str]] = []

    def send(self, event: str, target: str) -> None:
        transition = (self.state, event, target)
        if self.state in self.terminal or transition not in self.allowed:
            raise StateError(f"illegal {self.name} transition: {transition}")
        self.trace.append(transition)
        self.state = target
