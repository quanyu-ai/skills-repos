from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import socket
import stat
import subprocess
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .errors import ProcessError
from .ports import AdapterHandle, invocation_fingerprint


class PM2ProcessAdapter:
    """Linux PM2 adapter using only the programmatic API through a JSON bridge."""

    version = "0.1.0"
    pinned_pm2_version = "7.0.4"
    minimum_node_major = 20

    def __init__(
        self,
        *,
        pm2_home: Path,
        node_modules: Path,
        instance_id: str,
        stable_name: str,
        secret_owner_uid: int,
        trusted_path: tuple[str, ...] = ("/usr/local/bin", "/usr/bin", "/bin"),
        health_attempts: int = 20,
        health_interval_seconds: float = 0.1,
        runtime_policy: dict[str, Any] | None = None,
    ) -> None:
        if not re.fullmatch(r"[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}", instance_id):
            raise ProcessError("invalid PM2 adapter instance ID")
        if not stable_name or not trusted_path or any(not Path(item).is_absolute() or ":" in item for item in trusted_path):
            raise ProcessError("invalid PM2 adapter configuration")
        if not isinstance(secret_owner_uid, int) or secret_owner_uid < 0:
            raise ProcessError("invalid trusted secret owner UID")
        self.pm2_home = pm2_home.resolve()
        self.node_modules = node_modules.resolve()
        self.instance_id = instance_id
        self.stable_name = stable_name
        self.secret_owner_uid = secret_owner_uid
        self.trusted_path = tuple(dict.fromkeys(trusted_path))
        self.health_attempts = health_attempts
        self.health_interval_seconds = health_interval_seconds
        self.runtime_policy = copy.deepcopy(runtime_policy)
        self.bridge = Path(__file__).resolve().parents[1] / "pm2-adapter" / "bridge.cjs"
        self.issuer = f"pm2-programmatic:{instance_id}"
        self._sidecars: dict[str, dict[str, Any]] = {}
        self._attested: set[str] = set()
        self.version_evidence = self._attest_runtime_versions()

    def _attest_runtime_versions(self) -> dict[str, str]:
        evidence = self._bridge({"action": "runtime-version"})
        pm2_version = evidence.get("pm2PackageVersion")
        node_runtime = evidence.get("nodeRuntime")
        match = re.fullmatch(r"v(\d+)\.\d+\.\d+", str(node_runtime))
        if pm2_version != self.pinned_pm2_version:
            raise ProcessError("loaded PM2 package version does not match the pinned adapter version")
        if not match or int(match.group(1)) < self.minimum_node_major:
            raise ProcessError("loaded Node runtime is outside the supported adapter range")
        return {
            "adapterVersion": self.version,
            "pm2PackageVersion": pm2_version,
            "nodeRuntime": node_runtime,
        }

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def _redact(text: str, values: list[str]) -> str:
        for value in values:
            if value:
                text = text.replace(value, "[REDACTED]")
        return text

    def _bridge(self, request: dict[str, Any], sensitive_values: list[str] | None = None) -> dict[str, Any]:
        environment = {
            "HOME": str(self.pm2_home),
            "PATH": ":".join(self.trusted_path),
            "PM2_HOME": str(self.pm2_home),
            "NODE_PATH": str(self.node_modules),
        }
        completed = subprocess.run(
            ["node", str(self.bridge)],
            input=json.dumps(request, separators=(",", ":")),
            text=True,
            capture_output=True,
            env=environment,
            timeout=30,
            check=False,
        )
        values = sensitive_values or []
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise ProcessError("PM2 bridge returned invalid structured output") from error
        if completed.returncode or not response.get("ok"):
            message = self._redact(str(response.get("error", "PM2 bridge action failed")), values)
            raise ProcessError(message)
        return response

    @staticmethod
    def _receipt_payload(record: dict[str, Any]) -> dict[str, Any]:
        payload = copy.deepcopy(record)
        payload["provenance"].pop("adapterReceipt", None)
        return payload

    def _receipt(self, record: dict[str, Any]) -> str:
        payload = json.dumps(
            {"instanceId": self.instance_id, "record": self._receipt_payload(record)},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    def _handle_from_observation(
        self,
        observed: dict[str, Any],
        *,
        environment_id: str,
        service_id: str,
        release_sha: str,
        origin: str,
        observed_at: str,
        sidecar: dict[str, Any],
    ) -> AdapterHandle:
        evidence = observed.get("evidence")
        if observed.get("status") != "online" or not evidence:
            raise ProcessError("PM2 observation lacks live /proc evidence")
        record = {
            "apiVersion": "quanyu.ai/process-handle/v1alpha1",
            "kind": "ProcessHandle",
            "adapter": {"kind": "pm2-programmatic", "version": self.version, "instanceId": self.instance_id},
            "identity": {
                "environmentId": environment_id,
                "serviceId": service_id,
                "namespace": observed["namespace"],
                "adapterId": observed["adapterId"],
                "pid": observed["pid"],
                "processStartId": evidence["processStartId"],
            },
            "runtime": {
                "executable": observed["executable"],
                "args": observed["args"],
                "cwd": observed["cwd"],
            },
            "releaseSha": release_sha,
            "invocationFingerprint": invocation_fingerprint(observed["executable"], observed["args"], observed["cwd"]),
            "provenance": {
                "origin": origin,
                "observationId": str(uuid.uuid4()),
                "observedAt": observed_at,
            },
        }
        record["provenance"]["adapterReceipt"] = self._receipt(record)
        receipt = record["provenance"]["adapterReceipt"]
        self._sidecars[receipt] = copy.deepcopy(sidecar)
        return AdapterHandle(record, self.issuer)

    def assert_handle(self, handle: AdapterHandle) -> None:
        if not isinstance(handle, AdapterHandle) or handle._issuer != self.issuer:
            raise ProcessError("ProcessHandle was not issued by this PM2 adapter instance")
        record = handle.record
        adapter = record.get("adapter", {})
        if adapter != {"kind": "pm2-programmatic", "version": self.version, "instanceId": self.instance_id}:
            raise ProcessError("ProcessHandle adapter provenance mismatch")
        if record.get("provenance", {}).get("adapterReceipt") != self._receipt(record):
            raise ProcessError("ProcessHandle receipt mismatch")

    def validate_policy(self, policy: dict[str, Any]) -> None:
        process = policy["process"]
        if process["adapter"] != "pm2":
            raise ProcessError("PM2 adapter requires process.adapter=pm2")
        if process["stableName"] != self.stable_name:
            raise ProcessError("PM2 stable service identity does not match adapter configuration")

    def _all_inventory(self) -> list[dict[str, Any]]:
        return self._bridge({"action": "inventory"})["records"]

    def inventory(self, environment_id: str, service_id: str, namespace: str) -> list[AdapterHandle]:
        handles = []
        for observed in self._all_inventory():
            if (
                observed["environmentId"] == environment_id
                and observed["serviceId"] == service_id
                and observed["namespace"] == namespace
            ):
                if observed["status"] != "online":
                    raise ProcessError("scoped PM2 inventory contains a non-live residual record")
                handles.append(self._handle_from_observation(
                    observed,
                    environment_id=environment_id,
                    service_id=service_id,
                    release_sha=observed["releaseSha"],
                    origin="observed",
                    observed_at=self._now(),
                    sidecar={
                        "stableName": observed["name"],
                        "listener": {"host": observed["ownedHost"], "port": observed["ownedPort"]},
                    },
                ))
        return handles

    def _exact_expected(self, handle: AdapterHandle) -> dict[str, Any]:
        self.assert_handle(handle)
        record = handle.record
        sidecar = self._sidecars.get(record["provenance"]["adapterReceipt"], {})
        return {
            "adapterId": record["identity"]["adapterId"],
            "pid": record["identity"]["pid"],
            "processStartId": record["identity"]["processStartId"],
            "name": sidecar.get("stableName", self.stable_name),
            "namespace": record["identity"]["namespace"],
            "environmentId": record["identity"]["environmentId"],
            "serviceId": record["identity"]["serviceId"],
            "releaseSha": record["releaseSha"],
            **record["runtime"],
        }

    def _restore_spec(self, record: dict[str, Any], observed: dict[str, Any]) -> dict[str, Any] | None:
        if self.runtime_policy is None:
            return None
        return {
            "environmentId": record["identity"]["environmentId"],
            "serviceId": record["identity"]["serviceId"],
            "namespace": record["identity"]["namespace"],
            "stableName": observed["name"],
            "releaseSha": record["releaseSha"],
            "runtime": copy.deepcopy(record["runtime"]),
            "observedAt": self._now(),
            "allowedEnvNames": copy.deepcopy(self.runtime_policy["allowedEnvNames"]),
            "requiredSecretNames": copy.deepcopy(self.runtime_policy["requiredSecretNames"]),
            "secretSource": copy.deepcopy(self.runtime_policy["secretSource"]),
            "binding": copy.deepcopy(self.runtime_policy["binding"]),
            "listener": copy.deepcopy(self.runtime_policy["listener"]),
            "health": copy.deepcopy(self.runtime_policy["health"]),
        }

    def observe_legacy(self, spec: dict[str, Any]) -> AdapterHandle:
        matches = []
        for observed in self._all_inventory():
            if (
                observed["status"] == "online"
                and observed["namespace"] == spec["namespace"]
                and observed["name"] == spec.get("stableName", self.stable_name)
                and observed["executable"] == str(Path(spec["runtime"]["executable"]).resolve())
                and observed["cwd"] == str(Path(spec["runtime"]["cwd"]).resolve())
                and observed["args"] == spec["runtime"]["args"]
            ):
                matches.append(observed)
        if len(matches) != 1:
            raise ProcessError(f"legacy observation expected one exact process, found {len(matches)}")
        observed = matches[0]
        return self._handle_from_observation(
            observed,
            environment_id=spec["environmentId"],
            service_id=spec["serviceId"],
            release_sha=spec["releaseSha"],
            origin="observed",
            observed_at=spec["observedAt"],
            sidecar={
                "stableName": observed["name"],
                "listener": copy.deepcopy(spec.get("listener")),
                "startSpec": copy.deepcopy(spec.get("restoreSpec")) or self._restore_spec({
                    "identity": {
                        "environmentId": spec["environmentId"],
                        "serviceId": spec["serviceId"],
                        "namespace": spec["namespace"],
                    },
                    "releaseSha": spec["releaseSha"],
                    "runtime": spec["runtime"],
                }, observed),
            },
        )

    def resolve_persisted(self, record: dict[str, Any]) -> AdapterHandle:
        # A persisted receipt is correlation evidence only. Restart recovery does
        # not authenticate it or accept it as live authority. Every field below
        # is reconciled against a fresh full PM2 inventory plus /proc evidence.
        try:
            adapter = record["adapter"]
            identity = record["identity"]
            runtime = record["runtime"]
            persisted_fingerprint = record["invocationFingerprint"]
            expected = {
                "adapterId": identity["adapterId"],
                "pid": identity["pid"],
                "processStartId": identity["processStartId"],
                "name": self.stable_name,
                "namespace": identity["namespace"],
                "environmentId": identity["environmentId"],
                "serviceId": identity["serviceId"],
                "releaseSha": record["releaseSha"],
                "executable": runtime["executable"],
                "cwd": runtime["cwd"],
                "args": runtime["args"],
            }
        except (KeyError, TypeError) as error:
            raise ProcessError("persisted ProcessHandle is structurally incomplete") from error
        if adapter != {"kind": "pm2-programmatic", "version": self.version, "instanceId": self.instance_id}:
            raise ProcessError("persisted ProcessHandle adapter identity mismatch")
        if persisted_fingerprint != invocation_fingerprint(runtime["executable"], runtime["args"], runtime["cwd"]):
            raise ProcessError("persisted ProcessHandle runtime fingerprint mismatch")
        scoped = [
            item for item in self._all_inventory()
            if item["environmentId"] == identity["environmentId"]
            and item["serviceId"] == identity["serviceId"]
            and item["namespace"] == identity["namespace"]
        ]
        if len(scoped) != 1 or scoped[0]["adapterId"] != str(expected["adapterId"]):
            raise ProcessError("persisted ProcessHandle cannot be re-observed exactly")
        observed = scoped[0]
        self._assert_observation(observed, expected, require_live=True)
        handle = self._handle_from_observation(
            observed,
            environment_id=identity["environmentId"],
            service_id=identity["serviceId"],
            release_sha=record["releaseSha"],
            origin="observed",
            observed_at=self._now(),
            sidecar={
                "stableName": observed["name"],
                "listener": {"host": observed["ownedHost"], "port": observed["ownedPort"]},
                "startSpec": self._restore_spec(record, observed),
            },
        )
        return handle

    @staticmethod
    def _assert_observation(observed: dict[str, Any], expected: dict[str, Any], require_live: bool) -> None:
        fields = ("adapterId", "name", "namespace", "environmentId", "serviceId", "releaseSha", "executable", "cwd", "args")
        if any(observed.get(field) != expected.get(field) for field in fields):
            raise ProcessError("PM2 observation does not match exact ProcessHandle")
        if require_live and (
            observed.get("status") != "online"
            or observed.get("pid") != expected.get("pid")
            or not observed.get("evidence")
            or observed["evidence"].get("processStartId") != expected.get("processStartId")
        ):
            raise ProcessError("PM2 live process identity mismatch")

    @staticmethod
    def _overlaps(item: dict[str, Any], candidate: dict[str, Any]) -> bool:
        runtime = candidate["runtime"]
        return (
            (
                item["environmentId"] == candidate["environmentId"]
                and item["serviceId"] == candidate["serviceId"]
                and item["namespace"] == candidate["namespace"]
            )
            or (item["name"] == candidate["stableName"] and item["namespace"] == candidate["namespace"])
            or item["executable"] == runtime["executable"]
            or item["cwd"] == runtime["cwd"]
            or (
                item["ownedHost"] == candidate["listener"]["host"]
                and item["ownedPort"] == int(candidate["listener"]["port"])
            )
        )

    def assert_replaceable(self, current: AdapterHandle, candidate: dict[str, Any]) -> None:
        expected = self._exact_expected(current)
        inventory = self._all_inventory()
        exact = [item for item in inventory if item["adapterId"] == expected["adapterId"]]
        if len(exact) != 1:
            raise ProcessError("authoritative PM2 process is missing or ambiguous")
        self._assert_observation(exact[0], expected, require_live=True)
        overlaps = []
        for item in inventory:
            if item["adapterId"] == expected["adapterId"]:
                continue
            if self._overlaps(item, candidate):
                overlaps.append(item["adapterId"])
        if overlaps:
            raise ProcessError("unexpected overlapping PM2 inventory blocks replacement")

    def stop_exact(self, handle: AdapterHandle) -> None:
        self._bridge({"action": "stop", "expected": self._exact_expected(handle)})

    def delete_exact(self, handle: AdapterHandle) -> None:
        self._bridge({"action": "delete", "expected": self._exact_expected(handle)})

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        return Path(f"/proc/{pid}/stat").exists()

    @staticmethod
    def _port_is_free(host: str, port: int) -> bool:
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        with socket.socket(family, socket.SOCK_STREAM) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind((host, port))
            except OSError:
                return False
        return True

    def await_absent(self, handle: AdapterHandle) -> None:
        expected = self._exact_expected(handle)
        sidecar = self._sidecars.get(handle.record["provenance"]["adapterReceipt"], {})
        listener = sidecar.get("listener") or {}
        for _ in range(100):
            record_absent = all(item["adapterId"] != expected["adapterId"] for item in self._all_inventory())
            pid_dead = not self._pid_alive(expected["pid"])
            port_free = bool(listener.get("host") and listener.get("port")) and self._port_is_free(listener["host"], int(listener["port"]))
            if record_absent and pid_dead and port_free:
                return
            time.sleep(0.05)
        raise ProcessError("exact PM2 absence proof failed")

    def _runtime_environment(self, spec: dict[str, Any]) -> tuple[dict[str, str], list[str]]:
        required = spec["requiredSecretNames"]
        allowed = set(spec["allowedEnvNames"])
        if not set(required).issubset(allowed):
            raise ProcessError("required secret names exceed Release Contract runtime env names")
        source = Path(spec["secretSource"]["sourcePath"])
        try:
            metadata = source.lstat()
        except OSError as error:
            raise ProcessError("external secret source is unavailable") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ProcessError("external secret source must be a regular file")
        if metadata.st_uid != self.secret_owner_uid or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
            raise ProcessError("external secret source ownership or permissions are unsafe")
        try:
            document = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ProcessError("external secret source is invalid") from error
        if not isinstance(document, dict) or any(name not in document or not isinstance(document[name], str) or not document[name] for name in required):
            raise ProcessError("external secret source is missing required names")
        runtime_env = {name: document[name] for name in required}
        runtime_env.update({key: str(value) for key, value in spec["binding"].items()})
        if not set(runtime_env).issubset(allowed):
            raise ProcessError("runtime environment exceeds Release Contract allowlist")
        return runtime_env, [document[name] for name in required]

    def start_candidate(self, spec: dict[str, Any]) -> AdapterHandle:
        runtime_env, sensitive = self._runtime_environment(spec)
        if any(self._overlaps(item, spec) for item in self._all_inventory()):
            raise ProcessError("PM2 inventory is not clear for exact candidate start")
        launch_token = str(uuid.uuid4())
        runtime_env.update({
            "RELEASE_MANAGER_ENVIRONMENT_ID": spec["environmentId"],
            "RELEASE_MANAGER_SERVICE_ID": spec["serviceId"],
            "RELEASE_MANAGER_RELEASE_SHA": spec["releaseSha"],
            "RELEASE_MANAGER_LAUNCH_TOKEN": launch_token,
            "RELEASE_MANAGER_OWNED_HOST": str(spec["listener"]["host"]),
            "RELEASE_MANAGER_OWNED_PORT": str(spec["listener"]["port"]),
        })
        response = self._bridge({
            "action": "start",
            "app": {
                "name": spec["stableName"],
                "namespace": spec["namespace"],
                "script": spec["runtime"]["executable"],
                "args": spec["runtime"]["args"],
                "cwd": spec["runtime"]["cwd"],
                "env": runtime_env,
            },
        }, sensitive)
        observed = response["record"]
        if observed["launchToken"] != launch_token:
            raise ProcessError("PM2 candidate launch identity mismatch")
        sidecar = {
            "stableName": spec["stableName"],
            "listener": {"host": str(spec["listener"]["host"]), "port": int(spec["listener"]["port"])},
            "startSpec": copy.deepcopy(spec),
            "health": copy.deepcopy(spec.get("health")),
        }
        handle = self._handle_from_observation(
            observed,
            environment_id=spec["environmentId"],
            service_id=spec["serviceId"],
            release_sha=spec["releaseSha"],
            origin="started",
            observed_at=spec["observedAt"],
            sidecar=sidecar,
        )
        owned = [
            item for item in self._all_inventory()
            if item["environmentId"] == spec["environmentId"]
            and item["serviceId"] == spec["serviceId"]
            and item["namespace"] == spec["namespace"]
        ]
        if len(owned) != 1 or owned[0]["adapterId"] != handle.record["identity"]["adapterId"]:
            expected = self._exact_expected(handle)
            self._bridge({"action": "stop", "expected": expected})
            self._bridge({"action": "delete", "expected": expected})
            raise ProcessError("candidate start did not produce exactly one owned PM2 record")
        return handle

    def attest(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        expected = self._exact_expected(handle)
        matches = [item for item in self._all_inventory() if item["adapterId"] == expected["adapterId"]]
        if len(matches) != 1:
            raise ProcessError("PM2 process cannot be attested exactly")
        observed = matches[0]
        self._assert_observation(observed, expected, require_live=True)
        evidence = observed["evidence"]
        if handle.record["releaseSha"] != expected_sha:
            raise ProcessError("runtime release SHA mismatch")
        if evidence["procCwd"] != handle.record["runtime"]["cwd"]:
            raise ProcessError("/proc cwd attestation failed")
        if not Path(evidence["procExe"]).is_file() or not evidence["procCmdline"]:
            raise ProcessError("/proc executable evidence is incomplete")
        sidecar = self._sidecars.get(handle.record["provenance"]["adapterReceipt"], {})
        health = sidecar.get("health") or {}
        accepted = set(health.get("acceptedStatusClasses", [2]))
        attempts = int(health.get("attempts", self.health_attempts))
        interval = float(health.get("intervalMs", self.health_interval_seconds * 1000)) / 1000
        results = []
        for target in health_targets:
            status = None
            for _ in range(attempts):
                try:
                    with urllib.request.urlopen(target, timeout=1) as response:
                        status = response.status
                    if status // 100 in accepted:
                        break
                except (urllib.error.URLError, TimeoutError):
                    pass
                time.sleep(interval)
            if status is None or status // 100 not in accepted:
                raise ProcessError("runtime health attestation failed")
            results.append({"target": target, "statusClass": status // 100})
        receipt = handle.record["provenance"]["adapterReceipt"]
        self._attested.add(receipt)
        return {"releaseSha": expected_sha, "health": results, "processStartId": evidence["processStartId"]}

    def restore(self, handle: AdapterHandle) -> AdapterHandle:
        self.assert_handle(handle)
        sidecar = self._sidecars.get(handle.record["provenance"]["adapterReceipt"])
        if not sidecar or not sidecar.get("startSpec"):
            raise ProcessError("exact restore descriptor is unavailable")
        return self.start_candidate(copy.deepcopy(sidecar["startSpec"]))

    def persist(self, handle: AdapterHandle) -> dict[str, Any]:
        self.assert_handle(handle)
        receipt = handle.record["provenance"]["adapterReceipt"]
        if receipt not in self._attested:
            raise ProcessError("PM2 persistence requires prior runtime attestation")
        self._bridge({"action": "save"})
        return {"adapterId": handle.record["identity"]["adapterId"], "persistedAt": self._now()}

    def kill_isolated_daemon(self) -> None:
        self._bridge({"action": "kill-daemon"})
