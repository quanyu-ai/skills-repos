from __future__ import annotations

import copy
import base64
import hashlib
import json
import os
import re
import socket
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .errors import ProcessError
from .ports import AdapterHandle, ManagedReconciliationObservation, invocation_fingerprint
from .contracts import validate_legacy_restore_descriptor


class PM2ProcessAdapter:
    """Linux PM2 adapter using only the programmatic API through a JSON bridge."""

    version = "0.1.0"
    pinned_pm2_version = "7.0.4"
    minimum_node_major = 20
    forbidden_daemon_environment = frozenset({"NODE_CHANNEL_FD", "NODE_UNIQUE_ID"})
    diagnostic_limit_bytes = 16 * 1024
    diagnostic_retention = 5

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
        legacy_restore_descriptor: dict[str, Any] | None = None,
        diagnostics_root: Path | None = None,
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
        self.legacy_restore_descriptor = copy.deepcopy(legacy_restore_descriptor)
        raw_diagnostics_root = (diagnostics_root or (self.pm2_home / "release-manager-diagnostics")).absolute()
        if not raw_diagnostics_root.resolve(strict=False).is_relative_to(self.pm2_home):
            raise ProcessError("PM2 diagnostics root must remain inside PM2_HOME")
        self.diagnostics_root = raw_diagnostics_root
        self.bridge = Path(__file__).resolve().parents[1] / "pm2-adapter" / "bridge.cjs"
        self.issuer = f"pm2-programmatic:{instance_id}"
        self._sidecars: dict[str, dict[str, Any]] = {}
        self._attested: set[str] = set()
        self.version_evidence = self._attest_runtime_versions()

    def _attest_runtime_versions(self) -> dict[str, str]:
        evidence = self._bridge({"action": "runtime-version"})
        pm2_version = evidence.get("pm2PackageVersion")
        node_runtime = evidence.get("nodeRuntime")
        node_executable = evidence.get("nodeExecutable")
        match = re.fullmatch(r"v(\d+)\.\d+\.\d+", str(node_runtime))
        if pm2_version != self.pinned_pm2_version:
            raise ProcessError("loaded PM2 package version does not match the pinned adapter version")
        if not match or int(match.group(1)) < self.minimum_node_major:
            raise ProcessError("loaded Node runtime is outside the supported adapter range")
        if not isinstance(node_executable, str) or not Path(node_executable).is_file():
            raise ProcessError("loaded Node executable is unavailable")
        return {
            "adapterVersion": self.version,
            "pm2PackageVersion": pm2_version,
            "nodeRuntime": node_runtime,
            "nodeExecutable": str(Path(node_executable).resolve()),
        }

    def _validate_daemon_evidence(self, evidence: dict[str, Any]) -> dict[str, Any]:
        try:
            version = evidence["daemonPm2Version"]
            pid = int(evidence["daemonPid"])
            process_start_id = evidence["daemonProcessStartId"]
            node_executable = str(Path(evidence["daemonNodeExecutable"]).resolve(strict=True))
            node_runtime = evidence["daemonNodeRuntime"]
            ambient_names = evidence["ambientEnvironmentNames"]
            forbidden = evidence["forbiddenAmbientNames"]
        except (KeyError, TypeError, ValueError, OSError) as error:
            raise ProcessError("connected PM2 daemon attestation is incomplete") from error
        if version != self.pinned_pm2_version:
            raise ProcessError("connected PM2 daemon version does not match the pinned adapter version")
        if pid <= 0 or not re.fullmatch(r"[a-f0-9-]{36}:[1-9][0-9]*", str(process_start_id)):
            raise ProcessError("connected PM2 daemon process identity is invalid")
        if not isinstance(ambient_names, list) or any(not isinstance(name, str) for name in ambient_names):
            raise ProcessError("connected PM2 daemon ambient environment evidence is invalid")
        detected = sorted(self.forbidden_daemon_environment.intersection(ambient_names))
        if sorted(forbidden) != detected:
            raise ProcessError("connected PM2 daemon forbidden-environment evidence is inconsistent")
        if detected:
            raise ProcessError(f"connected PM2 daemon contains forbidden ambient variables: {detected}")
        if node_executable != self.version_evidence["nodeExecutable"]:
            raise ProcessError("connected PM2 daemon Node executable differs from the trusted adapter runtime")
        match = re.fullmatch(r"v(\d+)\.\d+\.\d+", str(node_runtime))
        if not match or int(match.group(1)) < self.minimum_node_major:
            raise ProcessError("connected PM2 daemon Node runtime is outside the supported adapter range")
        return {
            "daemonPm2Version": version,
            "daemonPid": pid,
            "daemonProcessStartId": process_start_id,
            "daemonNodeExecutable": node_executable,
            "daemonNodeRuntime": node_runtime,
            "ambientEnvironmentNameDigest": self._raw_record_digest(sorted(ambient_names)),
            "forbiddenAmbientNames": [],
        }

    def attest_connected_daemon(self) -> dict[str, Any]:
        evidence = self._bridge({"action": "daemon-attestation"})
        return self._validate_daemon_evidence(evidence.get("daemon", {}))

    def bootstrap_pinned_daemon(self, *, restart: bool = False) -> dict[str, Any]:
        evidence = self._bridge({"action": "bootstrap-daemon", "restart": restart})
        daemon = self._validate_daemon_evidence(evidence.get("daemon", {}))
        if evidence.get("daemon", {}).get("dumpPreserved") is not True:
            raise ProcessError("pinned PM2 daemon bootstrap did not preserve the persisted dump")
        daemon["dumpDigest"] = evidence["daemon"].get("dumpDigest")
        daemon["dumpPreserved"] = True
        return daemon

    def _require_governed_daemon(self) -> dict[str, Any]:
        return self.attest_connected_daemon()

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def _redact(text: str, values: list[str]) -> str:
        variants = set()
        for value in values:
            if not value:
                continue
            variants.update({
                value,
                json.dumps(value, ensure_ascii=False)[1:-1],
                urllib.parse.quote(value, safe=""),
                base64.b64encode(value.encode()).decode(),
            })
        for value in sorted(variants, key=len, reverse=True):
            text = text.replace(value, "[REDACTED]")
        text = re.sub(r"(?i)(postgres(?:ql)?://)[^\s'\"`]+", r"\1[REDACTED]", text)
        return text

    def _prepare_diagnostics(self, launch_token: str) -> tuple[Path, Path]:
        root = self.diagnostics_root
        if root.exists():
            metadata = root.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise ProcessError("PM2 diagnostics root must be a regular directory")
            if metadata.st_uid != self.secret_owner_uid or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ProcessError("PM2 diagnostics root ownership or permissions are unsafe")
        else:
            root.mkdir(parents=True, mode=0o700)
            metadata = root.lstat()
            if metadata.st_uid != self.secret_owner_uid or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ProcessError("PM2 diagnostics root ownership or permissions are unsafe")
        paths = (root / f"{launch_token}.stdout.raw", root / f"{launch_token}.stderr.raw")
        for path in paths:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
        return paths

    @staticmethod
    def _diagnostic_categories(text: str) -> list[str]:
        patterns = {
            "address-in-use": r"EADDRINUSE|address already in use",
            "artifact-not-found": r"Could not find a production build|BUILD_ID|ENOENT.*\.next",
            "module-not-found": r"MODULE_NOT_FOUND|Cannot find module",
            "permission-or-readonly": r"EACCES|EPERM|EROFS|permission denied|read-only file system",
            "node-abort-or-oom": r"FATAL ERROR|heap out of memory|SIGABRT|Assertion failed",
            "database": r"Prisma|database|ECONNREFUSED.*5432",
            "runtime": r"Error|exception|failed|invalid",
        }
        return sorted(name for name, pattern in patterns.items() if re.search(pattern, text, re.IGNORECASE)) or ["unclassified"]

    def _bounded_redacted_tail(self, path: Path, sensitive: list[str]) -> str:
        overlap = max((len(value.encode()) for value in sensitive if value), default=0)
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - self.diagnostic_limit_bytes - overlap))
            raw = stream.read()
        redacted = self._redact(raw.decode("utf-8", "replace"), sensitive)
        return redacted[-self.diagnostic_limit_bytes:]

    def _finalize_failed_diagnostics(
        self,
        launch_token: str,
        paths: tuple[Path, Path],
        sensitive: list[str],
        observed: dict[str, Any] | None,
    ) -> dict[str, Any]:
        stdout = self._bounded_redacted_tail(paths[0], sensitive)
        stderr = self._bounded_redacted_tail(paths[1], sensitive)
        for path in paths:
            path.unlink(missing_ok=True)
        record = {
            "apiVersion": "quanyu.ai/pm2-start-diagnostic/v1alpha1",
            "kind": "Pm2StartDiagnostic",
            "capturedAt": self._now(),
            "launchTokenDigest": self._raw_record_digest({"launchToken": launch_token}),
            "exitCode": None if observed is None else observed.get("exitCode"),
            "exitSignal": None if observed is None else observed.get("exitSignal"),
            "categories": self._diagnostic_categories(stdout + "\n" + stderr),
            "stdoutTail": stdout,
            "stderrTail": stderr,
            "truncatedToBytes": self.diagnostic_limit_bytes,
        }
        destination = self.diagnostics_root / f"failure-{launch_token}.json"
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(record, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        retained = sorted(self.diagnostics_root.glob("failure-*.json"), key=lambda item: item.stat().st_mtime_ns, reverse=True)
        for stale in retained[self.diagnostic_retention:]:
            stale.unlink()
        return {
            "record": str(destination),
            "categories": record["categories"],
            "exitCode": record["exitCode"],
            "exitSignal": record["exitSignal"],
        }

    @staticmethod
    def _discard_diagnostics(paths: tuple[Path, Path]) -> None:
        for path in paths:
            path.unlink(missing_ok=True)

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
        if sidecar.get("configurationDigests"):
            record["configurationDigests"] = copy.deepcopy(sidecar["configurationDigests"])
        if sidecar.get("legacyDescriptorDigest"):
            record["legacyRestoreDescriptorDigest"] = sidecar["legacyDescriptorDigest"]
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
        response = self._bridge({"action": "inventory"})
        self._validate_daemon_evidence(response.get("daemon", {}))
        return response["records"]

    def inventory(self, environment_id: str, service_id: str, namespace: str) -> list[AdapterHandle]:
        self._require_governed_daemon()
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
                        "configurationDigests": {
                            "releaseContract": observed["releaseContractDigest"],
                            "environmentPolicy": observed["environmentPolicyDigest"],
                            "build": observed["buildConfigDigest"],
                            "runtime": observed["runtimeConfigDigest"],
                        } if all(observed.get(name) for name in ("releaseContractDigest", "environmentPolicyDigest", "buildConfigDigest", "runtimeConfigDigest")) else None,
                    },
                ))
        return handles

    def _exact_expected(self, handle: AdapterHandle) -> dict[str, Any]:
        self.assert_handle(handle)
        record = handle.record
        sidecar = self._sidecars.get(record["provenance"]["adapterReceipt"], {})
        observed_ownership = sidecar.get("observedOwnership") or {}
        return {
            "adapterId": record["identity"]["adapterId"],
            "pid": record["identity"]["pid"],
            "processStartId": record["identity"]["processStartId"],
            "name": sidecar.get("stableName", self.stable_name),
            "namespace": record["identity"]["namespace"],
            "environmentId": observed_ownership.get("environmentId", record["identity"]["environmentId"]),
            "serviceId": observed_ownership.get("serviceId", record["identity"]["serviceId"]),
            "releaseSha": observed_ownership.get("releaseSha", record["releaseSha"]),
            **record["runtime"],
            "buildConfigDigest": observed_ownership.get("buildConfigDigest", record.get("configurationDigests", {}).get("build")),
            "runtimeConfigDigest": observed_ownership.get("runtimeConfigDigest", record.get("configurationDigests", {}).get("runtime")),
            "releaseContractDigest": observed_ownership.get("releaseContractDigest", record.get("configurationDigests", {}).get("releaseContract")),
            "environmentPolicyDigest": observed_ownership.get("environmentPolicyDigest", record.get("configurationDigests", {}).get("environmentPolicy")),
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
            "nonSecretValues": copy.deepcopy(self.runtime_policy["nonSecretValues"]),
            "configurationDigests": copy.deepcopy(record.get("configurationDigests")),
        }

    @staticmethod
    def _descriptor_digest(descriptor: dict[str, Any]) -> str:
        payload = json.dumps(descriptor, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    def _validate_observed_authority(self, descriptor: dict[str, Any]) -> None:
        try:
            observed = descriptor["observedAuthority"]
        except (KeyError, TypeError) as error:
            raise ProcessError("legacy observed authority is structurally incomplete") from error
        release_raw = Path(observed["releasePath"])
        release_meta = release_raw.lstat()
        if stat.S_ISLNK(release_meta.st_mode) or not stat.S_ISDIR(release_meta.st_mode): raise ProcessError("legacy release path must be a regular directory")
        if release_meta.st_uid not in (0, self.secret_owner_uid) or stat.S_IMODE(release_meta.st_mode) & 0o022: raise ProcessError("legacy release path ownership or permissions are unsafe")
        release = release_raw.resolve(strict=True)
        checks = (
            (Path(observed["invocation"]["executable"]), "file"),
            (Path(observed["invocation"]["cwd"]), "dir"),
        )
        for raw, kind in checks:
            metadata = raw.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ProcessError("legacy authority path cannot be a symlink")
            resolved = raw.resolve(strict=True)
            if metadata.st_uid not in (0, self.secret_owner_uid) or stat.S_IMODE(metadata.st_mode) & 0o022:
                raise ProcessError("legacy authority path ownership or permissions are unsafe")
            if kind == "file" and not resolved.is_file(): raise ProcessError("legacy authority executable is not a regular file")
            if kind == "dir" and not resolved.is_dir(): raise ProcessError("legacy authority cwd is not a directory")
        contained = (
            Path(observed["invocation"]["executable"]),
            Path(observed["invocation"]["cwd"]),
        )
        if any(not item.resolve().is_relative_to(release) for item in contained):
            raise ProcessError("legacy authority path escapes release path")

    def _validate_restore_recipe(self, descriptor: dict[str, Any]) -> None:
        validate_legacy_restore_descriptor(descriptor)
        observed = descriptor["observedAuthority"]
        recipe = descriptor["restoreRecipe"]
        release_raw = Path(observed["releasePath"])
        release_meta = release_raw.lstat()
        if stat.S_ISLNK(release_meta.st_mode) or not stat.S_ISDIR(release_meta.st_mode): raise ProcessError("legacy release path must be a regular directory")
        if release_meta.st_uid not in (0, self.secret_owner_uid) or stat.S_IMODE(release_meta.st_mode) & 0o022: raise ProcessError("legacy release path ownership or permissions are unsafe")
        release = release_raw.resolve(strict=True)
        checks = (
            (Path(recipe["bootstrap"]["executable"]), "file"),
            (Path(recipe["bootstrap"]["cwd"]), "dir"),
            (Path(recipe["payload"]["executable"]), "file"),
            (Path(recipe["payload"]["cwd"]), "dir"),
        )
        for raw, kind in checks:
            metadata = raw.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ProcessError("legacy restore path cannot be a symlink")
            resolved = raw.resolve(strict=True)
            if metadata.st_uid not in (0, self.secret_owner_uid) or stat.S_IMODE(metadata.st_mode) & 0o022:
                raise ProcessError("legacy restore path ownership or permissions are unsafe")
            if kind == "file" and not resolved.is_file(): raise ProcessError("legacy restore executable is not a regular file")
            if kind == "dir" and not resolved.is_dir(): raise ProcessError("legacy restore cwd is not a directory")
        contained = (
            Path(recipe["bootstrap"]["cwd"]),
            Path(recipe["payload"]["executable"]),
            Path(recipe["payload"]["cwd"]),
        )
        if any(not item.resolve().is_relative_to(release) for item in contained):
            raise ProcessError("legacy invocation path escapes release path")
        self._load_secret_document(recipe["secrets"])

    def _load_secret_document(self, source_spec: dict[str, Any]) -> tuple[dict[str, str], list[str]]:
        source = Path(source_spec["sourcePath"])
        try: metadata = source.lstat()
        except OSError as error: raise ProcessError("external secret source is unavailable") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode): raise ProcessError("external secret source must be a regular file")
        if metadata.st_uid != self.secret_owner_uid or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600): raise ProcessError("external secret source ownership or permissions are unsafe")
        try: document = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error: raise ProcessError("external secret source is invalid") from error
        required = source_spec["requiredNames"]
        if not isinstance(document, dict) or any(name not in document or not isinstance(document[name], str) or not document[name] for name in required): raise ProcessError("external secret source is missing required names")
        return {name: document[name] for name in required}, [document[name] for name in required]

    def _legacy_environment(self, descriptor: dict[str, Any], listener: dict[str, Any]) -> dict[str, str]:
        recipe = descriptor["restoreRecipe"]
        runtime = recipe["runtime"]
        payload = recipe["payload"]
        values = {item["name"]: item["value"] for item in runtime["nonSecretValues"]}
        secret_names = runtime["requiredSecretNames"]
        if runtime["requiredSecretNamesFormat"] == "json-array":
            encoded_secret_names = json.dumps(secret_names, separators=(",", ":"))
        else:
            encoded_secret_names = ",".join(secret_names)
        values.update({
            "LEGACY_EXECUTABLE": payload["executable"],
            "LEGACY_ARGS_JSON": json.dumps(payload["args"], separators=(",", ":")),
            "LEGACY_HOST": listener["host"],
            "LEGACY_INTERNAL_PORT": str(listener["port"]),
            "REQUIRED_RUNTIME_SECRETS": encoded_secret_names,
            "RUNTIME_SECRET_FILE": runtime["runtimeSecretFile"],
        })
        return values

    def preflight_legacy_restore(self, descriptor: dict[str, Any]) -> dict[str, Any]:
        self._require_governed_daemon()
        self._validate_restore_recipe(descriptor)
        observed_authority = descriptor["observedAuthority"]
        recipe = descriptor["restoreRecipe"]
        if recipe["probe"]["port"] == recipe["listener"]["port"]: raise ProcessError("legacy restore probe must use a non-business port")
        if not self._port_is_free(recipe["probe"]["host"], int(recipe["probe"]["port"])): raise ProcessError("legacy restore probe port is unavailable")
        token = str(uuid.uuid4())
        env = self._legacy_environment(descriptor, recipe["probe"])
        env.update({"RELEASE_MANAGER_ENVIRONMENT_ID": descriptor["metadata"]["environmentId"] + "-probe", "RELEASE_MANAGER_SERVICE_ID": descriptor["metadata"]["serviceId"], "RELEASE_MANAGER_RELEASE_SHA": observed_authority["releaseSha"], "RELEASE_MANAGER_LAUNCH_TOKEN": token, "RELEASE_MANAGER_OWNED_HOST": recipe["probe"]["host"], "RELEASE_MANAGER_OWNED_PORT": str(recipe["probe"]["port"])})
        observed = None
        handle = None
        try:
            observed = self._bridge({"action": "start", "app": {"name": observed_authority["stableName"] + "-restore-probe-" + token[:8], "namespace": observed_authority["namespace"], "script": recipe["bootstrap"]["executable"], "args": recipe["bootstrap"]["args"], "cwd": recipe["bootstrap"]["cwd"], "env": env}})["record"]
            handle = self._handle_from_observation(observed, environment_id=descriptor["metadata"]["environmentId"] + "-probe", service_id=descriptor["metadata"]["serviceId"], release_sha=observed_authority["releaseSha"], origin="started", observed_at=self._now(), sidecar={"stableName": observed["name"], "listener": recipe["probe"], "health": descriptor["health"]})
            url = f"http://{recipe['probe']['host']}:{recipe['probe']['port']}{descriptor['health']['path']}"
            self.attest(handle, observed_authority["releaseSha"], (url, url))
        finally:
            if handle is not None:
                self._remove_probe_exact(handle, token)
            elif observed is not None:
                expected = {**observed, "processStartId": observed["evidence"]["processStartId"]}
                self._bridge({"action": "stop", "expected": expected}); self._bridge({"action": "delete", "expected": expected})
        return {"descriptorDigest": self._descriptor_digest(descriptor), "probe": "pass"}

    def _remove_probe_exact(self, handle: AdapterHandle, launch_token: str) -> None:
        """Remove a disposable probe even when it exited before health attestation."""
        expected = self._exact_expected(handle)
        matches = [
            item for item in self._all_inventory()
            if item["adapterId"] == expected["adapterId"]
            and item.get("launchToken") == launch_token
        ]
        if len(matches) != 1:
            raise ProcessError("legacy restore probe cannot be identified exactly for cleanup")
        observed = matches[0]
        self._assert_observation(observed, expected, require_live=False)
        if observed["status"] == "online":
            live = self._handle_from_observation(
                observed,
                environment_id=handle.record["identity"]["environmentId"],
                service_id=handle.record["identity"]["serviceId"],
                release_sha=handle.record["releaseSha"],
                origin="observed",
                observed_at=self._now(),
                sidecar=self._sidecars[handle.record["provenance"]["adapterReceipt"]],
            )
            self.stop_exact(live)
            matches = [
                item for item in self._all_inventory()
                if item["adapterId"] == expected["adapterId"]
                and item.get("launchToken") == launch_token
            ]
            if len(matches) != 1:
                raise ProcessError("legacy restore probe disappeared before exact delete")
            observed = matches[0]
            self._assert_observation(observed, expected, require_live=False)
        self._bridge({"action": "delete", "expected": observed})
        self.await_absent(handle)

    def observe_legacy(self, spec: dict[str, Any]) -> AdapterHandle:
        self._require_governed_daemon()
        self._validate_observed_authority(spec)
        authority = spec["observedAuthority"]
        invocation = authority["invocation"]
        matches = []
        for observed in self._all_inventory():
            if (
                observed["status"] == "online"
                and observed["adapterId"] == authority["adapterId"]
                and observed["pid"] == authority["pid"]
                and observed.get("evidence", {}).get("processStartId") == authority["processStartId"]
                and observed["namespace"] == authority["namespace"]
                and observed["name"] == authority["stableName"]
                and observed["executable"] == str(Path(invocation["executable"]).resolve())
                and observed["cwd"] == str(Path(invocation["cwd"]).resolve())
                and observed["args"] == invocation["args"]
            ):
                matches.append(observed)
        if len(matches) != 1:
            raise ProcessError(f"legacy observation expected one exact process, found {len(matches)}")
        observed = matches[0]
        return self._handle_from_observation(
            observed,
            environment_id=spec["metadata"]["environmentId"],
            service_id=spec["metadata"]["serviceId"],
            release_sha=authority["releaseSha"],
            origin="observed",
            observed_at=self._now(),
            sidecar={
                "stableName": observed["name"],
                "listener": copy.deepcopy(authority["listener"]),
                "legacyDescriptor": copy.deepcopy(spec),
                "legacyDescriptorDigest": self._descriptor_digest(spec),
                "observedOwnership": {"environmentId": observed["environmentId"], "serviceId": observed["serviceId"], "releaseSha": observed["releaseSha"], "buildConfigDigest": observed.get("buildConfigDigest"), "runtimeConfigDigest": observed.get("runtimeConfigDigest"), "releaseContractDigest": observed.get("releaseContractDigest"), "environmentPolicyDigest": observed.get("environmentPolicyDigest")},
            },
        )

    def resolve_persisted(self, record: dict[str, Any]) -> AdapterHandle:
        self._require_governed_daemon()
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
                "buildConfigDigest": record.get("configurationDigests", {}).get("build"),
                "runtimeConfigDigest": record.get("configurationDigests", {}).get("runtime"),
                "releaseContractDigest": record.get("configurationDigests", {}).get("releaseContract"),
                "environmentPolicyDigest": record.get("configurationDigests", {}).get("environmentPolicy"),
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
        is_legacy = record.get("provenance", {}).get("origin") == "observed" and "legacyRestoreDescriptorDigest" in record
        if is_legacy:
            descriptor = self.legacy_restore_descriptor
            if descriptor is None or self._descriptor_digest(descriptor) != record["legacyRestoreDescriptorDigest"]:
                raise ProcessError("persisted legacy handle requires its exact external restore descriptor")
            self._validate_observed_authority(descriptor)
            expected["name"] = descriptor["observedAuthority"]["stableName"]
            scoped = [item for item in self._all_inventory() if item["adapterId"] == str(expected["adapterId"])]
        else:
            scoped = [
            item for item in self._all_inventory()
            if item["environmentId"] == identity["environmentId"]
            and item["serviceId"] == identity["serviceId"]
            and item["namespace"] == identity["namespace"]
            ]
        if len(scoped) != 1 or scoped[0]["adapterId"] != str(expected["adapterId"]):
            raise ProcessError("persisted ProcessHandle cannot be re-observed exactly")
        observed = scoped[0]
        self._assert_observation(observed, expected, require_live=True, compare_ownership=not is_legacy)
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
                "startSpec": None if is_legacy else self._restore_spec(record, observed),
                "configurationDigests": copy.deepcopy(record.get("configurationDigests")),
                "legacyDescriptor": copy.deepcopy(descriptor) if is_legacy else None,
                "legacyDescriptorDigest": record.get("legacyRestoreDescriptorDigest"),
                "observedOwnership": {"environmentId": observed["environmentId"], "serviceId": observed["serviceId"], "releaseSha": observed["releaseSha"], "buildConfigDigest": observed.get("buildConfigDigest"), "runtimeConfigDigest": observed.get("runtimeConfigDigest"), "releaseContractDigest": observed.get("releaseContractDigest"), "environmentPolicyDigest": observed.get("environmentPolicyDigest")} if is_legacy else None,
            },
        )
        return handle

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

    @staticmethod
    def _current_boot_id() -> str:
        try:
            boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="utf-8").strip()
            uuid.UUID(boot_id)
        except (OSError, ValueError) as error:
            raise ProcessError("current Linux boot identity is unavailable") from error
        return boot_id

    @staticmethod
    def _assert_release_containment(release_path: str, runtime: dict[str, Any]) -> None:
        try:
            raw_release = Path(release_path)
            metadata = raw_release.lstat()
            release = raw_release.resolve(strict=True)
            executable = Path(runtime["executable"]).resolve(strict=True)
            cwd = Path(runtime["cwd"]).resolve(strict=True)
        except (KeyError, OSError) as error:
            raise ProcessError("managed release/runtime path is unavailable") from error
        if stat.S_ISLNK(metadata.st_mode) or not release.is_dir():
            raise ProcessError("managed release path must be a canonical directory")
        if not executable.is_file() or not cwd.is_dir() or not executable.is_relative_to(release) or not cwd.is_relative_to(release):
            raise ProcessError("managed runtime escapes release path")
        if str(executable) != runtime["executable"] or str(cwd) != runtime["cwd"]:
            raise ProcessError("managed runtime paths must be canonical")

    def observe_managed_after_host_restart(
        self, record: dict[str, Any], expected: dict[str, Any]
    ) -> ManagedReconciliationObservation:
        """Mint fresh evidence without weakening exact persisted-handle resolution."""
        self._require_governed_daemon()
        try:
            adapter = record["adapter"]
            identity = record["identity"]
            runtime = record["runtime"]
            persisted_digests = record["configurationDigests"]
            expected_runtime = expected["runtime"]
            expected_digests = expected["configurationDigests"]
            expected_listener = expected["listener"]
        except (KeyError, TypeError) as error:
            raise ProcessError("managed reconciliation evidence is structurally incomplete") from error
        if adapter != {"kind": "pm2-programmatic", "version": self.version, "instanceId": self.instance_id}:
            raise ProcessError("persisted ProcessHandle adapter identity mismatch")
        if record.get("invocationFingerprint") != invocation_fingerprint(runtime["executable"], runtime["args"], runtime["cwd"]):
            raise ProcessError("persisted ProcessHandle runtime fingerprint mismatch")
        durable_persisted = (
            (identity["environmentId"], expected["environmentId"]),
            (identity["serviceId"], expected["serviceId"]),
            (identity["namespace"], expected["namespace"]),
            (record["releaseSha"], expected["releaseSha"]),
            (runtime, expected_runtime),
            (persisted_digests, expected_digests),
            (self.stable_name, expected["stableName"]),
        )
        if any(actual != wanted for actual, wanted in durable_persisted):
            raise ProcessError("persisted managed authority does not match reconciliation context")
        self._assert_release_containment(expected["releasePath"], runtime)

        old_boot_id = self._boot_id(identity["processStartId"])
        current_boot_id = self._current_boot_id()
        inventory = self._all_inventory()
        scoped = [
            item for item in inventory
            if item["environmentId"] == expected["environmentId"]
            and item["serviceId"] == expected["serviceId"]
            and item["namespace"] == expected["namespace"]
        ]
        if len(scoped) != 1 or scoped[0].get("status") != "online":
            raise ProcessError("managed reconciliation requires exactly one scoped live process")
        observed = scoped[0]
        live_boot_id = self._boot_id(observed.get("evidence", {}).get("processStartId"))
        if live_boot_id != current_boot_id:
            raise ProcessError("live process boot identity does not match current host boot")
        wanted = {
            "name": expected["stableName"],
            "namespace": expected["namespace"],
            "environmentId": expected["environmentId"],
            "serviceId": expected["serviceId"],
            "releaseSha": expected["releaseSha"],
            "executable": expected_runtime["executable"],
            "cwd": expected_runtime["cwd"],
            "args": expected_runtime["args"],
            "buildConfigDigest": expected_digests["build"],
            "runtimeConfigDigest": expected_digests["runtime"],
            "releaseContractDigest": expected_digests["releaseContract"],
            "environmentPolicyDigest": expected_digests["environmentPolicy"],
        }
        if any(observed.get(field) != value for field, value in wanted.items()):
            raise ProcessError("live managed process does not match durable authority")
        if (
            observed.get("ownedHost") != expected_listener["host"]
            or observed.get("ownedPort") != int(expected_listener["port"])
        ):
            raise ProcessError("live managed listener/topology mismatch")
        self._assert_release_containment(expected["releasePath"], {
            "executable": observed["executable"], "args": observed["args"], "cwd": observed["cwd"]
        })
        overlap_spec = {
            "environmentId": expected["environmentId"],
            "serviceId": expected["serviceId"],
            "namespace": expected["namespace"],
            "stableName": expected["stableName"],
            "runtime": expected_runtime,
            "listener": expected_listener,
        }
        if any(item["adapterId"] != observed["adapterId"] and self._overlaps(item, overlap_spec) for item in inventory):
            raise ProcessError("unexpected overlapping PM2 inventory blocks reconciliation")

        same_identity = (
            observed["adapterId"] == str(identity["adapterId"])
            and observed["pid"] == identity["pid"]
            and observed["evidence"]["processStartId"] == identity["processStartId"]
        )
        if not same_identity and old_boot_id == current_boot_id:
            raise ProcessError("same-boot process identity change cannot be reconciled")
        if not same_identity and old_boot_id == live_boot_id:
            raise ProcessError("host reboot boundary is not proven")
        handle = self._handle_from_observation(
            observed,
            environment_id=expected["environmentId"],
            service_id=expected["serviceId"],
            release_sha=expected["releaseSha"],
            origin="observed",
            observed_at=expected["observedAt"],
            sidecar={
                "stableName": expected["stableName"],
                "listener": copy.deepcopy(expected_listener),
                "startSpec": self._restore_spec(record, observed),
                "health": copy.deepcopy(expected["health"]),
                "configurationDigests": copy.deepcopy(expected_digests),
            },
        )
        return ManagedReconciliationObservation(
            handle, not same_identity, old_boot_id, current_boot_id, copy.deepcopy(expected_listener)
        )

    @staticmethod
    def _assert_observation(observed: dict[str, Any], expected: dict[str, Any], require_live: bool, compare_ownership: bool = True) -> None:
        fields = ["adapterId", "name", "namespace", "executable", "cwd", "args"]
        if compare_ownership: fields.extend(("environmentId", "serviceId", "releaseSha", "buildConfigDigest", "runtimeConfigDigest", "releaseContractDigest", "environmentPolicyDigest"))
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
        self._require_governed_daemon()
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
        self._require_governed_daemon()
        self._bridge({"action": "stop", "expected": self._exact_expected(handle)})

    def delete_exact(self, handle: AdapterHandle) -> None:
        self._require_governed_daemon()
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
        self._require_governed_daemon()
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
        runtime_env, sensitive = self._load_secret_document({"sourcePath": spec["secretSource"]["sourcePath"], "requiredNames": required})
        non_secret = {item["name"]: item["value"] for item in spec["nonSecretValues"]}
        sources = (set(runtime_env), set(non_secret), set(spec["binding"]))
        if any(sources[i] & sources[j] for i in range(3) for j in range(i + 1, 3)): raise ProcessError("runtime environment sources overlap")
        runtime_env.update(non_secret)
        runtime_env.update({key: str(value) for key, value in spec["binding"].items()})
        if set(runtime_env) != allowed: raise ProcessError("runtime environment sources are incomplete or undeclared")
        return runtime_env, sensitive

    def validate_runtime_spec(self, spec: dict[str, Any]) -> None:
        if "releasePath" in spec:
            self._assert_release_containment(spec["releasePath"], spec["runtime"])
        self._runtime_environment(spec)

    @staticmethod
    def _raw_record_digest(record: dict[str, Any]) -> str:
        payload = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    def _assert_raw_owned_candidate(
        self,
        observed: dict[str, Any],
        spec: dict[str, Any],
        *,
        launch_token: str | None,
        require_pidless: bool,
    ) -> None:
        token = observed.get("launchToken")
        try:
            parsed = uuid.UUID(str(token))
        except (ValueError, AttributeError) as error:
            raise ProcessError("raw PM2 candidate launch token is invalid") from error
        if parsed.version != 4 or (launch_token is not None and token != launch_token):
            raise ProcessError("raw PM2 candidate launch token mismatch")
        expected = {
            "name": spec["stableName"],
            "namespace": spec["namespace"],
            "environmentId": spec["environmentId"],
            "serviceId": spec["serviceId"],
            "releaseSha": spec["releaseSha"],
            "executable": spec["runtime"]["executable"],
            "cwd": spec["runtime"]["cwd"],
            "args": spec["runtime"]["args"],
            "ownedHost": str(spec["listener"]["host"]),
            "ownedPort": int(spec["listener"]["port"]),
            "buildConfigDigest": spec["configurationDigests"]["build"],
            "runtimeConfigDigest": spec["configurationDigests"]["runtime"],
            "releaseContractDigest": spec["configurationDigests"]["releaseContract"],
            "environmentPolicyDigest": spec["configurationDigests"]["environmentPolicy"],
        }
        if any(observed.get(field) != value for field, value in expected.items()):
            raise ProcessError("raw PM2 candidate does not match pending activation context")
        if "releasePath" in spec:
            self._assert_release_containment(spec["releasePath"], spec["runtime"])
        if require_pidless and (observed.get("pid") != 0 or observed.get("evidence") is not None):
            raise ProcessError("raw PM2 orphan unexpectedly has live process evidence")

    def _delete_raw_owned_candidate(
        self,
        observed: dict[str, Any],
        spec: dict[str, Any],
        *,
        launch_token: str | None,
    ) -> dict[str, Any]:
        self._assert_raw_owned_candidate(
            observed, spec, launch_token=launch_token, require_pidless=True
        )
        expected = copy.deepcopy(observed)
        self._bridge({"action": "delete-raw-owned", "expected": expected})
        for _ in range(100):
            inventory = self._all_inventory()
            if (
                all(item["adapterId"] != observed["adapterId"] for item in inventory)
                and not any(self._overlaps(item, spec) for item in inventory)
                and self._port_is_free(spec["listener"]["host"], int(spec["listener"]["port"]))
            ):
                return {
                    "adapterId": observed["adapterId"],
                    "orphanRecordDigest": self._raw_record_digest(observed),
                    "launchTokenDigest": self._raw_record_digest({"launchToken": observed["launchToken"]}),
                }
            time.sleep(0.05)
        raise ProcessError("raw PM2 orphan absence proof failed")

    def remove_interrupted_candidate(self, spec: dict[str, Any]) -> dict[str, Any]:
        self._require_governed_daemon()
        if "releasePath" not in spec:
            raise ProcessError("interrupted activation candidate root is unavailable")
        inventory = self._all_inventory()
        overlaps = [item for item in inventory if self._overlaps(item, spec)]
        exact = []
        for item in overlaps:
            try:
                self._assert_raw_owned_candidate(
                    item, spec, launch_token=None, require_pidless=True
                )
            except ProcessError:
                continue
            exact.append(item)
        if len(exact) != 1 or len(overlaps) != 1:
            raise ProcessError("interrupted activation raw PM2 inventory is ambiguous")
        return self._delete_raw_owned_candidate(exact[0], spec, launch_token=None)

    def start_candidate(self, spec: dict[str, Any]) -> AdapterHandle:
        self._require_governed_daemon()
        runtime_env, sensitive = self._runtime_environment(spec)
        if any(self._overlaps(item, spec) for item in self._all_inventory()):
            raise ProcessError("PM2 inventory is not clear for exact candidate start")
        launch_token = str(uuid.uuid4())
        diagnostic_paths = self._prepare_diagnostics(launch_token)
        runtime_env.update({
            "RELEASE_MANAGER_ENVIRONMENT_ID": spec["environmentId"],
            "RELEASE_MANAGER_SERVICE_ID": spec["serviceId"],
            "RELEASE_MANAGER_RELEASE_SHA": spec["releaseSha"],
            "RELEASE_MANAGER_LAUNCH_TOKEN": launch_token,
            "RELEASE_MANAGER_OWNED_HOST": str(spec["listener"]["host"]),
            "RELEASE_MANAGER_OWNED_PORT": str(spec["listener"]["port"]),
            "RELEASE_MANAGER_BUILD_CONFIG_DIGEST": spec["configurationDigests"]["build"],
            "RELEASE_MANAGER_RUNTIME_CONFIG_DIGEST": spec["configurationDigests"]["runtime"],
            "RELEASE_MANAGER_RELEASE_CONTRACT_DIGEST": spec["configurationDigests"]["releaseContract"],
            "RELEASE_MANAGER_ENVIRONMENT_POLICY_DIGEST": spec["configurationDigests"]["environmentPolicy"],
        })
        try:
            response = self._bridge({
                "action": "start",
                "app": {
                    "name": spec["stableName"],
                    "namespace": spec["namespace"],
                    "script": spec["runtime"]["executable"],
                    "args": spec["runtime"]["args"],
                    "cwd": spec["runtime"]["cwd"],
                    "env": runtime_env,
                    "outFile": str(diagnostic_paths[0]),
                    "errorFile": str(diagnostic_paths[1]),
                },
            }, sensitive)
        except Exception as error:
            diagnostics = self._finalize_failed_diagnostics(launch_token, diagnostic_paths, sensitive, None)
            raise ProcessError(
                f"PM2 candidate start failed; bounded diagnostics categories={diagnostics['categories']}"
            ) from error
        observed = response["record"]
        if observed["launchToken"] != launch_token:
            diagnostics = self._finalize_failed_diagnostics(launch_token, diagnostic_paths, sensitive, observed)
            raise ProcessError("PM2 candidate launch identity mismatch")
        sidecar = {
            "stableName": spec["stableName"],
            "listener": {"host": str(spec["listener"]["host"]), "port": int(spec["listener"]["port"])},
            "startSpec": copy.deepcopy(spec),
            "health": copy.deepcopy(spec.get("health")),
            "configurationDigests": copy.deepcopy(spec["configurationDigests"]),
        }
        original_failure = ProcessError("PM2 observation lacks live /proc evidence")
        handle = None
        for _ in range(50):
            matches = [
                item for item in self._all_inventory()
                if item.get("launchToken") == launch_token
            ]
            if len(matches) > 1:
                self._finalize_failed_diagnostics(launch_token, diagnostic_paths, sensitive, None)
                raise ProcessError("candidate launch token matched multiple PM2 records")
            if len(matches) == 1:
                observed = matches[0]
                self._assert_raw_owned_candidate(
                    observed, spec, launch_token=launch_token, require_pidless=False
                )
                try:
                    handle = self._handle_from_observation(
                        observed,
                        environment_id=spec["environmentId"],
                        service_id=spec["serviceId"],
                        release_sha=spec["releaseSha"],
                        origin="started",
                        observed_at=spec["observedAt"],
                        sidecar=sidecar,
                    )
                    break
                except ProcessError as error:
                    original_failure = error
            time.sleep(0.05)
        if handle is None:
            matches = [
                item for item in self._all_inventory()
                if item.get("launchToken") == launch_token
            ]
            failed_observation = matches[0] if len(matches) == 1 else observed
            if len(matches) == 1:
                self._delete_raw_owned_candidate(
                    matches[0], spec, launch_token=launch_token
                )
            elif len(matches) > 1:
                self._finalize_failed_diagnostics(launch_token, diagnostic_paths, sensitive, None)
                raise ProcessError("candidate launch token matched multiple PM2 records")
            diagnostics = self._finalize_failed_diagnostics(
                launch_token, diagnostic_paths, sensitive, failed_observation
            )
            raise ProcessError(
                f"{original_failure}; bounded diagnostics categories={diagnostics['categories']} "
                f"exitCode={diagnostics['exitCode']} exitSignal={diagnostics['exitSignal']}"
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
            self._finalize_failed_diagnostics(launch_token, diagnostic_paths, sensitive, owned[0] if owned else observed)
            raise ProcessError("candidate start did not produce exactly one owned PM2 record")
        self._discard_diagnostics(diagnostic_paths)
        return handle

    def attest(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        result = self._observe_health(handle, expected_sha, health_targets)
        self._attested.add(handle.record["provenance"]["adapterReceipt"])
        return result

    def observe_preflight(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        """Fresh PM2, /proc, listener and health evidence without changing adapter or PM2 state."""
        return self._observe_health(handle, expected_sha, health_targets)

    def _observe_health(self, handle: AdapterHandle, expected_sha: str, health_targets: tuple[str, str]) -> dict[str, Any]:
        self._require_governed_daemon()
        expected = self._exact_expected(handle)
        matches = [item for item in self._all_inventory() if item["adapterId"] == expected["adapterId"]]
        if len(matches) != 1:
            raise ProcessError("PM2 process cannot be attested exactly")
        observed = matches[0]
        sidecar = self._sidecars.get(handle.record["provenance"]["adapterReceipt"], {})
        self._assert_observation(observed, expected, require_live=True, compare_ownership=not bool(sidecar.get("legacyDescriptor")))
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
        return {"releaseSha": expected_sha, "health": results, "processStartId": evidence["processStartId"]}

    def restore(self, handle: AdapterHandle) -> AdapterHandle:
        self._require_governed_daemon()
        self.assert_handle(handle)
        sidecar = self._sidecars.get(handle.record["provenance"]["adapterReceipt"])
        if sidecar and sidecar.get("legacyDescriptor"):
            descriptor = sidecar["legacyDescriptor"]
            if sidecar.get("legacyDescriptorDigest") != self._descriptor_digest(descriptor): raise ProcessError("legacy restore descriptor digest mismatch")
            self._validate_restore_recipe(descriptor)
            authority = descriptor["observedAuthority"]
            recipe = descriptor["restoreRecipe"]
            env = self._legacy_environment(descriptor, recipe["listener"])
            token = str(uuid.uuid4())
            env.update({"RELEASE_MANAGER_ENVIRONMENT_ID": descriptor["metadata"]["environmentId"], "RELEASE_MANAGER_SERVICE_ID": descriptor["metadata"]["serviceId"], "RELEASE_MANAGER_RELEASE_SHA": authority["releaseSha"], "RELEASE_MANAGER_LAUNCH_TOKEN": token, "RELEASE_MANAGER_OWNED_HOST": recipe["listener"]["host"], "RELEASE_MANAGER_OWNED_PORT": str(recipe["listener"]["port"])})
            observed = self._bridge({"action": "start", "app": {"name": authority["stableName"], "namespace": authority["namespace"], "script": recipe["bootstrap"]["executable"], "args": recipe["bootstrap"]["args"], "cwd": recipe["bootstrap"]["cwd"], "env": env}})["record"]
            return self._handle_from_observation(observed, environment_id=descriptor["metadata"]["environmentId"], service_id=descriptor["metadata"]["serviceId"], release_sha=authority["releaseSha"], origin="started", observed_at=self._now(), sidecar={"stableName": authority["stableName"], "listener": recipe["listener"], "legacyDescriptor": copy.deepcopy(descriptor), "legacyDescriptorDigest": self._descriptor_digest(descriptor), "health": descriptor["health"]})
        if not sidecar or not sidecar.get("startSpec"):
            raise ProcessError("exact restore descriptor is unavailable")
        return self.start_candidate(copy.deepcopy(sidecar["startSpec"]))

    def persist(self, handle: AdapterHandle) -> dict[str, Any]:
        self._require_governed_daemon()
        self.assert_handle(handle)
        receipt = handle.record["provenance"]["adapterReceipt"]
        if receipt not in self._attested:
            raise ProcessError("PM2 persistence requires prior runtime attestation")
        self._bridge({"action": "save"})
        return {"adapterId": handle.record["identity"]["adapterId"], "persistedAt": self._now()}

    def kill_isolated_daemon(self) -> None:
        self._bridge({"action": "kill-daemon"})
