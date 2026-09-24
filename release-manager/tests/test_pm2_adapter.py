#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import os
import shutil
import socket
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine import PM2ProcessAdapter  # noqa: E402
from engine.errors import ProcessError  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


@unittest.skipUnless(sys.platform.startswith("linux") and Path("/proc/self/stat").exists(), "requires Linux /proc")
class PM2AdapterIntegrationTest(unittest.TestCase):
    INSTANCE_ID = "123e4567-e89b-42d3-a456-426614174099"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="env1b-c-pm2-")
        self.root = Path(self.temp.name)
        self.pm2_home = self.root / "pm2-home"
        self.node_modules = Path(os.environ.get("PM2_NODE_MODULES", ROOT / "pm2-adapter/node_modules"))
        if not (self.node_modules / "pm2").is_dir():
            self.skipTest("pinned PM2 dependency is not installed")
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node runtime is unavailable")
        self.trusted_path = (str(Path(node).resolve().parent), "/usr/local/bin", "/usr/bin", "/bin")
        self.adapter = PM2ProcessAdapter(
            pm2_home=self.pm2_home,
            node_modules=self.node_modules,
            instance_id=self.INSTANCE_ID,
            stable_name="env1b-c-service",
            secret_owner_uid=os.geteuid(),
            trusted_path=self.trusted_path,
            health_attempts=30,
            health_interval_seconds=0.1,
        )
        self.created_handles = []

    def restarted_adapter(self, spec: dict, *, secret_owner_uid: int | None = None, legacy_descriptor: dict | None = None) -> PM2ProcessAdapter:
        return PM2ProcessAdapter(
            pm2_home=self.pm2_home,
            node_modules=self.node_modules,
            instance_id=self.INSTANCE_ID,
            stable_name="env1b-c-service",
            secret_owner_uid=os.geteuid() if secret_owner_uid is None else secret_owner_uid,
            trusted_path=self.trusted_path,
            health_attempts=30,
            health_interval_seconds=0.1,
            runtime_policy=self.runtime_policy(spec),
            legacy_restore_descriptor=legacy_descriptor,
        )

    def tearDown(self) -> None:
        try:
            self.adapter.kill_isolated_daemon()
        except Exception:
            pass
        self.temp.cleanup()

    def spec(self, sha: str, status: int = 200, mode: int = 0o600) -> tuple[dict, Path, Path]:
        release = self.root / "releases" / sha
        release.mkdir(parents=True)
        script = release / "disposable-http-service.cjs"
        shutil.copy2(ROOT / "tests/fixtures/disposable-http-service.cjs", script)
        report = self.root / f"env-{sha[0]}.json"
        secrets = self.root / f"secrets-{sha[0]}.json"
        secrets.write_text(json.dumps({
            "TEST_SECRET": f"fake-secret-{sha[0]}-must-not-leak",
            "TEST_HEALTH_STATUS": str(status),
            "TEST_ENV_REPORT": str(report),
        }))
        secrets.chmod(mode)
        port = free_port()
        spec = {
            "environmentId": "env1b-c-test",
            "serviceId": "disposable-web",
            "namespace": "env1b-c-isolated",
            "stableName": "env1b-c-service",
            "releaseSha": sha,
            "releasePath": str(release),
            "runtime": {"executable": str(script.resolve()), "args": [], "cwd": str(release.resolve())},
            "observedAt": "2026-09-24T00:00:00Z",
            "allowedEnvNames": ["NODE_ENV", "NEXT_DIST_DIR", "HOST", "PORT", "TEST_SECRET", "TEST_HEALTH_STATUS", "TEST_ENV_REPORT"],
            "requiredSecretNames": ["TEST_SECRET", "TEST_HEALTH_STATUS", "TEST_ENV_REPORT"],
            "nonSecretValues": [{"name": "NODE_ENV", "value": "production"}, {"name": "NEXT_DIST_DIR", "value": ".next-demo"}],
            "configurationDigests": {"releaseContract": "sha256:" + "3" * 64, "environmentPolicy": "sha256:" + "4" * 64, "build": "sha256:" + "1" * 64, "runtime": "sha256:" + "2" * 64},
            "secretSource": {"provider": "external-json-file", "sourcePath": str(secrets)},
            "binding": {"HOST": "127.0.0.1", "PORT": str(port)},
            "listener": {"host": "127.0.0.1", "port": port},
            "health": {"acceptedStatusClasses": [2], "attempts": 30, "intervalMs": 100},
        }
        return spec, report, secrets

    @staticmethod
    def targets(spec: dict) -> tuple[str, str]:
        url = f"http://{spec['binding']['HOST']}:{spec['binding']['PORT']}/health"
        return url, url

    @staticmethod
    def runtime_policy(spec: dict) -> dict:
        return {
            "allowedEnvNames": copy.deepcopy(spec["allowedEnvNames"]),
            "requiredSecretNames": copy.deepcopy(spec["requiredSecretNames"]),
            "nonSecretValues": copy.deepcopy(spec["nonSecretValues"]),
            "secretSource": copy.deepcopy(spec["secretSource"]),
            "binding": copy.deepcopy(spec["binding"]),
            "listener": copy.deepcopy(spec["listener"]),
            "health": copy.deepcopy(spec["health"]),
        }

    @staticmethod
    def reconciliation_expected(spec: dict) -> dict:
        return {
            "environmentId": spec["environmentId"],
            "serviceId": spec["serviceId"],
            "namespace": spec["namespace"],
            "stableName": spec["stableName"],
            "releaseSha": spec["releaseSha"],
            "releasePath": spec["releasePath"],
            "runtime": copy.deepcopy(spec["runtime"]),
            "configurationDigests": copy.deepcopy(spec["configurationDigests"]),
            "listener": copy.deepcopy(spec["listener"]),
            "health": copy.deepcopy(spec["health"]),
            "observedAt": "2026-09-24T01:00:00Z",
        }

    def legacy_descriptor(self, *, failing_bootstrap: bool = False) -> tuple[dict, Path]:
        release = self.root / "legacy-release" / SHA_A
        cwd = release / "apps/web"
        cwd.mkdir(parents=True)
        payload = cwd / "node_modules/next/dist/bin/next"
        payload.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "tests/fixtures/disposable-next-like.cjs", payload)
        payload.chmod(0o755)
        bootstrap = self.root / "trusted-tools/legacy-bootstrap.cjs"
        bootstrap.parent.mkdir(parents=True)
        if failing_bootstrap:
            bootstrap.write_text("setTimeout(() => process.exit(64), 25);\n")
        else:
            shutil.copy2(ROOT / "tests/fixtures/disposable-legacy-wrapper.cjs", bootstrap)
        secrets = self.root / "legacy-secrets.json"
        secrets.write_text(json.dumps({"TEST_SECRET": "legacy-secret-must-not-leak"}))
        secrets.chmod(0o600)
        listener = {"host": "127.0.0.1", "port": free_port()}
        probe_port = free_port()
        while probe_port == listener["port"]:
            probe_port = free_port()
        descriptor = {
            "apiVersion": "quanyu.ai/legacy-restore-descriptor/v1alpha1",
            "kind": "LegacyRestoreDescriptor",
            "metadata": {"environmentId": "legacy-demo", "serviceId": "legacy-web"},
            "observedAuthority": {
                "releaseSha": SHA_A, "releasePath": str(release), "namespace": "legacy-isolated",
                "stableName": "legacy-service", "adapterId": "pending", "pid": 1,
                "processStartId": "pending",
                "invocation": {"executable": str(payload), "args": ["start", "-H", listener["host"], "-p", str(listener["port"])], "cwd": str(cwd)},
                "listener": dict(listener),
            },
            "restoreRecipe": {
                "source": {"releaseSha": SHA_A, "releasePath": str(release)},
                "bootstrap": {"executable": str(bootstrap), "args": [], "cwd": str(cwd)},
                "payload": {"executable": str(payload), "args": ["start"], "cwd": str(cwd)},
                "listenerAdaptation": {"kind": "argv-host-port", "hostFlag": "-H", "portFlag": "-p"},
                "runtime": {"requiredSecretNames": ["TEST_SECRET"], "requiredSecretNamesFormat": "comma-separated", "runtimeSecretFile": str(secrets), "nonSecretValues": [{"name": "NODE_ENV", "value": "production"}]},
                "secrets": {"provider": "external-json-file", "sourcePath": str(secrets), "requiredNames": ["TEST_SECRET"]},
                "listener": dict(listener),
                "probe": {"host": "127.0.0.1", "port": probe_port},
            },
            "health": {"path": "/api/health", "acceptedStatusClasses": [2], "attempts": 30, "intervalMs": 100},
        }
        return descriptor, secrets

    def start(self, spec: dict):
        handle = self.adapter.start_candidate(spec)
        self.created_handles.append(handle)
        return handle

    def remove(self, handle) -> None:
        self.adapter.stop_exact(handle)
        self.adapter.delete_exact(handle)
        self.adapter.await_absent(handle)

    def cross_boot_process(self, spec: dict):
        old = self.start(spec)
        old_record = copy.deepcopy(old.record)
        self.remove(old)
        live = self.start(spec)
        old_record["identity"]["processStartId"] = "33333333-3333-4333-8333-333333333333:12345"
        restarted = self.restarted_adapter(spec)
        return old_record, live, restarted

    def start_residual(
        self,
        spec: dict,
        *,
        environment_id: str,
        service_id: str,
        namespace: str,
        name: str,
        listener: dict,
    ) -> dict:
        root = self.root / f"residual-{name}"
        root.mkdir()
        script = root / "idle.cjs"
        shutil.copy2(ROOT / "tests/fixtures/disposable-idle-service.cjs", script)
        digests = spec["configurationDigests"]
        return self.adapter._bridge({
            "action": "test-start",
            "app": {
                "name": name,
                "namespace": namespace,
                "script": str(script),
                "args": [],
                "cwd": str(root),
                "env": {
                    "RELEASE_MANAGER_ENVIRONMENT_ID": environment_id,
                    "RELEASE_MANAGER_SERVICE_ID": service_id,
                    "RELEASE_MANAGER_RELEASE_SHA": spec["releaseSha"],
                    "RELEASE_MANAGER_LAUNCH_TOKEN": f"residual-{name}",
                    "RELEASE_MANAGER_OWNED_HOST": listener["host"],
                    "RELEASE_MANAGER_OWNED_PORT": str(listener["port"]),
                    "RELEASE_MANAGER_BUILD_CONFIG_DIGEST": digests["build"],
                    "RELEASE_MANAGER_RUNTIME_CONFIG_DIGEST": digests["runtime"],
                    "RELEASE_MANAGER_RELEASE_CONTRACT_DIGEST": digests["releaseContract"],
                    "RELEASE_MANAGER_ENVIRONMENT_POLICY_DIGEST": digests["environmentPolicy"],
                },
            },
        })["record"]

    def test_exact_handle_external_secrets_health_and_persist_order(self) -> None:
        spec, report, _ = self.spec(SHA_A)
        handle = self.start(spec)
        serialized = json.dumps(handle.record, sort_keys=True)
        self.assertNotIn("fake-secret", serialized)
        self.assertEqual("pm2-programmatic", handle.record["adapter"]["kind"])
        self.assertGreater(handle.record["identity"]["pid"], 0)
        self.assertTrue(handle.record["identity"]["processStartId"])
        with self.assertRaisesRegex(ProcessError, "prior runtime attestation"):
            self.adapter.persist(handle)
        evidence = self.adapter.attest(handle, SHA_A, self.targets(spec))
        self.assertEqual(SHA_A, evidence["releaseSha"])
        self.adapter.persist(handle)
        report_data = json.loads(report.read_text())
        self.assertEqual({"hasNodeChannelFd": False, "hasNodeUniqueId": False, "hasAmbientPoison": False, "nodeEnv": "production", "nextDistDir": ".next-demo"}, report_data)
        self.remove(handle)

    def test_host_restart_reconciliation_uses_fresh_linux_inventory_and_keeps_exact_resolve_strict(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old_record, live, restarted = self.cross_boot_process(spec)
        with self.assertRaisesRegex(
            ProcessError, "cannot be re-observed exactly|PM2 live process identity mismatch"
        ):
            restarted.resolve_persisted(old_record)
        observation = restarted.observe_managed_after_host_restart(
            old_record, self.reconciliation_expected(spec)
        )
        self.assertTrue(observation.reconciliation_required)
        self.assertNotEqual(observation.old_boot_id, observation.current_boot_id)
        host_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        fresh_boot_id = observation.handle.record["identity"]["processStartId"].rsplit(":", 1)[0]
        self.assertEqual(host_boot_id, restarted._current_boot_id())
        self.assertEqual(host_boot_id, observation.current_boot_id)
        self.assertEqual(host_boot_id, fresh_boot_id)
        self.assertEqual(live.record["identity"], observation.handle.record["identity"])
        internal = self.targets(spec)[0]
        public = internal.replace("127.0.0.1", "localhost")
        evidence = restarted.attest(observation.handle, SHA_A, (internal, public))
        self.assertEqual(SHA_A, evidence["releaseSha"])
        self.assertEqual(2, len(evidence["health"]))
        self.assertFalse((self.pm2_home / "dump.pm2").exists())
        self.remove(live)

    def test_reconciliation_rejects_live_process_boot_component_not_matching_host(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old_record, live, restarted = self.cross_boot_process(spec)
        host_boot_id = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        self.assertEqual(host_boot_id, restarted._current_boot_id())
        actual_inventory = restarted._all_inventory

        def mismatched_inventory():
            records = actual_inventory()
            for record in records:
                if record["adapterId"] == live.record["identity"]["adapterId"]:
                    record["evidence"]["processStartId"] = "44444444-4444-4444-8444-444444444444:54321"
            return records

        restarted._all_inventory = mismatched_inventory
        with self.assertRaisesRegex(ProcessError, "does not match current host boot"):
            restarted.observe_managed_after_host_restart(
                old_record, self.reconciliation_expected(spec)
            )
        self.assertFalse((self.pm2_home / "dump.pm2").exists())
        self.remove(live)

    def test_reconciliation_rejects_multiple_scoped_processes(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old_record, live, restarted = self.cross_boot_process(spec)
        self.start_residual(
            spec,
            environment_id=spec["environmentId"],
            service_id=spec["serviceId"],
            namespace=spec["namespace"],
            name="scoped-duplicate",
            listener={"host": "127.0.0.1", "port": free_port()},
        )
        with self.assertRaisesRegex(ProcessError, "exactly one scoped live process"):
            restarted.observe_managed_after_host_restart(
                old_record, self.reconciliation_expected(spec)
            )
        self.assertFalse((self.pm2_home / "dump.pm2").exists())

    def test_reconciliation_rejects_listener_drift_and_unscoped_overlap(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old_record, live, restarted = self.cross_boot_process(spec)
        listener_drift = self.reconciliation_expected(spec)
        listener_drift["listener"]["port"] = free_port()
        with self.assertRaisesRegex(ProcessError, "listener/topology mismatch"):
            restarted.observe_managed_after_host_restart(old_record, listener_drift)

        self.start_residual(
            spec,
            environment_id="other-demo",
            service_id="other-web",
            namespace="other-namespace",
            name="listener-overlap",
            listener=spec["listener"],
        )
        with self.assertRaisesRegex(ProcessError, "overlapping PM2 inventory"):
            restarted.observe_managed_after_host_restart(
                old_record, self.reconciliation_expected(spec)
            )
        self.assertFalse((self.pm2_home / "dump.pm2").exists())

    def test_reconciliation_fresh_handle_health_failure_does_not_persist(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old_record, live, restarted = self.cross_boot_process(spec)
        observation = restarted.observe_managed_after_host_restart(
            old_record, self.reconciliation_expected(spec)
        )
        healthy = self.targets(spec)[0]
        unavailable = f"http://127.0.0.1:{free_port()}/health"
        with self.assertRaisesRegex(ProcessError, "health attestation failed"):
            restarted.attest(observation.handle, SHA_A, (healthy, unavailable))
        self.assertFalse((self.pm2_home / "dump.pm2").exists())
        self.remove(live)

    def test_same_boot_process_change_cannot_use_reconciliation(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        old = self.start(spec)
        old_record = copy.deepcopy(old.record)
        self.remove(old)
        live = self.start(spec)
        restarted = self.restarted_adapter(spec)
        with self.assertRaisesRegex(ProcessError, "same-boot"):
            restarted.observe_managed_after_host_restart(
                old_record, self.reconciliation_expected(spec)
            )
        self.assertFalse((self.pm2_home / "dump.pm2").exists())
        self.remove(live)

    def test_stop_is_not_delete_and_absence_proves_pid_and_port(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        handle = self.start(spec)
        self.adapter.attest(handle, SHA_A, self.targets(spec))
        self.adapter.stop_exact(handle)
        records = self.adapter._all_inventory()
        stopped = [item for item in records if item["adapterId"] == handle.record["identity"]["adapterId"]]
        self.assertEqual(1, len(stopped))
        self.assertEqual("stopped", stopped[0]["status"])
        with self.assertRaises(ProcessError):
            self.adapter.await_absent(handle)
        self.adapter.delete_exact(handle)
        self.adapter.await_absent(handle)

    def test_persisted_handle_reobservation_restores_exact_runtime_after_adapter_restart(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        original = self.start(spec)
        self.adapter.attest(original, SHA_A, self.targets(spec))
        restarted = self.restarted_adapter(spec)
        reobserved = restarted.resolve_persisted(original.record)
        restarted.stop_exact(reobserved)
        restarted.delete_exact(reobserved)
        restarted.await_absent(reobserved)
        restored = restarted.restore(reobserved)
        evidence = restarted.attest(restored, SHA_A, self.targets(spec))
        self.assertEqual(SHA_A, evidence["releaseSha"])
        restarted.stop_exact(restored)
        restarted.delete_exact(restored)
        restarted.await_absent(restored)

    def test_persisted_handle_tamper_requires_exact_live_reobservation(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        original = self.start(spec)
        restarted = self.restarted_adapter(spec)

        receipt_tampered = copy.deepcopy(original.record)
        receipt_tampered["provenance"]["adapterReceipt"] = "sha256:" + "0" * 64
        reminted = restarted.resolve_persisted(receipt_tampered)
        self.assertNotEqual(receipt_tampered["provenance"]["adapterReceipt"], reminted.record["provenance"]["adapterReceipt"])
        self.assertEqual(original.record["identity"], reminted.record["identity"])

        mutations = (
            ("adapter ID", lambda value: value["identity"].__setitem__("adapterId", "999999")),
            ("PID", lambda value: value["identity"].__setitem__("pid", value["identity"]["pid"] + 1)),
            ("start identity", lambda value: value["identity"].__setitem__("processStartId", "tampered:start")),
            ("runtime", lambda value: value["runtime"].__setitem__("args", ["--tampered"])),
            ("release SHA", lambda value: value.__setitem__("releaseSha", SHA_B)),
            ("contract digest context", lambda value: value["configurationDigests"].__setitem__("releaseContract", "sha256:" + "0" * 64)),
        )
        for label, mutate in mutations:
            with self.subTest(field=label):
                tampered = copy.deepcopy(original.record)
                mutate(tampered)
                with self.assertRaises(ProcessError):
                    restarted.resolve_persisted(tampered)
        self.remove(original)

    def test_ecosystem_wrong_name_and_unexpected_residual_block_replacement(self) -> None:
        current_spec, _, _ = self.spec(SHA_A)
        current = self.start(current_spec)
        residual_script = self.root / "ecosystem.cjs"
        shutil.copy2(ROOT / "tests/fixtures/disposable-idle-service.cjs", residual_script)
        residual_token = "residual-test-token"
        self.adapter._bridge({
            "action": "test-start",
            "app": {
                "name": "ecosystem",
                "namespace": current_spec["namespace"],
                "script": str(residual_script),
                "args": [],
                "cwd": current_spec["runtime"]["cwd"],
                "env": {
                    "RELEASE_MANAGER_ENVIRONMENT_ID": current_spec["environmentId"],
                    "RELEASE_MANAGER_SERVICE_ID": current_spec["serviceId"],
                    "RELEASE_MANAGER_RELEASE_SHA": SHA_B,
                    "RELEASE_MANAGER_LAUNCH_TOKEN": residual_token,
                    "RELEASE_MANAGER_OWNED_HOST": "127.0.0.1",
                    "RELEASE_MANAGER_OWNED_PORT": str(free_port()),
                },
            },
        })
        candidate, _, _ = self.spec(SHA_B)
        with self.assertRaisesRegex(ProcessError, "unexpected overlapping"):
            self.adapter.assert_replaceable(current, candidate)
        self.assertTrue(any(item["name"] == "ecosystem" for item in self.adapter._all_inventory()))
        self.remove(current)
        inventory_before_start = self.adapter._all_inventory()
        with self.assertRaisesRegex(ProcessError, "not clear"):
            self.adapter.start_candidate(candidate)
        inventory_after_start = self.adapter._all_inventory()
        self.assertEqual(
            [item["adapterId"] for item in inventory_before_start],
            [item["adapterId"] for item in inventory_after_start],
        )
        self.assertFalse(any(item["name"] == candidate["stableName"] for item in inventory_after_start))

    def test_candidate_health_failure_is_removed_and_exact_current_restored(self) -> None:
        current_spec, _, _ = self.spec(SHA_A)
        current = self.start(current_spec)
        self.adapter.attest(current, SHA_A, self.targets(current_spec))
        self.remove(current)
        candidate_spec, _, _ = self.spec(SHA_B, status=503)
        candidate = self.start(candidate_spec)
        with self.assertRaisesRegex(ProcessError, "health attestation failed"):
            self.adapter.attest(candidate, SHA_B, self.targets(candidate_spec))
        self.remove(candidate)
        restored = self.adapter.restore(current)
        evidence = self.adapter.attest(restored, SHA_A, self.targets(current_spec))
        self.assertEqual(SHA_A, evidence["releaseSha"])
        online = self.adapter.inventory(current_spec["environmentId"], current_spec["serviceId"], current_spec["namespace"])
        self.assertEqual([SHA_A], [item.record["releaseSha"] for item in online])
        self.remove(restored)

    def test_unsafe_secret_permissions_fail_before_pm2_start(self) -> None:
        spec, _, secrets = self.spec(SHA_A, mode=0o644)
        secret_value = json.loads(secrets.read_text())["TEST_SECRET"]
        with self.assertRaisesRegex(ProcessError, "permissions are unsafe") as raised:
            self.adapter.start_candidate(spec)
        self.assertNotIn(secret_value, str(raised.exception))
        self.assertEqual([], self.adapter._all_inventory())

    def test_secret_source_symlink_non_regular_and_wrong_owner_fail_before_pm2_mutation(self) -> None:
        spec, _, secrets = self.spec(SHA_A)
        secret_value = json.loads(secrets.read_text())["TEST_SECRET"]
        cases = []

        symlink = self.root / "secret-link.json"
        symlink.symlink_to(secrets)
        symlink_spec = copy.deepcopy(spec)
        symlink_spec["secretSource"]["sourcePath"] = str(symlink)
        cases.append(("symlink", self.adapter, symlink_spec, "regular file"))

        directory_spec = copy.deepcopy(spec)
        directory_spec["secretSource"]["sourcePath"] = str(self.root)
        cases.append(("non-regular", self.adapter, directory_spec, "regular file"))

        wrong_owner_adapter = self.restarted_adapter(spec, secret_owner_uid=os.geteuid() + 1)
        cases.append(("wrong-owner", wrong_owner_adapter, spec, "ownership or permissions"))

        for label, adapter, candidate, message in cases:
            with self.subTest(case=label):
                with self.assertRaisesRegex(ProcessError, message) as raised:
                    adapter.start_candidate(candidate)
                self.assertNotIn(secret_value, str(raised.exception))
                self.assertFalse((self.pm2_home / "pm2.pid").exists())

    def test_adapter_self_attests_versions_and_rejects_pm2_package_drift(self) -> None:
        self.assertEqual("0.1.0", self.adapter.version_evidence["adapterVersion"])
        self.assertEqual("7.0.4", self.adapter.version_evidence["pm2PackageVersion"])
        self.assertRegex(self.adapter.version_evidence["nodeRuntime"], r"^v\d+\.\d+\.\d+$")

        original = PM2ProcessAdapter.pinned_pm2_version
        PM2ProcessAdapter.pinned_pm2_version = "7.0.3"
        try:
            with self.assertRaisesRegex(ProcessError, "pinned adapter version"):
                self.restarted_adapter(self.spec(SHA_A)[0])
        finally:
            PM2ProcessAdapter.pinned_pm2_version = original
        self.assertFalse((self.pm2_home / "pm2.pid").exists())

    def test_legacy_restore_descriptor_probe_and_exact_restore(self) -> None:
        descriptor, _ = self.legacy_descriptor()
        authority = descriptor["observedAuthority"]
        recipe = descriptor["restoreRecipe"]
        evidence = self.adapter.preflight_legacy_restore(descriptor)
        self.assertEqual("pass", evidence["probe"])
        self.assertEqual([], self.adapter._all_inventory())
        observed = self.adapter._bridge({"action": "test-start", "app": {"name": authority["stableName"], "namespace": authority["namespace"], "script": authority["invocation"]["executable"], "args": authority["invocation"]["args"], "cwd": authority["invocation"]["cwd"], "env": {"RELEASE_MANAGER_LAUNCH_TOKEN": "legacy-observe-token"}}})["record"]
        authority.update({"adapterId": observed["adapterId"], "pid": observed["pid"], "processStartId": observed["evidence"]["processStartId"]})
        observation_tamper = copy.deepcopy(descriptor)
        observation_tamper["observedAuthority"]["pid"] += 1
        with self.assertRaisesRegex(ProcessError, "expected one exact process, found 0"):
            self.adapter.observe_legacy(observation_tamper)
        handle = self.adapter.observe_legacy(descriptor)
        wrong = copy.deepcopy(descriptor); wrong["observedAuthority"]["releaseSha"] = SHA_B
        restart_spec, _, _ = self.spec(SHA_B)
        with self.assertRaisesRegex(ProcessError, "exact external restore descriptor"):
            self.restarted_adapter(restart_spec, legacy_descriptor=wrong).resolve_persisted(handle.record)
        reobserved = self.restarted_adapter(restart_spec, legacy_descriptor=descriptor).resolve_persisted(handle.record)
        self.assertEqual(handle.record["identity"], reobserved.record["identity"])
        target = f"http://127.0.0.1:{authority['listener']['port']}/api/health"
        self.adapter.attest(handle, SHA_A, (target, target))
        self.remove(handle)
        restored = self.adapter.restore(handle)
        self.adapter.attest(restored, SHA_A, (target, target))
        self.assertEqual(SHA_A, restored.record["releaseSha"])
        self.assertEqual(str(Path(recipe["bootstrap"]["executable"]).resolve()), restored.record["runtime"]["executable"])
        self.remove(restored)

    def test_failed_legacy_restore_probe_is_removed_after_early_exit(self) -> None:
        descriptor, _ = self.legacy_descriptor(failing_bootstrap=True)
        descriptor["health"]["attempts"] = 2
        with self.assertRaisesRegex(ProcessError, "health attestation failed|live process identity mismatch"):
            self.adapter.preflight_legacy_restore(descriptor)
        self.assertEqual([], self.adapter._all_inventory())

    def test_legacy_restore_probe_injects_selected_host_and_non_business_port(self) -> None:
        descriptor, _ = self.legacy_descriptor()
        descriptor["observedAuthority"]["listener"]["host"] = "::1"
        descriptor["observedAuthority"]["invocation"]["args"][2] = "::1"
        descriptor["restoreRecipe"]["listener"]["host"] = "::1"
        self.assertEqual("127.0.0.1", descriptor["restoreRecipe"]["probe"]["host"])
        self.assertNotEqual(
            descriptor["restoreRecipe"]["listener"]["port"],
            descriptor["restoreRecipe"]["probe"]["port"],
        )
        evidence = self.adapter.preflight_legacy_restore(descriptor)
        self.assertEqual("pass", evidence["probe"])
        self.assertEqual([], self.adapter._all_inventory())

    def test_legacy_descriptor_tamper_source_and_unsafe_inputs_fail_before_mutation(self) -> None:
        descriptor, secrets = self.legacy_descriptor()
        original_digest = self.adapter._descriptor_digest(descriptor)
        observed_tamper = copy.deepcopy(descriptor)
        observed_tamper["observedAuthority"]["invocation"]["args"][-1] = str(free_port())
        self.assertNotEqual(original_digest, self.adapter._descriptor_digest(observed_tamper))
        with self.assertRaisesRegex(Exception, "typed listener mismatch"):
            self.adapter.preflight_legacy_restore(observed_tamper)
        source_tamper = copy.deepcopy(descriptor)
        source_tamper["restoreRecipe"]["source"]["releaseSha"] = SHA_B
        self.assertNotEqual(original_digest, self.adapter._descriptor_digest(source_tamper))
        with self.assertRaisesRegex(Exception, "must match observedAuthority"):
            self.adapter.preflight_legacy_restore(source_tamper)
        listener_tamper = copy.deepcopy(descriptor)
        business_port = descriptor["restoreRecipe"]["listener"]["port"]
        listener_tamper["restoreRecipe"]["listener"] = {
            **listener_tamper["restoreRecipe"]["listener"],
            "port": business_port + 1 if business_port < 65535 else business_port - 1,
        }
        self.assertNotEqual(original_digest, self.adapter._descriptor_digest(listener_tamper))
        with self.assertRaisesRegex(Exception, "must preserve the observed business listener"):
            self.adapter.preflight_legacy_restore(listener_tamper)
        argv_tamper = copy.deepcopy(descriptor)
        argv_tamper["restoreRecipe"]["payload"]["args"].append("--unsafe")
        with self.assertRaisesRegex(Exception, "only typed listener adaptation"):
            self.adapter.preflight_legacy_restore(argv_tamper)
        unsafe_wrapper = copy.deepcopy(descriptor)
        link = self.root / "unsafe-wrapper-link.cjs"
        link.symlink_to(Path(descriptor["restoreRecipe"]["bootstrap"]["executable"]))
        unsafe_wrapper["restoreRecipe"]["bootstrap"]["executable"] = str(link)
        with self.assertRaisesRegex(ProcessError, "cannot be a symlink"):
            self.adapter.preflight_legacy_restore(unsafe_wrapper)
        secrets.chmod(0o644)
        with self.assertRaisesRegex(ProcessError, "secret source ownership or permissions are unsafe"):
            self.adapter.preflight_legacy_restore(descriptor)
        self.assertEqual([], self.adapter._all_inventory())

    def test_shadow_proof_does_not_persist_pm2_state(self) -> None:
        descriptor, _ = self.legacy_descriptor()
        self.adapter.preflight_legacy_restore(descriptor)
        self.assertFalse((self.pm2_home / "dump.pm2").exists())
        self.assertEqual([], self.adapter._all_inventory())

    def test_runtime_source_overlap_fails_before_pm2_mutation(self) -> None:
        spec, _, _ = self.spec(SHA_A)
        spec["nonSecretValues"].append({"name": "TEST_SECRET", "value": "forbidden"})
        with self.assertRaisesRegex(ProcessError, "sources overlap"):
            self.adapter.start_candidate(spec)
        self.assertEqual([], self.adapter._all_inventory())


if __name__ == "__main__":
    unittest.main(verbosity=2)
