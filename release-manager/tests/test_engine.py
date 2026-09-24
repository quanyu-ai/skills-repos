#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine import (  # noqa: E402
    AtomicStateStore,
    FakeLifecycleRunner,
    FakeProcessAdapter,
    FakeProcessRuntime,
    FakeSourceProvider,
    GenerationConflict,
    MigrationApprovalReceipt,
    MigrationGateRequired,
    ReleaseEngine,
    ReleaseRequest,
)
from engine.errors import ArtifactError, ContractError, ProcessError, SourceAttestationError, StateError  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40


class IdSequence:
    def __init__(self) -> None:
        self.value = 0

    def __call__(self) -> str:
        self.value += 1
        return f"00000000-0000-4000-8000-{self.value:012d}"


class EngineTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_root = self.root / "source"
        (self.source_root / "node_modules/next/dist/bin").mkdir(parents=True)
        (self.source_root / "node_modules/next/dist/bin/next").write_text("next\n")
        (self.source_root / "apps/web").mkdir(parents=True)
        (self.source_root / "apps/web/next-env.d.ts").write_text("baseline\n")
        (self.source_root / "package.json").write_text(json.dumps({
            "packageManager": "pnpm@9.15.4",
            "engines": {"node": ">=20"},
        }))
        self.contract = json.loads((ROOT / "fixtures/valid/release-contract.json").read_text())
        self.policy = json.loads((ROOT / "fixtures/valid/environment-policy.json").read_text())
        self.runtime = FakeProcessRuntime()
        self.runtime.available_secret_names = set(self.policy["secrets"]["requiredNames"])
        self.ids = IdSequence()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def request(self, sha: str, contract: dict | None = None) -> ReleaseRequest:
        return ReleaseRequest(
            source="fake://repository",
            target_sha=sha,
            contract=copy.deepcopy(contract or self.contract),
            policy=copy.deepcopy(self.policy),
            build_environment={
                "HOME": "/tmp/release-home",
                "PATH": "/tmp/attacker-first:/usr/bin:/bin",
                "NEXT_DIST_DIR": "caller-must-not-win",
                "NODE_CHANNEL_FD": "forbidden",
                "NODE_UNIQUE_ID": "forbidden",
                "DATABASE_URL": "must-not-enter-build",
            },
        )

    def components(self, sha: str, reported_sha: str | None = None, runtime: FakeProcessRuntime | None = None):
        source = FakeSourceProvider(self.source_root, sha, reported_sha)
        runner = FakeLifecycleRunner()
        runner.outputs = ["packages/db/generated", "apps/web/.next-demo/BUILD_ID"]
        adapter = FakeProcessAdapter(runtime or self.runtime, instance_id="123e4567-e89b-42d3-a456-426614174010")
        store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock")
        engine = ReleaseEngine(
            source,
            runner,
            adapter,
            store,
            self.root / f"work-{sha[0]}",
            trusted_path=("/opt/release-manager/bin", "/usr/bin", "/bin"),
            now=lambda: "2026-09-23T15:00:00Z",
            new_id=self.ids,
        )
        return engine, source, runner, adapter, store

    def approval(self, request: ReleaseRequest, state: dict, **overrides) -> MigrationApprovalReceipt:
        values = {
            "target_sha": request.target_sha,
            "release_contract_digest": ReleaseEngine._digest(request.contract),
            "environment_policy_digest": ReleaseEngine._digest(request.policy),
            "environment_id": request.policy["metadata"]["environmentId"],
            "service_id": request.policy["metadata"]["serviceId"],
            "attempt_id": state["attempt"]["attemptId"],
            "state_generation": state["generation"],
            "gate_id": "db-gate:approval-0001",
            "approved_at": "2026-09-23T15:00:00Z",
        }
        values.update(overrides)
        return MigrationApprovalReceipt(**values)

    def legacy_spec(self) -> dict:
        descriptor = json.loads((ROOT / "fixtures/valid/legacy-restore-descriptor.json").read_text())
        release = self.source_root.resolve()
        executable = str((release / "node_modules/next/dist/bin/next").resolve())
        cwd = str((release / "apps/web").resolve())
        listener = {"host": self.policy["network"]["internalHost"], "port": self.policy["network"]["internalPort"]}
        descriptor["metadata"] = {"environmentId": self.policy["metadata"]["environmentId"], "serviceId": self.policy["metadata"]["serviceId"]}
        descriptor["observedAuthority"].update({
            "releaseSha": "f" * 40,
            "releasePath": str(release),
            "namespace": self.policy["process"]["namespace"],
            "stableName": self.policy["process"]["stableName"],
            "invocation": {"executable": executable, "args": ["start", "-H", listener["host"], "-p", str(listener["port"])], "cwd": cwd},
            "listener": listener,
        })
        descriptor["restoreRecipe"]["source"] = {"releaseSha": "f" * 40, "releasePath": str(release)}
        descriptor["restoreRecipe"]["payload"] = {"executable": executable, "args": ["start"], "cwd": cwd}
        descriptor["restoreRecipe"]["bootstrap"]["cwd"] = cwd
        descriptor["restoreRecipe"]["listener"] = listener
        return descriptor

    def adopt_a(self):
        engine, source, runner, adapter, store = self.components(SHA_A)
        state = engine.adopt(self.request(SHA_A), self.legacy_spec())
        return state, engine, source, runner, adapter, store

    def simulate_host_restart(self, state: dict, boot_id: str = "22222222-2222-4222-8222-222222222222") -> dict:
        old_id = state["current"]["handle"]["identity"]["adapterId"]
        item = self.runtime.records.pop(old_id)
        self.runtime.current_boot_id = boot_id
        new_id = str(self.runtime.next_id)
        self.runtime.next_id += 1
        live = copy.deepcopy(item["record"])
        live["identity"].update({
            "adapterId": new_id,
            "pid": 10000 + int(new_id),
            "processStartId": f"{boot_id}:{1000 + int(new_id)}",
        })
        live["provenance"] = {
            "origin": "started",
            "observationId": self.ids(),
            "observedAt": "2026-09-23T15:00:00Z",
            "adapterReceipt": f"fake-resurrected-receipt-{new_id}",
        }
        self.runtime.known_receipts.add(live["provenance"]["adapterReceipt"])
        replacement = copy.deepcopy(item)
        replacement["record"] = live
        self.runtime.records[new_id] = replacement
        return replacement

    def reconcile_a(self):
        state, *_ = self.adopt_a()
        live = self.simulate_host_restart(state)
        engine, _, _, adapter, store = self.components(SHA_A)
        result = engine.reconcile_managed_authority(
            self.request(SHA_A), expected_generation=state["generation"]
        )
        return state, live, result, engine, adapter, store

    def test_schema_validation_precedes_source_acquisition(self) -> None:
        engine, source, *_ = self.components(SHA_A)
        request = self.request(SHA_A)
        request.contract["unknown"] = True
        with self.assertRaises(ContractError):
            engine.build_candidate(request)
        self.assertEqual(0, source.acquisitions)

    def test_host_restart_reconciliation_commits_one_generation_and_typed_receipt(self) -> None:
        state, _, result, engine, adapter, store = self.reconcile_a()
        self.assertEqual("reconciled", result.status)
        reconciled = result.state
        self.assertEqual(state["generation"] + 1, reconciled["generation"])
        self.assertEqual(state["current"]["releaseSha"], reconciled["current"]["releaseSha"])
        self.assertEqual(state["current"]["releasePath"], reconciled["current"]["releasePath"])
        self.assertEqual(state["attempt"], reconciled["attempt"])
        reconciliation_events = adapter.runtime.events[
            adapter.runtime.events.index("observe-managed-after-host-restart"):
        ]
        self.assertEqual(["observe-managed-after-host-restart", "attest"], reconciliation_events)
        receipt = result.receipt
        self.assertIsNotNone(receipt)
        assert receipt is not None
        self.assertEqual("host-restart", receipt["reason"])
        self.assertEqual(state["generation"], receipt["priorGeneration"])
        self.assertEqual(reconciled["generation"], receipt["newGeneration"])
        self.assertEqual(engine._digest(state["current"]["handle"]), receipt["oldHandleDigest"])
        self.assertEqual(engine._digest(reconciled["current"]["handle"]), receipt["newHandleDigest"])
        payload = copy.deepcopy(receipt)
        digest = payload.pop("receiptDigest")
        self.assertEqual(engine._digest(payload), digest)
        self.assertEqual(reconciled, store.load())

    def test_host_restart_reconciliation_is_idempotent(self) -> None:
        _, _, first, engine, adapter, store = self.reconcile_a()
        event_count = len(adapter.runtime.events)
        second = engine.reconcile_managed_authority(
            self.request(SHA_A), expected_generation=first.state["generation"]
        )
        self.assertEqual("reconciliation-not-required", second.status)
        self.assertIsNone(second.receipt)
        self.assertEqual(first.state, second.state)
        self.assertEqual(first.state, store.load())
        self.assertNotIn("persist", adapter.runtime.events[event_count:])

    def test_same_boot_identity_change_is_rejected(self) -> None:
        state, *_ = self.adopt_a()
        self.simulate_host_restart(state, self.runtime.current_boot_id)
        engine, _, _, _, store = self.components(SHA_A)
        with self.assertRaisesRegex(ProcessError, "same-boot"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        self.assertEqual(state, store.load())

    def test_reconciliation_rejects_malformed_persisted_boot_evidence(self) -> None:
        state, *_ = self.adopt_a()
        state["current"]["handle"]["identity"]["processStartId"] = "pid-only-123"
        store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock")
        store.state_file.write_text(json.dumps(state), encoding="utf-8")
        self.simulate_host_restart(state)
        engine, _, _, _, _ = self.components(SHA_A)
        with self.assertRaisesRegex(ProcessError, "Linux boot evidence"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])

    def test_reconciliation_rejects_durable_authority_mismatches(self) -> None:
        state, *_ = self.adopt_a()
        item = self.simulate_host_restart(state)
        engine, _, _, _, store = self.components(SHA_A)
        mutations = (
            ("release SHA", lambda: item["record"].__setitem__("releaseSha", SHA_B), lambda: item["record"].__setitem__("releaseSha", SHA_A)),
            ("runtime executable", lambda: item["record"]["runtime"].__setitem__("executable", "/tmp/other"), lambda: item["record"]["runtime"].__setitem__("executable", state["current"]["handle"]["runtime"]["executable"])),
            ("runtime args", lambda: item["record"]["runtime"].__setitem__("args", ["other"]), lambda: item["record"]["runtime"].__setitem__("args", state["current"]["handle"]["runtime"]["args"])),
            ("runtime cwd", lambda: item["record"]["runtime"].__setitem__("cwd", "/tmp"), lambda: item["record"]["runtime"].__setitem__("cwd", state["current"]["handle"]["runtime"]["cwd"])),
            ("stable identity", lambda: item.__setitem__("stableName", "other-service"), lambda: item.__setitem__("stableName", self.policy["process"]["stableName"])),
            ("release path", lambda: item.__setitem__("releasePath", "/tmp/other"), lambda: item.__setitem__("releasePath", state["current"]["releasePath"])),
            ("listener", lambda: item.__setitem__("listener", {"host": "127.0.0.1", "port": 65530}), lambda: item.__setitem__("listener", {"host": self.policy["network"]["internalHost"], "port": self.policy["network"]["internalPort"]})),
        )
        for label, mutate, restore in mutations:
            with self.subTest(field=label):
                mutate()
                with self.assertRaises(ProcessError):
                    engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
                restore()
                self.assertEqual(state, store.load())

    def test_reconciliation_rejects_each_configuration_digest_mismatch(self) -> None:
        state, *_ = self.adopt_a()
        item = self.simulate_host_restart(state)
        engine, _, _, _, store = self.components(SHA_A)
        for name in ("releaseContract", "environmentPolicy", "build", "runtime"):
            with self.subTest(digest=name):
                original = item["record"]["configurationDigests"][name]
                item["record"]["configurationDigests"][name] = "sha256:" + "0" * 64
                with self.assertRaises(ProcessError):
                    engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
                item["record"]["configurationDigests"][name] = original
                self.assertEqual(state, store.load())

    def test_reconciliation_rejects_multiple_process_health_failure_and_stale_generation(self) -> None:
        state, *_ = self.adopt_a()
        item = self.simulate_host_restart(state)
        engine, _, _, adapter, store = self.components(SHA_A)
        duplicate = copy.deepcopy(item)
        duplicate["record"]["identity"].update({"adapterId": "999", "pid": 10999, "processStartId": f"{self.runtime.current_boot_id}:9999"})
        self.runtime.records["999"] = duplicate
        with self.assertRaisesRegex(ProcessError, "exactly one"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        self.runtime.records.pop("999")
        adapter.runtime.fail_attestation_for_sha = SHA_A
        with self.assertRaisesRegex(ProcessError, "health"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        adapter.runtime.fail_attestation_for_sha = None
        events = list(adapter.runtime.events)
        with self.assertRaisesRegex(StateError, "stale reconciliation generation"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"] - 1)
        self.assertEqual(events, adapter.runtime.events)
        self.assertEqual(state, store.load())

    def test_reconciliation_rejects_unscoped_overlapping_listener_owner(self) -> None:
        state, *_ = self.adopt_a()
        item = self.simulate_host_restart(state)
        engine, _, _, _, store = self.components(SHA_A)
        residual = copy.deepcopy(item)
        residual["record"]["identity"].update({
            "environmentId": "other-demo",
            "serviceId": "other-web",
            "adapterId": "999",
            "pid": 10999,
            "processStartId": f"{self.runtime.current_boot_id}:9999",
        })
        self.runtime.records["999"] = residual
        with self.assertRaisesRegex(ProcessError, "overlapping"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        self.assertEqual(state, store.load())

    def test_reconciliation_preserves_previous_and_attempt(self) -> None:
        self.adopt_a()
        engine_b, *_ = self.components(SHA_B)
        state = engine_b.activate(self.request(SHA_B))
        previous = copy.deepcopy(state["previous"])
        attempt = copy.deepcopy(state["attempt"])
        self.simulate_host_restart(state)
        engine, _, _, _, _ = self.components(SHA_B)
        result = engine.reconcile_managed_authority(self.request(SHA_B), expected_generation=state["generation"])
        self.assertEqual(previous, result.state["previous"])
        self.assertEqual(attempt, result.state["attempt"])

    def test_reconciliation_atomic_fault_preserves_old_valid_state(self) -> None:
        state, *_ = self.adopt_a()
        self.simulate_host_restart(state)
        engine, _, _, _, _ = self.components(SHA_A)
        def fault(point: str) -> None:
            if point == "after-temp-fsync":
                raise RuntimeError("injected reconciliation crash")
        engine.store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock", fault)
        with self.assertRaisesRegex(RuntimeError, "injected reconciliation crash"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        self.assertEqual(state, AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock").load())

    def test_reconciliation_atomic_fault_after_replace_leaves_complete_new_state(self) -> None:
        state, *_ = self.adopt_a()
        self.simulate_host_restart(state)
        engine, _, _, _, _ = self.components(SHA_A)
        def fault(point: str) -> None:
            if point == "after-replace":
                raise RuntimeError("injected post-replace crash")
        engine.store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock", fault)
        with self.assertRaisesRegex(RuntimeError, "injected post-replace crash"):
            engine.reconcile_managed_authority(self.request(SHA_A), expected_generation=state["generation"])
        persisted = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock").load()
        self.assertEqual(state["generation"] + 1, persisted["generation"])
        self.assertEqual("host-restart", persisted["reconciliations"][-1]["reason"])

    def test_exact_sha_attestation_fails_before_install(self) -> None:
        engine, _, runner, *_ = self.components(SHA_A, reported_sha=SHA_B)
        with self.assertRaises(SourceAttestationError):
            engine.build_candidate(self.request(SHA_A))
        self.assertEqual([], runner.events)

    def test_package_manager_must_be_an_exact_three_part_version(self) -> None:
        (self.source_root / "package.json").write_text(json.dumps({
            "packageManager": "pnpm@9.15",
            "engines": {"node": ">=20"},
        }))
        engine, _, runner, *_ = self.components(SHA_A)
        with self.assertRaisesRegex(Exception, "exact supported version"):
            engine.build_candidate(self.request(SHA_A))
        self.assertEqual([], runner.events)

    def test_policy_secret_names_must_be_declared_by_runtime_contract(self) -> None:
        policy = copy.deepcopy(self.policy)
        policy["secrets"]["requiredNames"].append("UNDECLARED_SECRET")
        request = self.request(SHA_A)
        request = ReleaseRequest(request.source, request.target_sha, request.contract, policy, request.build_environment)
        engine, source, *_ = self.components(SHA_A)
        with self.assertRaisesRegex(ContractError, "classification must be complete"):
            engine.build_candidate(request)
        self.assertEqual(0, source.acquisitions)

    def test_missing_runtime_secret_blocks_candidate_and_restores_legacy(self) -> None:
        engine, _, _, adapter, store = self.components(SHA_A)
        adapter.runtime.available_secret_names.remove("DATABASE_URL")
        with self.assertRaisesRegex(ProcessError, "runtime secret names unavailable"):
            engine.adopt(self.request(SHA_A), self.legacy_spec())
        state = store.load()
        self.assertEqual("failed", state["status"])
        self.assertEqual("f" * 40, state["legacy"]["releaseSha"])
        self.assertNotIn("current", state)

    def test_frozen_install_lifecycle_order_and_sanitized_environment(self) -> None:
        engine, _, runner, *_ = self.components(SHA_A)
        candidate = engine.build_candidate(self.request(SHA_A))
        self.assertEqual(SHA_A, candidate.sha)
        self.assertEqual("frozen-install", runner.events[0][0])
        self.assertEqual("pnpm@9.15.4", runner.events[0][1]["packageManager"])
        phases = [event[1]["action"].get("packageScript") for event in runner.events[1:]]
        self.assertEqual(["db:generate", "build", "test:release"], phases)
        for _, evidence in runner.events:
            env = evidence["env"]
            self.assertEqual("true", env["CI"])
            self.assertNotIn("NODE_CHANNEL_FD", env)
            self.assertNotIn("NODE_UNIQUE_ID", env)
            self.assertNotIn("DATABASE_URL", env)
            self.assertEqual(".next-demo", env["NEXT_DIST_DIR"])
            self.assertEqual("/opt/release-manager/bin:/usr/bin:/bin", env["PATH"])

    def test_runtime_configuration_is_complete_and_attested(self) -> None:
        state, *_ = self.adopt_a()
        handle = state["current"]["handle"]
        self.assertEqual(state["releaseContractDigest"], handle["configurationDigests"]["releaseContract"])
        self.assertEqual(state["environmentPolicyDigest"], handle["configurationDigests"]["environmentPolicy"])
        self.assertEqual(state["releaseContractDigest"], state["attempt"]["releaseContractDigest"])
        self.assertEqual(state["environmentPolicyDigest"], state["attempt"]["environmentPolicyDigest"])
        self.assertRegex(handle["configurationDigests"]["build"], r"^sha256:[a-f0-9]{64}$")
        self.assertRegex(handle["configurationDigests"]["runtime"], r"^sha256:[a-f0-9]{64}$")
        started = self.runtime.started_specs[-1]
        values = {item["name"]: item["value"] for item in started["nonSecretValues"]}
        self.assertEqual(".next-demo", values["NEXT_DIST_DIR"])

    def _assert_activation_drift_rejected(self, mutate) -> None:
        state, *_ = self.adopt_a()
        engine, _, _, adapter, store = self.components(SHA_B)
        request = self.request(SHA_B)
        original_build = engine.build_candidate

        def build_then_drift(active_request, active_state=None):
            candidate = original_build(active_request, active_state)
            mutate(active_request)
            return candidate

        engine.build_candidate = build_then_drift
        events_before = list(adapter.runtime.events)
        with self.assertRaises(ContractError):
            engine.activate(request)
        self.assertEqual(events_before, adapter.runtime.events)
        self.assertEqual(state, store.load())

    def test_contract_only_runtime_args_drift_rejected_before_process_mutation(self) -> None:
        self._assert_activation_drift_rejected(lambda request: request.contract["runtime"]["args"].append("--drift"))

    def test_contract_only_env_classification_drift_rejected_before_process_mutation(self) -> None:
        self._assert_activation_drift_rejected(lambda request: request.contract["runtime"]["nonSecretEnvNames"].remove("NODE_ENV"))

    def test_contract_only_binding_drift_rejected_before_process_mutation(self) -> None:
        def mutate(request):
            request.contract["runtime"]["binding"]["hostEnv"] = "SERVER_HOST"
            request.contract["runtime"]["envNames"].remove("HOST")
            request.contract["runtime"]["envNames"].append("SERVER_HOST")
        self._assert_activation_drift_rejected(mutate)

    def test_contract_only_artifact_runtime_drift_rejected_before_process_mutation(self) -> None:
        self._assert_activation_drift_rejected(lambda request: request.contract["artifact"]["required"].append("package.json"))

    def test_contract_only_runtime_executable_drift_rejected_before_process_mutation(self) -> None:
        self._assert_activation_drift_rejected(lambda request: request.contract["runtime"].__setitem__("executable", "package.json"))

    def test_policy_only_drift_rejected_before_process_mutation(self) -> None:
        self._assert_activation_drift_rejected(lambda request: request.policy["health"].__setitem__("attempts", request.policy["health"]["attempts"] + 1))

    def test_missing_runtime_non_secret_value_fails_before_source(self) -> None:
        request = self.request(SHA_A)
        request.policy["runtime"]["values"] = [item for item in request.policy["runtime"]["values"] if item["name"] != "NEXT_DIST_DIR"]
        engine, source, *_ = self.components(SHA_A)
        with self.assertRaisesRegex(ContractError, "incomplete or undeclared"):
            engine.build_candidate(request)
        self.assertEqual(0, source.acquisitions)

    def test_secret_non_secret_and_phase_mismatch_fail_closed(self) -> None:
        engine, source, *_ = self.components(SHA_A)
        request = self.request(SHA_A)
        request.contract["runtime"]["nonSecretEnvNames"].append("JWT_ACCESS_SECRET")
        with self.assertRaises(ContractError): engine.build_candidate(request)
        self.assertEqual(0, source.acquisitions)
        request = self.request(SHA_A)
        for item in request.policy["runtime"]["values"]:
            if item["name"] == "NEXT_DIST_DIR": item["value"] = ".next-other"
        with self.assertRaisesRegex(ContractError, "build/runtime binding mismatch"): engine.build_candidate(request)

    def test_missing_prepare_output_fails_before_process_mutation(self) -> None:
        engine, _, runner, adapter, *_ = self.components(SHA_A)
        runner.outputs = ["apps/web/.next-demo/BUILD_ID"]
        with self.assertRaisesRegex(ArtifactError, "prepare output missing"):
            engine.build_candidate(self.request(SHA_A))
        self.assertEqual([], adapter.runtime.events)

    def test_unexpected_tracked_mutation_fails(self) -> None:
        engine, _, runner, *_ = self.components(SHA_A)
        runner.mutate = {"package.json": b"{}\n"}
        with self.assertRaisesRegex(ArtifactError, "unexpected tracked mutations"):
            engine.build_candidate(self.request(SHA_A))

    def test_allowlisted_tracked_mutation_is_restored(self) -> None:
        engine, _, runner, *_ = self.components(SHA_A)
        runner.mutate = {"apps/web/next-env.d.ts": b"generated\n"}
        candidate = engine.build_candidate(self.request(SHA_A))
        self.assertEqual("baseline\n", (candidate.path / "apps/web/next-env.d.ts").read_text())

    def test_runtime_paths_are_repository_root_relative_and_canonical(self) -> None:
        state, *_ = self.adopt_a()
        release_root = Path(state["current"]["releasePath"])
        runtime = state["current"]["handle"]["runtime"]
        self.assertEqual((release_root / "node_modules/next/dist/bin/next").resolve(), Path(runtime["executable"]))
        self.assertEqual((release_root / "apps/web").resolve(), Path(runtime["cwd"]))

    def test_runtime_executable_symlink_cannot_escape_release_root(self) -> None:
        outside = self.root / "outside-next"
        outside.write_text("outside\n")
        executable = self.source_root / "node_modules/next/dist/bin/next"
        executable.unlink()
        executable.symlink_to(outside)
        engine, _, _, adapter, *_ = self.components(SHA_A)
        with self.assertRaisesRegex(ArtifactError, "runtime executable escapes release root"):
            engine.build_candidate(self.request(SHA_A))
        self.assertEqual([], adapter.runtime.events)

    def test_runtime_cwd_symlink_cannot_escape_release_root(self) -> None:
        outside = self.root / "outside-cwd"
        outside.mkdir()
        cwd = self.source_root / "apps/web"
        (cwd / "next-env.d.ts").unlink()
        cwd.rmdir()
        cwd.symlink_to(outside, target_is_directory=True)
        engine, _, _, adapter, *_ = self.components(SHA_A)
        with self.assertRaisesRegex(ArtifactError, "runtime cwd escapes release root"):
            engine.build_candidate(self.request(SHA_A))
        self.assertEqual([], adapter.runtime.events)

    def test_migration_gate_persists_wait_state_without_adapter_use(self) -> None:
        contract = copy.deepcopy(self.contract)
        contract["migration"]["mode"] = "approval-gated"
        engine, _, _, adapter, store = self.components(SHA_A)
        with self.assertRaises(MigrationGateRequired):
            engine.adopt(self.request(SHA_A, contract), self.legacy_spec())
        state = store.load()
        self.assertEqual("waiting-db-gate", state["attempt"]["phase"])
        self.assertEqual("candidate-ready", state["status"])
        self.assertEqual([], adapter.runtime.events)

    def test_migration_gate_approved_resume_uses_new_attempt(self) -> None:
        contract = copy.deepcopy(self.contract)
        contract["migration"]["mode"] = "approval-gated"
        engine, _, _, _, store = self.components(SHA_A)
        request = self.request(SHA_A, contract)
        with self.assertRaises(MigrationGateRequired):
            engine.adopt(request, self.legacy_spec())
        waiting = store.load()
        resumed = engine.adopt(request, self.legacy_spec(), approval=self.approval(request, waiting))
        self.assertEqual("managed", resumed["status"])
        self.assertGreater(resumed["attempt"]["sequence"], waiting["attempt"]["sequence"])
        self.assertNotEqual(resumed["attempt"]["attemptId"], waiting["attempt"]["attemptId"])
        self.assertEqual("DB_GATE_APPROVED", resumed["attempt"]["events"][0]["type"])
        self.assertIn("evidenceDigest", resumed["attempt"]["events"][0])

    def test_migration_receipt_mismatch_fails_before_source_or_process_mutation(self) -> None:
        contract = copy.deepcopy(self.contract)
        contract["migration"]["mode"] = "approval-gated"
        engine, source, _, adapter, store = self.components(SHA_A)
        request = self.request(SHA_A, contract)
        with self.assertRaises(MigrationGateRequired):
            engine.adopt(request, self.legacy_spec())
        waiting = store.load()
        acquisitions = source.acquisitions
        events = list(adapter.runtime.events)
        mismatches = (
            ("target_sha", SHA_B),
            ("release_contract_digest", "sha256:" + "0" * 64),
            ("environment_policy_digest", "sha256:" + "1" * 64),
            ("environment_id", "other-demo"),
            ("service_id", "other-web"),
            ("attempt_id", "00000000-0000-4000-8000-999999999999"),
            ("state_generation", waiting["generation"] + 1),
        )
        for field, wrong in mismatches:
            with self.subTest(field=field):
                with self.assertRaisesRegex(ContractError, "receipt .* mismatch"):
                    engine.adopt(request, self.legacy_spec(), approval=self.approval(request, waiting, **{field: wrong}))
                self.assertEqual(acquisitions, source.acquisitions)
                self.assertEqual(events, adapter.runtime.events)

    def test_adoption_success_commits_only_attested_candidate(self) -> None:
        state, _, _, _, adapter, store = self.adopt_a()
        self.assertEqual("managed", state["status"])
        self.assertEqual(SHA_A, state["current"]["releaseSha"])
        self.assertNotIn("previous", state)
        self.assertNotIn("legacy", state)
        self.assertEqual(state, store.load())
        self.assertLess(adapter.runtime.events.index("attest"), adapter.runtime.events.index("persist"))

    def test_adoption_failure_restores_legacy_and_excludes_candidate(self) -> None:
        engine, _, _, adapter, store = self.components(SHA_A)
        adapter.runtime.fail_attestation_for_sha = SHA_A
        with self.assertRaises(ProcessError):
            engine.adopt(self.request(SHA_A), self.legacy_spec())
        state = store.load()
        self.assertEqual("failed", state["status"])
        self.assertEqual("f" * 40, state["legacy"]["releaseSha"])
        self.assertNotIn("current", state)
        self.assertNotIn("previous", state)
        online = [item["record"]["releaseSha"] for item in adapter.runtime.records.values() if item["status"] == "online"]
        self.assertEqual(["f" * 40], online)

    def test_activation_success_sets_current_and_previous_generations(self) -> None:
        self.adopt_a()
        engine, _, _, _, store = self.components(SHA_B)
        state = engine.activate(self.request(SHA_B))
        self.assertEqual(SHA_B, state["current"]["releaseSha"])
        self.assertEqual(SHA_A, state["previous"]["releaseSha"])
        self.assertLess(state["previous"]["generation"], state["current"]["generation"])
        self.assertEqual(state, store.load())

    def test_activation_health_failure_restores_exact_current(self) -> None:
        self.adopt_a()
        engine, _, _, adapter, store = self.components(SHA_B)
        adapter.runtime.fail_attestation_for_sha = SHA_B
        with self.assertRaises(ProcessError):
            engine.activate(self.request(SHA_B))
        state = store.load()
        self.assertEqual("failed", state["status"])
        self.assertEqual(SHA_A, state["current"]["releaseSha"])
        self.assertNotEqual(SHA_B, state["current"]["releaseSha"])
        online = [item["record"]["releaseSha"] for item in adapter.runtime.records.values() if item["status"] == "online"]
        self.assertEqual([SHA_A], online)

    def test_ambiguous_inventory_fails_before_current_stop(self) -> None:
        self.adopt_a()
        engine, _, _, adapter, store = self.components(SHA_B)
        adapter.runtime.ambiguous_inventory = True
        with self.assertRaises(ProcessError):
            engine.activate(self.request(SHA_B))
        self.assertNotIn("stop-exact", adapter.runtime.events[-5:])
        self.assertEqual(SHA_A, store.load()["current"]["releaseSha"])

    def test_canonical_rollback_promotes_attested_previous(self) -> None:
        self.adopt_a()
        engine_b, *_ = self.components(SHA_B)
        engine_b.activate(self.request(SHA_B))
        engine_c, _, _, adapter, store = self.components(SHA_C)
        state = engine_c.rollback(self.request(SHA_C))
        self.assertEqual(SHA_A, state["current"]["releaseSha"])
        self.assertEqual(SHA_B, state["previous"]["releaseSha"])
        self.assertEqual(adapter.runtime.persisted_adapter_id, state["current"]["handle"]["identity"]["adapterId"])
        self.assertEqual(state, store.load())

    def test_rollback_target_failure_restores_original_and_excludes_target(self) -> None:
        self.adopt_a()
        engine_b, *_ = self.components(SHA_B)
        engine_b.activate(self.request(SHA_B))
        engine_c, _, _, adapter, store = self.components(SHA_C)
        adapter.runtime.fail_attestation_for_sha = SHA_A
        with self.assertRaises(ProcessError):
            engine_c.rollback(self.request(SHA_C))
        state = store.load()
        self.assertEqual("failed", state["status"])
        self.assertEqual(SHA_B, state["current"]["releaseSha"])
        self.assertNotIn("previous", state)
        online = [item["record"]["releaseSha"] for item in adapter.runtime.records.values() if item["status"] == "online"]
        self.assertEqual([SHA_B], online)

    def test_persisted_managed_state_reloads_and_reattests(self) -> None:
        state, *_ = self.adopt_a()
        engine, _, _, adapter, store = self.components(SHA_B)
        reloaded = engine.recover(self.request(SHA_B))
        self.assertEqual(state, reloaded)
        self.assertIn("resolve-persisted", adapter.runtime.events)
        self.assertIn("attest", adapter.runtime.events)
        self.assertEqual(state, store.load())

    def test_reobserved_runtime_digest_context_mismatch_is_rejected(self) -> None:
        state, *_ = self.adopt_a()
        adapter_id = state["current"]["handle"]["identity"]["adapterId"]
        self.runtime.records[adapter_id]["record"]["configurationDigests"]["releaseContract"] = "sha256:" + "0" * 64
        engine, _, _, adapter, store = self.components(SHA_B)
        events_before = list(adapter.runtime.events)
        with self.assertRaisesRegex(ProcessError, "configuration digest context mismatch"):
            engine.recover(self.request(SHA_B))
        self.assertEqual(events_before, adapter.runtime.events)
        self.assertEqual(state, store.load())

    def test_interrupted_activation_recovers_from_persisted_current(self) -> None:
        state, *_ = self.adopt_a()
        store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock")
        interrupted = copy.deepcopy(state)
        interrupted["generation"] += 1
        interrupted["status"] = "activating"
        interrupted["updatedAt"] = "2026-09-23T15:00:00Z"
        interrupted["attempt"] = {
            "attemptId": self.ids(), "sequence": state["attempt"]["sequence"] + 1,
            "targetSha": SHA_B,
            "releaseContractDigest": state["releaseContractDigest"],
            "environmentPolicyDigest": state["environmentPolicyDigest"],
            "phase": "activating", "outcome": "pending",
            "events": [{"sequence": 1, "at": "2026-09-23T15:00:00Z", "type": "ACTIVATION_STARTED"}],
        }
        store.commit(state["generation"], interrupted)
        engine, _, _, _, store = self.components(SHA_B)
        recovered = engine.recover(self.request(SHA_B))
        self.assertEqual("failed", recovered["status"])
        self.assertEqual(SHA_A, recovered["current"]["releaseSha"])
        self.assertEqual(recovered, store.load())

    def test_interrupted_activation_reconciles_started_candidate_before_restore(self) -> None:
        state, *_ = self.adopt_a()
        engine, _, _, adapter, store = self.components(SHA_B)
        request = self.request(SHA_B)
        candidate = engine.build_candidate(request, state)
        interrupted = copy.deepcopy(state)
        interrupted["generation"] += 1
        interrupted["status"] = "activating"
        interrupted["updatedAt"] = "2026-09-23T15:00:00Z"
        interrupted["attempt"] = {
            "attemptId": candidate.attempt_id, "sequence": candidate.attempt_sequence,
            "targetSha": SHA_B,
            "releaseContractDigest": candidate.release_contract_digest,
            "environmentPolicyDigest": candidate.environment_policy_digest,
            "phase": "activating", "outcome": "pending",
            "events": [{"sequence": 1, "at": "2026-09-23T15:00:00Z", "type": "ACTIVATION_STARTED"}],
        }
        store.commit(state["generation"], interrupted)
        current = adapter.resolve_persisted(state["current"]["handle"])
        adapter.stop_exact(current)
        adapter.delete_exact(current)
        adapter.await_absent(current)
        started = adapter.start_candidate(engine._runtime_spec(request, candidate))
        started_id = started.record["identity"]["adapterId"]

        recovered = engine.recover(request)

        self.assertEqual("failed", recovered["status"])
        self.assertEqual(SHA_A, recovered["current"]["releaseSha"])
        self.assertNotIn(started_id, adapter.runtime.records)
        online = [item["record"]["releaseSha"] for item in adapter.runtime.records.values() if item["status"] == "online"]
        self.assertEqual([SHA_A], online)
        self.assertIn("inventory", adapter.runtime.events)

    def test_atomic_store_failure_before_replace_preserves_prior_generation(self) -> None:
        state, *_ = self.adopt_a()
        def fault(point: str) -> None:
            if point == "after-temp-fsync":
                raise RuntimeError("injected crash")
        crashing = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock", fault)
        next_state = copy.deepcopy(state)
        next_state["generation"] += 1
        next_state["updatedAt"] = "2026-09-23T15:00:01Z"
        with self.assertRaises(RuntimeError):
            crashing.commit(state["generation"], next_state)
        self.assertEqual(state, AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock").load())

    def test_atomic_store_failure_after_replace_leaves_complete_new_generation(self) -> None:
        state, *_ = self.adopt_a()
        def fault(point: str) -> None:
            if point == "after-replace":
                raise RuntimeError("injected crash")
        crashing = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock", fault)
        next_state = copy.deepcopy(state)
        next_state["generation"] += 1
        next_state["updatedAt"] = "2026-09-23T15:00:01Z"
        with self.assertRaises(RuntimeError):
            crashing.commit(state["generation"], next_state)
        self.assertEqual(next_state, AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock").load())

    def test_generation_compare_and_swap_rejects_stale_writer(self) -> None:
        state, *_ = self.adopt_a()
        store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock")
        next_state = copy.deepcopy(state)
        next_state["generation"] += 1
        with self.assertRaises(GenerationConflict):
            store.commit(state["generation"] - 1, next_state)

    def test_failed_build_retry_uses_distinct_immutable_attempt_path(self) -> None:
        engine, _, runner, *_ = self.components(SHA_A)
        runner.fail_on = "build"
        with self.assertRaises(RuntimeError):
            engine.build_candidate(self.request(SHA_A))
        failed_paths = sorted((self.root / "work-a/attempts").iterdir())
        runner.fail_on = None
        candidate = engine.build_candidate(self.request(SHA_A))
        self.assertNotEqual(failed_paths[0], candidate.path.parent)
        self.assertTrue(failed_paths[0].exists())

    def test_forged_persisted_handle_cannot_be_consumed(self) -> None:
        state, *_ = self.adopt_a()
        state = copy.deepcopy(state)
        state["current"]["handle"]["provenance"]["adapterReceipt"] = "forged-receipt-value"
        state["generation"] += 1
        state["updatedAt"] = "2026-09-23T15:00:01Z"
        store = AtomicStateStore(self.root / "state/state.json", self.root / "state/state.lock")
        store.commit(state["generation"] - 1, state)
        engine, *_ = self.components(SHA_B)
        with self.assertRaises(ProcessError):
            engine.recover(self.request(SHA_B))

    def test_health_targets_are_composed_from_split_owners(self) -> None:
        engine, *_ = self.components(SHA_A)
        candidate = engine.build_candidate(self.request(SHA_A))
        self.assertEqual(("http://127.0.0.1:3104/api/health", "https://demo.example.invalid/api/health"), candidate.health_targets)


if __name__ == "__main__":
    unittest.main(verbosity=2)
