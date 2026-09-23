from __future__ import annotations

import copy
import uuid
from dataclasses import dataclass, field
from typing import Any

from .errors import ProcessError
from .ports import AdapterHandle, invocation_fingerprint


@dataclass
class FakeProcessRuntime:
    records: dict[str, dict[str, Any]] = field(default_factory=dict)
    known_receipts: set[str] = field(default_factory=set)
    events: list[str] = field(default_factory=list)
    next_id: int = 1
    persisted_adapter_id: str | None = None
    fail_attestation_for_sha: str | None = None
    fail_restore: bool = False
    ambiguous_inventory: bool = False
    available_secret_names: set[str] = field(default_factory=set)


class FakeProcessAdapter:
    """Deterministic adapter for engine tests. It has no PM2 or OS mutation code."""

    version = "0.0.0"

    def __init__(self, runtime: FakeProcessRuntime | None = None, instance_id: str | None = None) -> None:
        self.runtime = runtime or FakeProcessRuntime()
        self.instance_id = instance_id or str(uuid.uuid4())
        self.issuer = f"fake-adapter:{self.instance_id}"

    def _new_handle(self, spec: dict[str, Any], origin: str) -> AdapterHandle:
        adapter_id = str(self.runtime.next_id)
        self.runtime.next_id += 1
        receipt = f"fake-{origin}-receipt-{adapter_id}-verified"
        runtime = copy.deepcopy(spec["runtime"])
        record = {
            "apiVersion": "quanyu.ai/process-handle/v1alpha1",
            "kind": "ProcessHandle",
            "adapter": {"kind": "fake", "version": self.version, "instanceId": self.instance_id},
            "identity": {
                "environmentId": spec["environmentId"],
                "serviceId": spec["serviceId"],
                "namespace": spec["namespace"],
                "adapterId": adapter_id,
                "pid": 10000 + int(adapter_id),
                "processStartId": f"fake-start-{adapter_id}",
            },
            "runtime": runtime,
            "releaseSha": spec["releaseSha"],
            "invocationFingerprint": invocation_fingerprint(runtime["executable"], runtime["args"], runtime["cwd"]),
            "provenance": {
                "origin": origin,
                "observationId": str(uuid.uuid4()),
                "observedAt": spec["observedAt"],
                "adapterReceipt": receipt,
            },
        }
        self.runtime.known_receipts.add(receipt)
        self.runtime.records[adapter_id] = {"record": record, "status": "online"}
        return AdapterHandle(copy.deepcopy(record), self.issuer)

    def assert_handle(self, handle: AdapterHandle) -> None:
        if not isinstance(handle, AdapterHandle) or handle._issuer != self.issuer:
            raise ProcessError("ProcessHandle was not issued by this adapter instance")
        if handle.record["provenance"]["adapterReceipt"] not in self.runtime.known_receipts:
            raise ProcessError("unknown ProcessHandle provenance")

    def validate_policy(self, policy: dict[str, Any]) -> None:
        return None

    def inventory(self, environment_id: str, service_id: str, namespace: str) -> list[AdapterHandle]:
        if self.runtime.ambiguous_inventory:
            raise ProcessError("ambiguous process inventory")
        self.runtime.events.append("inventory")
        handles = []
        for item in self.runtime.records.values():
            record = item["record"]
            identity = record["identity"]
            if (
                item["status"] == "online"
                and identity["environmentId"] == environment_id
                and identity["serviceId"] == service_id
                and identity["namespace"] == namespace
            ):
                handles.append(AdapterHandle(copy.deepcopy(record), self.issuer))
        return handles

    def observe_legacy(self, spec: dict[str, Any]) -> AdapterHandle:
        self.runtime.events.append("observe-legacy")
        return self._new_handle(spec, "observed")

    def resolve_persisted(self, record: dict[str, Any]) -> AdapterHandle:
        receipt = record["provenance"]["adapterReceipt"]
        if receipt not in self.runtime.known_receipts:
            raise ProcessError("persisted handle cannot be re-observed")
        self.runtime.events.append("resolve-persisted")
        return AdapterHandle(copy.deepcopy(record), self.issuer)

    def assert_replaceable(self, current: AdapterHandle, candidate: dict[str, Any]) -> None:
        self.assert_handle(current)
        if self.runtime.ambiguous_inventory:
            raise ProcessError("ambiguous process inventory")
        self.runtime.events.append("replaceable")

    def stop_exact(self, handle: AdapterHandle) -> None:
        self.assert_handle(handle)
        record = self.runtime.records.get(handle.record["identity"]["adapterId"])
        if record:
            record["status"] = "stopped"
        self.runtime.events.append("stop-exact")

    def delete_exact(self, handle: AdapterHandle) -> None:
        self.assert_handle(handle)
        self.runtime.records.pop(handle.record["identity"]["adapterId"], None)
        self.runtime.events.append("delete-exact")

    def await_absent(self, handle: AdapterHandle) -> None:
        self.assert_handle(handle)
        if handle.record["identity"]["adapterId"] in self.runtime.records:
            raise ProcessError("exact process remains present")
        self.runtime.events.append("absent")

    def start_candidate(self, spec: dict[str, Any]) -> AdapterHandle:
        missing = sorted(set(spec["requiredSecretNames"]) - self.runtime.available_secret_names)
        if missing:
            raise ProcessError(f"required runtime secret names unavailable: {missing}")
        if not set(spec["binding"]).issubset(spec["allowedEnvNames"]):
            raise ProcessError("runtime bindings are not allowed by the Release Contract")
        self.runtime.events.append("start-candidate")
        return self._new_handle(spec, "started")

    def attest(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        self.assert_handle(handle)
        adapter_id = handle.record["identity"]["adapterId"]
        if self.runtime.records.get(adapter_id, {}).get("status") != "online":
            raise ProcessError("process is not online")
        if handle.record["releaseSha"] != expected_sha:
            raise ProcessError("runtime SHA mismatch")
        if self.runtime.fail_attestation_for_sha == expected_sha:
            raise ProcessError("injected health attestation failure")
        self.runtime.events.append("attest")
        return {"internal": health_targets[0], "public": health_targets[1], "result": "pass"}

    def restore(self, handle: AdapterHandle) -> AdapterHandle:
        self.assert_handle(handle)
        if self.runtime.fail_restore:
            raise ProcessError("injected restore failure")
        self.runtime.events.append("restore")
        spec = {
            "environmentId": handle.record["identity"]["environmentId"],
            "serviceId": handle.record["identity"]["serviceId"],
            "namespace": handle.record["identity"]["namespace"],
            "releaseSha": handle.record["releaseSha"],
            "runtime": copy.deepcopy(handle.record["runtime"]),
            "observedAt": handle.record["provenance"]["observedAt"],
        }
        return self._new_handle(spec, "started")

    def persist(self, handle: AdapterHandle) -> dict[str, Any]:
        self.assert_handle(handle)
        self.runtime.persisted_adapter_id = handle.record["identity"]["adapterId"]
        self.runtime.events.append("persist")
        return {"adapterId": self.runtime.persisted_adapter_id}
