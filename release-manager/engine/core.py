from __future__ import annotations

import copy
import hashlib
import json
import re
import shutil
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .contracts import compose_health_targets, validate_contract_and_policy
from .errors import ArtifactError, ContractError, ProcessError, ReleaseError, StateError, ToolchainError
from .ports import AdapterHandle, LifecycleRunner, ProcessAdapter, SourceProvider
from .state_machine import StateMachine
from .state_store import AtomicStateStore

SHA_PATTERN = re.compile(r"^[a-f0-9]{40}$")
PACKAGE_MANAGER_PATTERN = re.compile(r"^(pnpm|npm|yarn)@[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$")
BUILD_ENV_ALLOWLIST = {"HOME", "PATH", "CI", "NEXT_DIST_DIR"}


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
class Candidate:
    path: Path
    sha: str
    attempt_id: str
    attempt_sequence: int
    trace: tuple[tuple[str, str, str], ...]
    health_targets: tuple[str, str]


class ReleaseEngine:
    def __init__(
        self,
        source: SourceProvider,
        runner: LifecycleRunner,
        adapter: ProcessAdapter,
        store: AtomicStateStore,
        workspace_root: Path,
        now: Callable[[], str] | None = None,
        new_id: Callable[[], str] | None = None,
    ) -> None:
        self.source = source
        self.runner = runner
        self.adapter = adapter
        self.store = store
        self.workspace_root = workspace_root
        self.now = now or (lambda: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.new_id = new_id or (lambda: str(uuid.uuid4()))

    @staticmethod
    def _digest(value: Any) -> str:
        payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return "sha256:" + hashlib.sha256(payload).hexdigest()

    @staticmethod
    def _sanitize_build_environment(environment: dict[str, str]) -> dict[str, str]:
        clean = {key: value for key, value in environment.items() if key in BUILD_ENV_ALLOWLIST}
        clean["CI"] = "true"
        return clean

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
        return compose_health_targets(request.contract, request.policy)

    def _next_attempt_sequence(self, state: dict[str, Any] | None) -> int:
        return 1 if state is None else state["attempt"]["sequence"] + 1

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

        environment = self._sanitize_build_environment(request.build_environment)
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
        if not (destination / runtime["cwd"]).is_dir():
            raise ArtifactError("runtime cwd missing")
        if not (destination / runtime["executable"]).is_file():
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
        return Candidate(destination, request.target_sha, attempt_id, sequence, tuple(machine.trace), health_targets)

    def _attempt(self, candidate: Candidate, phase: str, outcome: str, event: str) -> dict[str, Any]:
        return {
            "attemptId": candidate.attempt_id,
            "sequence": candidate.attempt_sequence,
            "targetSha": candidate.sha,
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
            "contractDigest": self._digest(request.contract),
            "policyDigest": self._digest(request.policy),
            "attempt": attempt,
        }
        record.update({key: copy.deepcopy(value) for key, value in authorities.items() if value is not None})
        return record

    def _runtime_spec(self, request: ReleaseRequest, candidate: Candidate) -> dict[str, Any]:
        runtime = request.contract["runtime"]
        app_root = candidate.path / request.contract["artifact"]["appRoot"]
        return {
            "environmentId": request.policy["metadata"]["environmentId"],
            "serviceId": request.policy["metadata"]["serviceId"],
            "namespace": request.policy["process"]["namespace"],
            "releaseSha": candidate.sha,
            "releasePath": str(candidate.path),
            "runtime": {
                "executable": str(candidate.path / runtime["executable"]),
                "args": list(runtime["args"]),
                "cwd": str(candidate.path / runtime["cwd"]),
            },
            "observedAt": self.now(),
            "appRoot": str(app_root),
            "allowedEnvNames": list(runtime["envNames"]),
            "requiredSecretNames": list(request.policy["secrets"]["requiredNames"]),
            "secretSource": {
                "provider": request.policy["secrets"]["provider"],
                "sourcePath": request.policy["secrets"]["sourcePath"],
            },
            "binding": {
                runtime["binding"]["hostEnv"]: request.policy["network"]["internalHost"],
                runtime["binding"]["portEnv"]: str(request.policy["network"]["internalPort"]),
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

    def _gate_or_continue(
        self,
        request: ReleaseRequest,
        candidate: Candidate,
        state: dict[str, Any] | None,
        migration_approved: bool,
    ) -> None:
        if request.contract["migration"]["mode"] != "approval-gated" or migration_approved:
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

    def adopt(self, request: ReleaseRequest, legacy_spec: dict[str, Any], migration_approved: bool = False) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            resuming_gate = bool(state and state["status"] == "candidate-ready" and state["attempt"]["phase"] == "waiting-db-gate")
            if state is not None and not (resuming_gate and migration_approved and "current" not in state):
                raise StateError("adoption requires an empty State Store")
            candidate = self.build_candidate(request, state)
            self._gate_or_continue(request, candidate, state, migration_approved)
            machine = StateMachine("legacy-adoption")
            spec = copy.deepcopy(legacy_spec)
            spec.update({
                "environmentId": request.policy["metadata"]["environmentId"],
                "serviceId": request.policy["metadata"]["serviceId"],
                "namespace": request.policy["process"]["namespace"],
                "observedAt": self.now(),
            })
            legacy_handle = self.adapter.observe_legacy(spec)
            self.adapter.assert_handle(legacy_handle)
            machine.send("LEGACY_OBSERVED", "LEGACY_OBSERVED")
            self.adapter.attest(legacy_handle, legacy_handle.record["releaseSha"], candidate.health_targets)
            machine.send("LEGACY_HEALTH_OK", "LEGACY_HEALTH_ATTESTED")
            machine.send("RESTORE_PROBE_OK", "ADOPTION_READY")
            expected = 0 if state is None else state["generation"]
            adoption_generation = expected + 1
            legacy_authority = self._authority(legacy_handle, legacy_spec["releasePath"], adoption_generation)
            adoption = self._base_record(
                request, adoption_generation, "adoption-ready", self._attempt(candidate, "candidate-ready", "pending", "LEGACY_ATTESTED"), legacy=legacy_authority
            )
            self.store.commit(expected, adoption)
            candidate_handle = None
            legacy_removed = False
            try:
                self.adapter.assert_replaceable(legacy_handle, self._runtime_spec(request, candidate))
                self.adapter.stop_exact(legacy_handle)
                self.adapter.delete_exact(legacy_handle)
                self.adapter.await_absent(legacy_handle)
                legacy_removed = True
                machine.send("OLD_EXACTLY_ABSENT", "OLD_HANDLE_ABSENT")
                candidate_handle = self.adapter.start_candidate(self._runtime_spec(request, candidate))
                self.adapter.assert_handle(candidate_handle)
                machine.send("CANDIDATE_STARTED", "CANDIDATE_STARTED")
                self.adapter.attest(candidate_handle, candidate.sha, candidate.health_targets)
                machine.send("CANDIDATE_ATTESTED", "CANDIDATE_ATTESTED")
                final_generation = adoption_generation + 1
                current = self._authority(candidate_handle, str(candidate.path), final_generation)
                final = self._base_record(
                    request, final_generation, "managed", self._attempt(candidate, "complete", "succeeded", "RUNTIME_ATTESTED"), current=current
                )
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
                failed = self._base_record(
                    request, failed_generation, "failed", self._attempt(candidate, "failed", "failed", "ADOPTION_FAILED"), legacy=legacy_authority
                )
                self.store.commit(adoption_generation, failed)
                raise

    def activate(self, request: ReleaseRequest, migration_approved: bool = False) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            resuming_gate = bool(state and state["status"] == "candidate-ready" and state["attempt"]["phase"] == "waiting-db-gate")
            if not state or "current" not in state or (state["status"] != "managed" and not (resuming_gate and migration_approved)):
                raise StateError("canonical activation requires managed current authority")
            candidate = self.build_candidate(request, state)
            self._gate_or_continue(request, candidate, state, migration_approved)
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
                self.adapter.assert_replaceable(current_handle, self._runtime_spec(request, candidate))
                machine.send("REPLACEABILITY_PROVED", "REPLACEABLE")
                self.adapter.stop_exact(current_handle)
                self.adapter.delete_exact(current_handle)
                self.adapter.await_absent(current_handle)
                current_removed = True
                machine.send("CURRENT_EXACTLY_ABSENT", "CURRENT_ABSENT")
                candidate_handle = self.adapter.start_candidate(self._runtime_spec(request, candidate))
                self.adapter.assert_handle(candidate_handle)
                machine.send("CANDIDATE_STARTED", "CANDIDATE_STARTED")
                self.adapter.attest(candidate_handle, candidate.sha, candidate.health_targets)
                machine.send("CANDIDATE_ATTESTED", "CANDIDATE_ATTESTED")
                generation = expected + 1
                current = self._authority(candidate_handle, str(candidate.path), generation)
                final = self._base_record(
                    request, generation, "managed", self._attempt(candidate, "complete", "succeeded", "RUNTIME_ATTESTED"),
                    current=current, previous=state["current"]
                )
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
                failed = self._base_record(
                    request, generation, "failed", self._attempt(candidate, "failed", "failed", "ACTIVATION_FAILED"),
                    current=current, previous=state.get("previous")
                )
                self.store.commit(expected, failed)
                raise

    def rollback(self, request: ReleaseRequest) -> dict[str, Any]:
        self._validate_request(request)
        with self.store.locked():
            state = self.store.load()
            if not state or state["status"] != "managed" or "current" not in state or "previous" not in state:
                raise StateError("rollback requires managed current and previous authority")
            target = state["previous"]
            sequence = self._next_attempt_sequence(state)
            candidate = Candidate(Path(target["releasePath"]), target["releaseSha"], self.new_id(), sequence, (), compose_health_targets(request.contract, request.policy))
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
            handle = self.adapter.resolve_persisted(authority["handle"])
            targets = compose_health_targets(request.contract, request.policy)
            try:
                self.adapter.attest(handle, authority["releaseSha"], targets)
                restored = handle
            except ProcessError:
                restored = self.adapter.restore(handle)
                self.adapter.attest(restored, authority["releaseSha"], targets)
            self.adapter.persist(restored)
            generation = state["generation"] + 1
            restored_authority = self._authority(restored, authority["releasePath"], generation)
            candidate = Candidate(Path(authority["releasePath"]), state["attempt"]["targetSha"], state["attempt"]["attemptId"], state["attempt"]["sequence"], (), targets)
            slot = "current" if "current" in state else "legacy"
            if slot == "legacy":
                restored_authority = authority
            failed = self._base_record(
                request, generation, "failed", self._attempt(candidate, "failed", "failed", "RECOVERY_RESTORED"), **{slot: restored_authority}
            )
            return self.store.commit(state["generation"], failed)
