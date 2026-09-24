from __future__ import annotations

import copy
import hashlib
import json
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .contracts import canonical_document_digest, compose_health_targets, validate_contract_and_policy, validate_legacy_restore_descriptor
from .errors import ArtifactError, ContractError, ProcessError, ReleaseError, StateError, ToolchainError
from .ports import AdapterHandle, LifecycleRunner, ProcessAdapter, SourceProvider
from .state_machine import StateMachine
from .state_store import AtomicStateStore

SHA_PATTERN = re.compile(r"^[a-f0-9]{40}$")
PACKAGE_MANAGER_PATTERN = re.compile(r"^(pnpm|npm|yarn)@[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$")
BUILD_ENV_ALLOWLIST = {"HOME"}


class MigrationGateRequired(ReleaseError):
    pass


@dataclass(frozen=True)
class ReleaseRequest:
    source: str
    target_sha: str
    contract: dict[str, Any]
    policy: dict[str, Any]
    build_environment: dict[str, str]


@dataclass(frozen=True)
class MigrationApprovalReceipt:
    target_sha: str
    release_contract_digest: str
    environment_policy_digest: str
    environment_id: str
    service_id: str
    attempt_id: str
    state_generation: int
    gate_id: str
    approved_at: str


@dataclass(frozen=True)
class Candidate:
    path: Path
    sha: str
    attempt_id: str
    attempt_sequence: int
    trace: tuple[tuple[str, str, str], ...]
    health_targets: tuple[str, str]
    release_contract_digest: str
    environment_policy_digest: str
    build_config_digest: str
    runtime_config_digest: str


