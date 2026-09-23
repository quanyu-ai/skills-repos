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
        self.adapter = PM2ProcessAdapter(
            pm2_home=self.pm2_home,
            node_modules=self.node_modules,
            instance_id=self.INSTANCE_ID,
            stable_name="env1b-c-service",
            secret_owner_uid=os.geteuid(),
            trusted_path=(str(Path(sys.executable).parent), "/usr/local/bin", "/usr/bin", "/bin"),
            health_attempts=30,
            health_interval_seconds=0.1,
        )
        self.created_handles = []

    def restarted_adapter(self, spec: dict, *, secret_owner_uid: int | None = None) -> PM2ProcessAdapter:
        return PM2ProcessAdapter(
            pm2_home=self.pm2_home,
            node_modules=self.node_modules,
            instance_id=self.INSTANCE_ID,
            stable_name="env1b-c-service",
            secret_owner_uid=os.geteuid() if secret_owner_uid is None else secret_owner_uid,
            trusted_path=(str(Path(sys.executable).parent), "/usr/local/bin", "/usr/bin", "/bin"),
            health_attempts=30,
            health_interval_seconds=0.1,
            runtime_policy=self.runtime_policy(spec),
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
            "allowedEnvNames": ["HOST", "PORT", "TEST_SECRET", "TEST_HEALTH_STATUS", "TEST_ENV_REPORT"],
            "requiredSecretNames": ["TEST_SECRET", "TEST_HEALTH_STATUS", "TEST_ENV_REPORT"],
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
            "secretSource": copy.deepcopy(spec["secretSource"]),
            "binding": copy.deepcopy(spec["binding"]),
            "listener": copy.deepcopy(spec["listener"]),
            "health": copy.deepcopy(spec["health"]),
        }

    def start(self, spec: dict):
        handle = self.adapter.start_candidate(spec)
        self.created_handles.append(handle)
        return handle

    def remove(self, handle) -> None:
        self.adapter.stop_exact(handle)
        self.adapter.delete_exact(handle)
        self.adapter.await_absent(handle)

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
        self.assertEqual({"hasNodeChannelFd": False, "hasNodeUniqueId": False, "hasAmbientPoison": False}, report_data)
        self.remove(handle)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
