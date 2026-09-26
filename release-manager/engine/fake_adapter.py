from __future__ import annotations

import copy
import hashlib
import json
import uuid
from dataclasses import dataclass, field
from typing import Any

from .errors import ProcessError
from .ports import AdapterHandle, ManagedReconciliationObservation, invocation_fingerprint


BOOT_A = "11111111-1111-4111-8111-111111111111"


@dataclass
class FakeProcessRuntime:
    records: dict[str, dict[str, Any]] = field(default_factory=dict)
    raw_records: dict[str, dict[str, Any]] = field(default_factory=dict)
    known_receipts: set[str] = field(default_factory=set)
    events: list[str] = field(default_factory=list)
    next_id: int = 1
    persisted_adapter_id: str | None = None
    fail_attestation_for_sha: str | None = None
    fail_restore: bool = False
    ambiguous_inventory: bool = False
    available_secret_names: set[str] = field(default_factory=set)
    started_specs: list[dict[str, Any]] = field(default_factory=list)
    legacy_descriptors: dict[str, dict[str, Any]] = field(default_factory=dict)
    current_boot_id: str = BOOT_A


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
                "processStartId": f"{self.runtime.current_boot_id}:{1000 + int(adapter_id)}",
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
        if spec.get("configurationDigests"):
            record["configurationDigests"] = copy.deepcopy(spec["configurationDigests"])
        self.runtime.known_receipts.add(receipt)
        self.runtime.records[adapter_id] = {
            "record": record,
            "status": "online",
            "stableName": spec.get("stableName"),
            "releasePath": spec.get("releasePath"),
            "listener": copy.deepcopy(spec.get("listener")),
        }
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

    @staticmethod
    def _legacy_spec(descriptor: dict[str, Any]) -> dict[str, Any]:
        authority = descriptor["observedAuthority"]
        return {
            "environmentId": descriptor["metadata"]["environmentId"],
            "serviceId": descriptor["metadata"]["serviceId"],
            "namespace": authority["namespace"],
            "releaseSha": authority["releaseSha"],
            "runtime": copy.deepcopy(authority["invocation"]),
            "observedAt": "2026-09-23T15:00:00Z",
        }

    @staticmethod
    def _legacy_restore_spec(descriptor: dict[str, Any]) -> dict[str, Any]:
        authority = descriptor["observedAuthority"]
        recipe = descriptor["restoreRecipe"]
        return {
            "environmentId": descriptor["metadata"]["environmentId"],
            "serviceId": descriptor["metadata"]["serviceId"],
            "namespace": authority["namespace"],
            "releaseSha": authority["releaseSha"],
            "runtime": copy.deepcopy(recipe["bootstrap"]),
            "observedAt": "2026-09-23T15:00:00Z",
        }

    def preflight_legacy_restore(self, descriptor: dict[str, Any]) -> dict[str, Any]:
        self.runtime.events.append("preflight-legacy-restore")
        return {"descriptorDigest": "sha256:" + "1" * 64, "probe": "pass"}

    def observe_legacy(self, descriptor: dict[str, Any]) -> AdapterHandle:
        self.runtime.events.append("observe-legacy")
        handle = self._new_handle(self._legacy_spec(descriptor), "observed")
        self.runtime.legacy_descriptors[handle.record["provenance"]["adapterReceipt"]] = copy.deepcopy(descriptor)
        return handle

    def resolve_persisted(self, record: dict[str, Any]) -> AdapterHandle:
        receipt = record["provenance"]["adapterReceipt"]
        if receipt not in self.runtime.known_receipts:
            raise ProcessError("persisted handle cannot be re-observed")
        live = self.runtime.records.get(record["identity"]["adapterId"], {}).get("record")
        if live is not None and live.get("configurationDigests") != record.get("configurationDigests"):
            raise ProcessError("persisted runtime configuration digest context mismatch")
        self.runtime.events.append("resolve-persisted")
        return AdapterHandle(copy.deepcopy(record), self.issuer)

    @staticmethod
    def _boot_id(process_start_id: str) -> str:
        try:
            boot_id, ticks = process_start_id.rsplit(":", 1)
            uuid.UUID(boot_id)
            if int(ticks) <= 0:
                raise ValueError
        except (AttributeError, ValueError) as error:
            raise ProcessError("processStartId does not contain valid Linux boot evidence") from error
        return boot_id

    def observe_managed_after_host_restart(
        self, record: dict[str, Any], expected: dict[str, Any]
    ) -> ManagedReconciliationObservation:
        try:
            identity = record["identity"]
            adapter = record["adapter"]
            runtime = record["runtime"]
        except (KeyError, TypeError) as error:
            raise ProcessError("persisted ProcessHandle is structurally incomplete") from error
        if adapter != {"kind": "fake", "version": self.version, "instanceId": self.instance_id}:
            raise ProcessError("persisted ProcessHandle adapter identity mismatch")
        if record.get("invocationFingerprint") != invocation_fingerprint(runtime["executable"], runtime["args"], runtime["cwd"]):
            raise ProcessError("persisted ProcessHandle runtime fingerprint mismatch")
        old_boot_id = self._boot_id(identity["processStartId"])
        current_boot_id = self.runtime.current_boot_id
        try:
            uuid.UUID(current_boot_id)
        except (AttributeError, ValueError) as error:
            raise ProcessError("current Linux boot identity is unavailable") from error
        scoped = [
            item for item in self.runtime.records.values()
            if item["record"]["identity"]["environmentId"] == expected["environmentId"]
            and item["record"]["identity"]["serviceId"] == expected["serviceId"]
            and item["record"]["identity"]["namespace"] == expected["namespace"]
        ]
        if self.runtime.ambiguous_inventory or len(scoped) != 1 or scoped[0]["status"] != "online":
            raise ProcessError("managed reconciliation requires exactly one scoped live process")
        item = scoped[0]
        live = item["record"]
        overlapping = [
            other for other in self.runtime.records.values()
            if other is not item and (
                (
                    other.get("stableName") == expected["stableName"]
                    and other["record"]["identity"]["namespace"] == expected["namespace"]
                )
                or other["record"]["runtime"]["executable"] == expected["runtime"]["executable"]
                or other["record"]["runtime"]["cwd"] == expected["runtime"]["cwd"]
                or other.get("listener") == expected["listener"]
            )
        ]
        if overlapping:
            raise ProcessError("unexpected overlapping process inventory blocks reconciliation")
        live_boot_id = self._boot_id(live["identity"]["processStartId"])
        if live_boot_id != current_boot_id:
            raise ProcessError("live process boot identity does not match current host boot")
        durable_pairs = (
            (identity["environmentId"], expected["environmentId"]),
            (identity["serviceId"], expected["serviceId"]),
            (identity["namespace"], expected["namespace"]),
            (record["releaseSha"], expected["releaseSha"]),
            (record["runtime"], expected["runtime"]),
            (record.get("configurationDigests"), expected["configurationDigests"]),
            (live["releaseSha"], expected["releaseSha"]),
            (live["runtime"], expected["runtime"]),
            (live.get("configurationDigests"), expected["configurationDigests"]),
            (item.get("stableName"), expected["stableName"]),
            (item.get("releasePath"), expected["releasePath"]),
            (item.get("listener"), expected["listener"]),
        )
        if any(actual != wanted for actual, wanted in durable_pairs):
            raise ProcessError("managed reconciliation durable authority mismatch")
        same_identity = all(
            live["identity"][name] == identity[name]
            for name in ("adapterId", "pid", "processStartId")
        )
        if not same_identity and old_boot_id == current_boot_id:
            raise ProcessError("same-boot process identity change cannot be reconciled")
        if not same_identity and old_boot_id == live_boot_id:
            raise ProcessError("host reboot boundary is not proven")
        fresh = copy.deepcopy(live)
        fresh["provenance"] = {
            "origin": "observed",
            "observationId": str(uuid.uuid4()),
            "observedAt": expected["observedAt"],
            "adapterReceipt": f"fake-reconciled-receipt-{live['identity']['adapterId']}-{uuid.uuid4()}",
        }
        self.runtime.known_receipts.add(fresh["provenance"]["adapterReceipt"])
        self.runtime.events.append("observe-managed-after-host-restart")
        return ManagedReconciliationObservation(
            AdapterHandle(fresh, self.issuer), not same_identity, old_boot_id, current_boot_id,
            copy.deepcopy(expected["listener"]),
        )

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

    @staticmethod
    def _raw_digest(record: dict[str, Any]) -> str:
        payload = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    @staticmethod
    def _raw_overlaps(record: dict[str, Any], spec: dict[str, Any]) -> bool:
        return (
            (
                record.get("environmentId") == spec["environmentId"]
                and record.get("serviceId") == spec["serviceId"]
                and record.get("namespace") == spec["namespace"]
            )
            or (
                record.get("name") == spec["stableName"]
                and record.get("namespace") == spec["namespace"]
            )
            or record.get("executable") == spec["runtime"]["executable"]
            or record.get("cwd") == spec["runtime"]["cwd"]
            or (
                record.get("ownedHost") == spec["listener"]["host"]
                and record.get("ownedPort") == int(spec["listener"]["port"])
            )
        )

    @staticmethod
    def _raw_exact(record: dict[str, Any], spec: dict[str, Any]) -> bool:
        expected = {
            "name": spec["stableName"],
            "namespace": spec["namespace"],
            "environmentId": spec["environmentId"],
            "serviceId": spec["serviceId"],
            "releaseSha": spec["releaseSha"],
            "executable": spec["runtime"]["executable"],
            "cwd": spec["runtime"]["cwd"],
            "args": spec["runtime"]["args"],
            "ownedHost": spec["listener"]["host"],
            "ownedPort": int(spec["listener"]["port"]),
            "buildConfigDigest": spec["configurationDigests"]["build"],
            "runtimeConfigDigest": spec["configurationDigests"]["runtime"],
            "releaseContractDigest": spec["configurationDigests"]["releaseContract"],
            "environmentPolicyDigest": spec["configurationDigests"]["environmentPolicy"],
            "pid": 0,
            "evidence": None,
        }
        try:
            token = uuid.UUID(str(record.get("launchToken")))
        except (ValueError, AttributeError):
            return False
        return token.version == 4 and all(record.get(key) == value for key, value in expected.items())

    def remove_interrupted_candidate(self, spec: dict[str, Any]) -> dict[str, Any]:
        if self.runtime.ambiguous_inventory:
            raise ProcessError("interrupted activation raw process inventory is ambiguous")
        overlaps = [
            record for record in self.runtime.raw_records.values()
            if self._raw_overlaps(record, spec)
        ]
        exact = [record for record in overlaps if self._raw_exact(record, spec)]
        if len(exact) != 1 or len(overlaps) != 1:
            raise ProcessError("interrupted activation raw process inventory is ambiguous")
        record = exact[0]
        self.runtime.raw_records.pop(record["adapterId"])
        self.runtime.events.extend(("delete-raw-owned", "raw-absent"))
        return {
            "adapterId": record["adapterId"],
            "orphanRecordDigest": self._raw_digest(record),
            "launchTokenDigest": self._raw_digest({"launchToken": record["launchToken"]}),
        }

    def validate_runtime_spec(self, spec: dict[str, Any]) -> None:
        missing = sorted(set(spec["requiredSecretNames"]) - self.runtime.available_secret_names)
        if missing:
            raise ProcessError(f"required runtime secret names unavailable: {missing}")
        if not set(spec["binding"]).issubset(spec["allowedEnvNames"]):
            raise ProcessError("runtime bindings are not allowed by the Release Contract")
        non_secret = {item["name"]: item["value"] for item in spec["nonSecretValues"]}
        sources = [set(non_secret), set(spec["binding"]), set(spec["requiredSecretNames"])]
        if any(sources[i] & sources[j] for i in range(3) for j in range(i + 1, 3)):
            raise ProcessError("runtime environment sources overlap")
        if set(spec["allowedEnvNames"]) != set().union(*sources):
            raise ProcessError("runtime environment sources are incomplete")

    def start_candidate(self, spec: dict[str, Any]) -> AdapterHandle:
        self.validate_runtime_spec(spec)
        self.runtime.events.append("start-candidate")
        self.runtime.started_specs.append(copy.deepcopy(spec))
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

    def observe_preflight(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        self.attest(handle, expected_sha, health_targets)
        return {"releaseSha": expected_sha, "processStartId": handle.record["identity"]["processStartId"], "health": [{"target": target, "statusClass": 2} for target in health_targets]}

    def restore(self, handle: AdapterHandle) -> AdapterHandle:
        self.assert_handle(handle)
        if self.runtime.fail_restore:
            raise ProcessError("injected restore failure")
        self.runtime.events.append("restore")
        descriptor = self.runtime.legacy_descriptors.get(handle.record["provenance"]["adapterReceipt"])
        spec = self._legacy_restore_spec(descriptor) if descriptor else {
            "environmentId": handle.record["identity"]["environmentId"],
            "serviceId": handle.record["identity"]["serviceId"],
            "namespace": handle.record["identity"]["namespace"],
            "releaseSha": handle.record["releaseSha"],
            "runtime": copy.deepcopy(handle.record["runtime"]),
            "observedAt": handle.record["provenance"]["observedAt"],
            "configurationDigests": copy.deepcopy(handle.record.get("configurationDigests")),
        }
        return self._new_handle(spec, "started")

    def persist(self, handle: AdapterHandle) -> dict[str, Any]:
        self.assert_handle(handle)
        self.runtime.persisted_adapter_id = handle.record["identity"]["adapterId"]
        self.runtime.events.append("persist")
        return {"adapterId": self.runtime.persisted_adapter_id}