class ReleaseEngine:
    def __init__(
        self,
        source: SourceProvider,
        runner: LifecycleRunner,
        adapter: ProcessAdapter,
        store: AtomicStateStore,
        workspace_root: Path,
        trusted_path: tuple[str, ...],
        now: Callable[[], str] | None = None,
        new_id: Callable[[], str] | None = None,
    ) -> None:
        self.source = source
        self.runner = runner
        self.adapter = adapter
        self.store = store
        self.workspace_root = workspace_root
        if not trusted_path or any(not Path(entry).is_absolute() or ":" in entry for entry in trusted_path):
            raise ContractError("trusted PATH entries must be non-empty absolute paths")
        self.trusted_path = tuple(dict.fromkeys(trusted_path))
        self.now = now or (lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.new_id = new_id or (lambda: str(uuid.uuid4()))

    @staticmethod
    def _digest(value: Any) -> str:
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    def _sanitize_build_environment(self, environment: dict[str, str], policy: dict[str, Any]) -> dict[str, str]:
        clean = {key: value for key, value in environment.items() if key in BUILD_ENV_ALLOWLIST}
        clean.update({item["name"]: item["value"] for item in policy["build"]["values"]})
        clean["CI"] = "true"
        clean["PATH"] = ":".join(self.trusted_path)
        return clean

    @staticmethod
    def _resolve_release_path(release_root: Path, relative: str, kind: str) -> Path:
        try:
            root = release_root.resolve(strict=True)
            resolved = (root / relative).resolve(strict=True)
        except OSError as error:
            raise ArtifactError(f"runtime {kind} is unavailable") from error
        if not resolved.is_relative_to(root):
            raise ArtifactError(f"runtime {kind} escapes release root")
        return resolved

    def _validate_request(self, request: ReleaseRequest) -> tuple[str, str]:
        validate_contract_and_policy(request.contract, request.policy)
        if not SHA_PATTERN.fullmatch(request.target_sha):
            raise ContractError("target SHA must be an exact lowercase 40-character SHA")
        if request.contract["metadata"]["application"] != request.policy["metadata"]["application"]:
            raise ContractError("contract and policy application mismatch")
        undeclared_secrets = sorted(
            set(request.policy["secrets"]["requiredNames"])
            - set(request.contract["runtime"]["envNames"])
        )
        if undeclared_secrets:
            raise ContractError(f"policy requires runtime env names absent from contract: {undeclared_secrets}")
        self.adapter.validate_policy(request.policy)
        return compose_health_targets(request.contract, request.policy)

    def _next_attempt_sequence(self, state: dict[str, Any] | None) -> int:
        return 1 if state is None else state["attempt"]["sequence"] + 1

    @staticmethod
    def _canonical_context(request: ReleaseRequest) -> dict[str, str]:
        return {
            "releaseContract": canonical_document_digest(request.contract),
            "environmentPolicy": canonical_document_digest(request.policy),
        }

    def _assert_candidate_context(self, request: ReleaseRequest, candidate: Candidate) -> None:
        self._validate_request(request)
        current = self._canonical_context(request)
        if candidate.release_contract_digest != current["releaseContract"]:
            raise ContractError("Release Contract drifted after candidate creation")
        if candidate.environment_policy_digest != current["environmentPolicy"]:
            raise ContractError("Environment Policy drifted after candidate creation")

    @staticmethod
    def _assert_handle_context(handle_record: dict[str, Any], expected: dict[str, str]) -> None:
        digests = handle_record.get("configurationDigests") or {}
        if (
            digests.get("releaseContract") != expected["releaseContract"]
            or digests.get("environmentPolicy") != expected["environmentPolicy"]
        ):
            raise ContractError("persisted runtime contract/policy digest context mismatch")

    def _assert_current_state_context(self, state: dict[str, Any]) -> None:
        expected = {
            "releaseContract": state.get("releaseContractDigest"),
            "environmentPolicy": state.get("environmentPolicyDigest"),
        }
        self._assert_handle_context(state["current"]["handle"], expected)

    def build_candidate(self, request: ReleaseRequest, state: dict[str, Any] | None = None) -> Candidate:
        health_targets = self._validate_request(request)  # schema validation is the first engine action
        sequence = self._next_attempt_sequence(state)
        attempt_id = self.new_id()
        destination = self.workspace_root / "attempts" / f"{sequence}-{attempt_id}" / request.target_sha
        if destination.exists():
            raise StateError("attempt destination already exists")
        destination.parent.mkdir(parents=True, exist_ok=False)
        machine = StateMachine("build")
        workspace = self.source.acquire(request.source, request.target_sha, destination)
        machine.send("SOURCE_ACQUIRE_OK", "SOURCE_ACQUIRED")
        workspace.attest_sha(request.target_sha)
        machine.send("SOURCE_ATTEST_OK", "SOURCE_ATTESTED")

        package_json_path = destination / "package.json"
        if not package_json_path.is_file():
            raise ToolchainError("package.json missing")
        package_json = json.loads(package_json_path.read_text(encoding="utf-8"))
        package_manager = package_json.get("packageManager", "")
        if not PACKAGE_MANAGER_PATTERN.fullmatch(package_manager):
            raise ToolchainError("packageManager must pin an exact supported version")
        if not package_json.get("engines", {}).get("node"):
            raise ToolchainError("repository Node engine declaration missing")
        if request.contract["toolchain"]["install"]["operation"] != "package-manager-frozen-install":
            raise ToolchainError("unsupported install operation")
        machine.send("TOOLCHAIN_ATTEST_OK", "TOOLCHAIN_ATTESTED")

        environment = self._sanitize_build_environment(request.build_environment, request.policy)
        self.runner.frozen_install(destination, package_manager, environment)
        machine.send("FROZEN_INSTALL_OK", "INSTALLED_FROZEN")

        prepare = request.contract["lifecycle"].get("prepare")
        if prepare:
            self.runner.run_action(destination, prepare["action"], environment)
            for relative in prepare["outputs"]:
                if not (destination / relative).exists():
                    raise ArtifactError(f"prepare output missing: {relative}")
        machine.send("PREPARE_OK", "PREPARED")

        self.runner.run_action(destination, request.contract["lifecycle"]["build"], environment)
        machine.send("BUILD_OK", "BUILT")
        for relative in request.contract["artifact"]["required"]:
            if not (destination / relative).is_file():
                raise ArtifactError(f"required artifact missing: {relative}")
        runtime = request.contract["runtime"]
        runtime_cwd = self._resolve_release_path(destination, runtime["cwd"], "cwd")
        runtime_executable = self._resolve_release_path(destination, runtime["executable"], "executable")
        if not runtime_cwd.is_dir():
            raise ArtifactError("runtime cwd missing")
        if not runtime_executable.is_file():
            raise ArtifactError("runtime executable missing")
        machine.send("ARTIFACT_VERIFY_OK", "ARTIFACT_VERIFIED")

        for action in request.contract["lifecycle"]["verify"]:
            self.runner.run_action(destination, action, environment)
        changed = workspace.changed_tracked()
        allowed = set(request.contract["artifact"]["trackedMutationAllowlist"])
        unexpected = sorted(set(changed) - allowed)
        if unexpected:
            raise ArtifactError(f"unexpected tracked mutations: {unexpected}")
        workspace.restore_tracked(changed)
        if workspace.changed_tracked():
            raise ArtifactError("tracked mutations remain after allowlisted restoration")
        workspace.attest_sha(request.target_sha)
        machine.send("CLEAN_TREE_OK", "CANDIDATE_READY")
        build_digest = self._digest(request.policy["build"])
        runtime_digest = self._digest({"runtime": request.policy["runtime"], "network": request.policy["network"], "secrets": request.policy["secrets"]})
        return Candidate(
            destination, request.target_sha, attempt_id, sequence, tuple(machine.trace), health_targets,
            canonical_document_digest(request.contract), canonical_document_digest(request.policy),
            build_digest, runtime_digest,
        )

    def _attempt(self, candidate: Candidate, phase: str, outcome: str, event: str) -> dict[str, Any]:
        return {
            "attemptId": candidate.attempt_id,
            "sequence": candidate.attempt_sequence,
            "targetSha": candidate.sha,
            "releaseContractDigest": candidate.release_contract_digest,
            "environmentPolicyDigest": candidate.environment_policy_digest,
            "phase": phase,
            "outcome": outcome,
            "events": [{"sequence": 1, "at": self.now(), "type": event}],
        }

    def _base_record(
        self,
        request: ReleaseRequest,
        generation: int,
        status: str,
        attempt: dict[str, Any],
        **authorities: Any,
    ) -> dict[str, Any]:
        record = {
            "apiVersion": "quanyu.ai/state-record/v1alpha1",
            "kind": "ReleaseState",
            "environmentId": request.policy["metadata"]["environmentId"],
            "serviceId": request.policy["metadata"]["serviceId"],
            "generation": generation,
            "updatedAt": self.now(),
            "status": status,
            "releaseContractDigest": canonical_document_digest(request.contract),
            "environmentPolicyDigest": canonical_document_digest(request.policy),
            "attempt": attempt,
        }
        record.update({key: copy.deepcopy(value) for key, value in authorities.items() if value is not None})
        return record

    def _runtime_spec(self, request: ReleaseRequest, candidate: Candidate) -> dict[str, Any]:
        self._assert_candidate_context(request, candidate)
        if candidate.build_config_digest != self._digest(request.policy["build"]):
            raise ContractError("build configuration drifted after candidate creation")
        runtime_digest = self._digest({"runtime": request.policy["runtime"], "network": request.policy["network"], "secrets": request.policy["secrets"]})
        if candidate.runtime_config_digest != runtime_digest:
            raise ContractError("runtime configuration drifted after candidate creation")
        runtime = request.contract["runtime"]
        executable = self._resolve_release_path(candidate.path, runtime["executable"], "executable")
        cwd = self._resolve_release_path(candidate.path, runtime["cwd"], "cwd")
        if not executable.is_file():
            raise ArtifactError("runtime executable is not a file")
        if not cwd.is_dir():
            raise ArtifactError("runtime cwd is not a directory")
        return {
            "environmentId": request.policy["metadata"]["environmentId"],
            "serviceId": request.policy["metadata"]["serviceId"],
            "namespace": request.policy["process"]["namespace"],
            "stableName": request.policy["process"]["stableName"],
            "releaseSha": candidate.sha,
            "releasePath": str(candidate.path),
            "runtime": {
                "executable": str(executable),
                "args": list(runtime["args"]),
                "cwd": str(cwd),
            },
            "observedAt": self.now(),
            "allowedEnvNames": list(runtime["envNames"]),
            "requiredSecretNames": list(request.policy["secrets"]["requiredNames"]),
            "nonSecretValues": copy.deepcopy(request.policy["runtime"]["values"]),
            "configurationDigests": {
                "releaseContract": candidate.release_contract_digest,
                "environmentPolicy": candidate.environment_policy_digest,
                "build": candidate.build_config_digest,
                "runtime": candidate.runtime_config_digest,
            },
            "secretSource": {
                "provider": request.policy["secrets"]["provider"],
                "sourcePath": request.policy["secrets"]["sourcePath"],
            },
            "binding": {
                runtime["binding"]["hostEnv"]: request.policy["network"]["internalHost"],
                runtime["binding"]["portEnv"]: str(request.policy["network"]["internalPort"]),
            },
            "listener": {
                "host": request.policy["network"]["internalHost"],
                "port": request.policy["network"]["internalPort"],
            },
            "health": {
                "acceptedStatusClasses": list(request.contract["health"]["acceptedStatusClasses"]),
                "attempts": request.policy["health"]["attempts"],
                "intervalMs": request.policy["health"]["intervalMs"],
            },
        }

    def _authority(self, handle: AdapterHandle, release_path: str, generation: int) -> dict[str, Any]:
        self.adapter.assert_handle(handle)
        sha = handle.record["releaseSha"]
        evidence = self._digest({"handle": handle.record, "generation": generation})
        return {
            "generation": generation,
            "releaseSha": sha,
            "releasePath": release_path,
            "restorable": True,
            "handle": copy.deepcopy(handle.record),
            "attestation": {
                "attestedAt": self.now(),
                "sourceSha": sha,
                "runtimeSha": sha,
                "internalHealth": "pass",
                "publicHealth": "pass",
                "evidenceDigest": evidence,
            },
        }

    def _approval_digest(self, receipt: MigrationApprovalReceipt) -> str:
        return self._digest(receipt.__dict__)

    def _record_approval(self, attempt: dict[str, Any], approval_digest: str | None) -> dict[str, Any]:
        if approval_digest:
            attempt["events"].insert(0, {
                "sequence": 1,
                "at": self.now(),
                "type": "DB_GATE_APPROVED",
                "evidenceDigest": approval_digest,
            })
            for sequence, event in enumerate(attempt["events"], 1):
                event["sequence"] = sequence
        return attempt

    def _validate_approval(
        self,
        request: ReleaseRequest,
        state: dict[str, Any],
        receipt: MigrationApprovalReceipt | None,
    ) -> str:
        if receipt is None:
            raise MigrationGateRequired("typed migration approval receipt required")
        if not isinstance(receipt, MigrationApprovalReceipt):
            raise ContractError("migration approval must be a typed MigrationApprovalReceipt")
        expected = {
            "target_sha": request.target_sha,
            "release_contract_digest": canonical_document_digest(request.contract),
            "environment_policy_digest": canonical_document_digest(request.policy),
            "environment_id": request.policy["metadata"]["environmentId"],
            "service_id": request.policy["metadata"]["serviceId"],
            "attempt_id": state["attempt"]["attemptId"],
            "state_generation": state["generation"],
        }
        for field, value in expected.items():
            if getattr(receipt, field) != value:
                raise ContractError(f"migration approval receipt {field} mismatch")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}", receipt.gate_id):
            raise ContractError("migration approval receipt gate_id is invalid")
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", receipt.approved_at):
            raise ContractError("migration approval receipt approved_at is invalid")
        try:
            datetime.strptime(receipt.approved_at, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError as error:
            raise ContractError("migration approval receipt approved_at is invalid") from error
        return self._approval_digest(receipt)

    def _gate_or_stop(
        self,
        request: ReleaseRequest,
        candidate: Candidate,
        state: dict[str, Any] | None,
    ) -> None:
        if request.contract["migration"]["mode"] != "approval-gated":
            return
        expected = 0 if state is None else state["generation"]
        authorities = {key: state.get(key) if state else None for key in ("current", "previous", "legacy")}
        record = self._base_record(
            request,
            expected + 1,
            "candidate-ready",
            self._attempt(candidate, "waiting-db-gate", "pending", "DB_GATE_REQUIRED"),
            **authorities,
        )
        self.store.commit(expected, record)
        raise MigrationGateRequired("independent database approval gate required before activation")

    def adopt(
        self,
        request: ReleaseRequest,
        legacy_spec: dict[str, Any],
        approval: MigrationApprovalReceipt | None = None,
    ) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            resuming_gate = bool(state and state["status"] == "candidate-ready" and state["attempt"]["phase"] == "waiting-db-gate")
            if state is not None and not (resuming_gate and "current" not in state):
                raise StateError("adoption requires an empty State Store")
            approval_digest = self._validate_approval(request, state, approval) if resuming_gate else None
            candidate = self.build_candidate(request, state)
            self._assert_candidate_context(request, candidate)
            if not resuming_gate:
                self._gate_or_stop(request, candidate, state)
            machine = StateMachine("legacy-adoption")
            validate_legacy_restore_descriptor(legacy_spec)
            if legacy_spec["metadata"] != {"environmentId": request.policy["metadata"]["environmentId"], "serviceId": request.policy["metadata"]["serviceId"]}:
                raise ContractError("legacy descriptor environment/service mismatch")
            observed_authority = legacy_spec["observedAuthority"]
            if observed_authority["namespace"] != request.policy["process"]["namespace"] or observed_authority["stableName"] != request.policy["process"]["stableName"]:
                raise ContractError("legacy descriptor process identity mismatch")
            if observed_authority["listener"] != {"host": request.policy["network"]["internalHost"], "port": request.policy["network"]["internalPort"]}:
                raise ContractError("legacy descriptor listener mismatch")
            self.adapter.preflight_legacy_restore(legacy_spec)
            legacy_handle = self.adapter.observe_legacy(legacy_spec)
            self.adapter.assert_handle(legacy_handle)
            machine.send("LEGACY_OBSERVED", "LEGACY_OBSERVED")
            self.adapter.attest(legacy_handle, legacy_handle.record["releaseSha"], candidate.health_targets)
            machine.send("LEGACY_HEALTH_OK", "LEGACY_HEALTH_ATTESTED")
            machine.send("RESTORE_PROBE_OK", "ADOPTION_READY")
            expected = 0 if state is None else state["generation"]
            adoption_generation = expected + 1
            legacy_authority = self._authority(legacy_handle, observed_authority["releasePath"], adoption_generation)
            adoption = self._base_record(
                request, adoption_generation, "adoption-ready", self._attempt(candidate, "candidate-ready", "pending", "LEGACY_ATTESTED"), legacy=legacy_authority
            )
            self.store.commit(expected, adoption)
            candidate_handle = None
            legacy_removed = False
            try:
                runtime_spec = self._runtime_spec(request, candidate)
                self.adapter.assert_replaceable(legacy_handle, runtime_spec)
                self._assert_candidate_context(request, candidate)
                self.adapter.stop_exact(legacy_handle)
                self.adapter.delete_exact(legacy_handle)
                self.adapter.await_absent(legacy_handle)
                legacy_removed = True
                machine.send("OLD_EXACTLY_ABSENT", "OLD_HANDLE_ABSENT")
                self._assert_candidate_context(request, candidate)
                candidate_handle = self.adapter.start_candidate(runtime_spec)
                self.adapter.assert_handle(candidate_handle)
                machine.send("CANDIDATE_STARTED", "CANDIDATE_STARTED")
                self.adapter.attest(candidate_handle, candidate.sha, candidate.health_targets)
                machine.send("CANDIDATE_ATTESTED", "CANDIDATE_ATTESTED")
                final_generation = adoption_generation + 1
                current = self._authority(candidate_handle, str(candidate.path), final_generation)
                attempt = self._record_approval(
                    self._attempt(candidate, "complete", "succeeded", "RUNTIME_ATTESTED"), approval_digest
                )
                final = self._base_record(request, final_generation, "managed", attempt, current=current)
                self.store.commit(adoption_generation, final)
                machine.send("STATE_COMMITTED", "MANAGED_COMMITTED")
                self.adapter.persist(candidate_handle)
                machine.send("ADAPTER_PERSISTED", "PERSISTED")
                return final
            except Exception:
                if candidate_handle is not None:
                    self.adapter.stop_exact(candidate_handle)
                    self.adapter.delete_exact(candidate_handle)
                    self.adapter.await_absent(candidate_handle)
                restored = self.adapter.restore(legacy_handle) if legacy_removed else legacy_handle
                self.adapter.attest(restored, legacy_handle.record["releaseSha"], candidate.health_targets)
                self.adapter.persist(restored)
                failed_generation = adoption_generation + 1
                attempt = self._record_approval(
                    self._attempt(candidate, "failed", "failed", "ADOPTION_FAILED"), approval_digest
                )
                failed = self._base_record(request, failed_generation, "failed", attempt, legacy=legacy_authority)
                self.store.commit(adoption_generation, failed)
                raise

    def activate(
        self,
        request: ReleaseRequest,
        approval: MigrationApprovalReceipt | None = None,
    ) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            resuming_gate = bool(state and state["status"] == "candidate-ready" and state["attempt"]["phase"] == "waiting-db-gate")
            if not state or "current" not in state or (state["status"] != "managed" and not resuming_gate):
                raise StateError("canonical activation requires managed current authority")
            self._assert_current_state_context(state)
            approval_digest = self._validate_approval(request, state, approval) if resuming_gate else None
            candidate = self.build_candidate(request, state)
            self._assert_candidate_context(request, candidate)
            if not resuming_gate:
                self._gate_or_stop(request, candidate, state)
            expected = state["generation"]
            if not resuming_gate:
                pending = self._base_record(
                    request, expected + 1, "candidate-ready", self._attempt(candidate, "candidate-ready", "pending", "CANDIDATE_READY"),
                    current=state["current"], previous=state.get("previous")
                )
                self.store.commit(expected, pending)
                expected += 1
            current_handle = self.adapter.resolve_persisted(state["current"]["handle"])
            machine = StateMachine("activation")
            machine.send("HANDLE_CAPTURED", "CURRENT_HANDLE_CAPTURED")
            candidate_handle = None
            current_removed = False
            try:
                runtime_spec = self._runtime_spec(request, candidate)
                self.adapter.assert_replaceable(current_handle, runtime_spec)
                machine.send("REPLACEABILITY_PROVED", "REPLACEABLE")
                self._assert_candidate_context(request, candidate)
                self.adapter.stop_exact(current_handle)
                self.adapter.delete_exact(current_handle)
                self.adapter.await_absent(current_handle)
                current_removed = True
                machine.send("CURRENT_EXACTLY_ABSENT", "CURRENT_ABSENT")
                self._assert_candidate_context(request, candidate)
                candidate_handle = self.adapter.start_candidate(runtime_spec)
                self.adapter.assert_handle(candidate_handle)
                machine.send("CANDIDATE_STARTED", "CANDIDATE_STARTED")
                self.adapter.attest(candidate_handle, candidate.sha, candidate.health_targets)
                machine.send("CANDIDATE_ATTESTED", "CANDIDATE_ATTESTED")
                generation = expected + 1
                current = self._authority(candidate_handle, str(candidate.path), generation)
                attempt = self._record_approval(
                    self._attempt(candidate, "complete", "succeeded", "RUNTIME_ATTESTED"), approval_digest
                )
                final = self._base_record(request, generation, "managed", attempt, current=current, previous=state["current"])
                self.store.commit(expected, final)
                machine.send("STATE_COMMITTED", "STATE_COMMITTED")
                self.adapter.persist(candidate_handle)
                machine.send("ADAPTER_PERSISTED", "PERSISTED")
                return final
            except Exception:
                if candidate_handle is not None:
                    self.adapter.stop_exact(candidate_handle)
                    self.adapter.delete_exact(candidate_handle)
                    self.adapter.await_absent(candidate_handle)
                restored = self.adapter.restore(current_handle) if current_removed else current_handle
                self.adapter.attest(restored, state["current"]["releaseSha"], candidate.health_targets)
                self.adapter.persist(restored)
                generation = expected + 1
                current = self._authority(restored, state["current"]["releasePath"], generation)
                attempt = self._record_approval(
                    self._attempt(candidate, "failed", "failed", "ACTIVATION_FAILED"), approval_digest
                )
                failed = self._base_record(request, generation, "failed", attempt, current=current, previous=state.get("previous"))
                self.store.commit(expected, failed)
                raise

    def rollback(self, request: ReleaseRequest) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            if not state or state["status"] != "managed" or "current" not in state or "previous" not in state:
                raise StateError("rollback requires managed current and previous authority")
            self._assert_current_state_context(state)
            target = state["previous"]
            sequence = self._next_attempt_sequence(state)
            context = self._canonical_context(request)
            candidate = Candidate(
                Path(target["releasePath"]), target["releaseSha"], self.new_id(), sequence, (),
                compose_health_targets(request.contract, request.policy), context["releaseContract"],
                context["environmentPolicy"], self._digest(request.policy["build"]),
                self._digest({"runtime": request.policy["runtime"], "network": request.policy["network"], "secrets": request.policy["secrets"]}),
            )
            current_handle = self.adapter.resolve_persisted(state["current"]["handle"])
            target_handle = self.adapter.resolve_persisted(target["handle"])
            machine = StateMachine("rollback")
            machine.send("TARGET_VERIFIED", "TARGET_ATTESTED")
            machine.send("CURRENT_HANDLE_CAPTURED", "CURRENT_HANDLE_CAPTURED")
            restored_target = None
            current_removed = False
            try:
                self.adapter.assert_replaceable(current_handle, target)
                self.adapter.stop_exact(current_handle)
                self.adapter.delete_exact(current_handle)
                self.adapter.await_absent(current_handle)
                current_removed = True
                machine.send("CURRENT_EXACTLY_ABSENT", "CURRENT_ABSENT")
                restored_target = self.adapter.restore(target_handle)
                machine.send("TARGET_STARTED", "TARGET_STARTED")
                self.adapter.attest(restored_target, target["releaseSha"], candidate.health_targets)
                machine.send("TARGET_RUNTIME_ATTESTED", "TARGET_RUNTIME_ATTESTED")
                generation = state["generation"] + 1
                current = self._authority(restored_target, target["releasePath"], generation)
                final = self._base_record(
                    request, generation, "managed", self._attempt(candidate, "complete", "succeeded", "ROLLBACK_ATTESTED"),
                    current=current, previous=state["current"]
                )
                self.store.commit(state["generation"], final)
                machine.send("STATE_COMMITTED", "STATE_COMMITTED")
                self.adapter.persist(restored_target)
                machine.send("ADAPTER_PERSISTED", "PERSISTED")
                return final
            except Exception:
                if restored_target is not None:
                    self.adapter.stop_exact(restored_target)
                    self.adapter.delete_exact(restored_target)
                    self.adapter.await_absent(restored_target)
                restored = self.adapter.restore(current_handle) if current_removed else current_handle
                self.adapter.attest(restored, state["current"]["releaseSha"], candidate.health_targets)
                self.adapter.persist(restored)
                generation = state["generation"] + 1
                current = self._authority(restored, state["current"]["releasePath"], generation)
                failed = self._base_record(
                    request, generation, "failed", self._attempt(candidate, "failed", "failed", "ROLLBACK_FAILED"), current=current
                )
                self.store.commit(state["generation"], failed)
                raise

    def recover(self, request: ReleaseRequest) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            if not state:
                raise StateError("no persisted state to recover")
            if state["status"] == "managed":
                current_context = self._canonical_context(request)
                if (
                    state.get("releaseContractDigest") != current_context["releaseContract"]
                    or state.get("environmentPolicyDigest") != current_context["environmentPolicy"]
                ):
                    raise ContractError("recovery request contract/policy digest context mismatch")
                self._assert_current_state_context(state)
                current = self.adapter.resolve_persisted(state["current"]["handle"])
                self.adapter.attest(current, state["current"]["releaseSha"], compose_health_targets(request.contract, request.policy))
                self.adapter.persist(current)
                return state
            authority = state.get("current") or state.get("legacy")
            if not authority:
                failed = copy.deepcopy(state)
                failed["generation"] += 1
                failed["updatedAt"] = self.now()
                failed["status"] = "failed"
                failed["attempt"]["phase"] = "failed"
                failed["attempt"]["outcome"] = "failed"
                failed["attempt"]["events"].append({"sequence": len(failed["attempt"]["events"]) + 1, "at": self.now(), "type": "RECOVERY_NO_PROCESS_MUTATION"})
                return self.store.commit(state["generation"], failed)
            targets = compose_health_targets(request.contract, request.policy)
            handle = self.adapter.resolve_persisted(authority["handle"])
            identity = authority["handle"]["identity"]
            inventory = self.adapter.inventory(
                identity["environmentId"], identity["serviceId"], identity["namespace"]
            )
            for observed in inventory:
                self.adapter.assert_handle(observed)
            current_id = identity["adapterId"]
            target_sha = state["attempt"]["targetSha"]
            expected_candidate_root = (
                self.workspace_root
                / "attempts"
                / f"{state['attempt']['sequence']}-{state['attempt']['attemptId']}"
                / target_sha
            ).resolve()

            def is_expected_candidate(observed: AdapterHandle) -> bool:
                if observed.record["releaseSha"] != target_sha:
                    return False
                runtime = observed.record["runtime"]
                try:
                    return (
                        Path(runtime["cwd"]).resolve().is_relative_to(expected_candidate_root)
                        and Path(runtime["executable"]).resolve().is_relative_to(expected_candidate_root)
                    )
                except (KeyError, OSError):
                    return False

            candidates = [
                observed for observed in inventory
                if observed.record["identity"]["adapterId"] != current_id
                and is_expected_candidate(observed)
            ]
            unexpected = [
                observed for observed in inventory
                if observed.record["identity"]["adapterId"] != current_id
                and observed not in candidates
            ]
            if len(candidates) > 1 or unexpected:
                raise ProcessError("interrupted release inventory is ambiguous")
            if candidates:
                candidate = candidates[0]
                self.adapter.stop_exact(candidate)
                self.adapter.delete_exact(candidate)
                self.adapter.await_absent(candidate)
            try:
                self.adapter.attest(handle, authority["releaseSha"], targets)
                restored = handle
            except ProcessError:
                restored = self.adapter.restore(handle)
                self.adapter.attest(restored, authority["releaseSha"], targets)
            self.adapter.persist(restored)
            generation = state["generation"] + 1
            restored_authority = self._authority(restored, authority["releasePath"], generation)
            context = self._canonical_context(request)
            candidate = Candidate(
                Path(authority["releasePath"]), state["attempt"]["targetSha"], state["attempt"]["attemptId"],
                state["attempt"]["sequence"], (), targets, context["releaseContract"],
                context["environmentPolicy"], self._digest(request.policy["build"]),
                self._digest({"runtime": request.policy["runtime"], "network": request.policy["network"], "secrets": request.policy["secrets"]}),
            )
            slot = "current" if "current" in state else "legacy"
            if slot == "legacy":
                restored_authority = authority
            failed = self._base_record(
                request, generation, "failed", self._attempt(candidate, "failed", "failed", "RECOVERY_RESTORED"), **{slot: restored_authority}
            )
            return self.store.commit(state["generation"], failed)
