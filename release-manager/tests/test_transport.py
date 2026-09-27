from __future__ import annotations

import json
import hashlib
import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / "transport"))
import client
import gateway


class TransportTest(unittest.TestCase):
    SHA = "a" * 40
    OPERATOR_SHA = "1" * 40

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name).resolve()
        self.install_root = root / "install"
        self.install_root.mkdir(mode=0o700)
        self.operator = self.install_root / "operator"
        self.operator.write_text("#!/bin/sh\n")
        self.operator.chmod(0o700)
        (self.install_root / "scripts").mkdir(mode=0o700)
        validator = self.install_root / "scripts" / "validate.py"
        shutil.copy2(ROOT / "scripts" / "validate.py", validator)
        validator.chmod(0o600)
        (self.install_root / "schemas").mkdir(mode=0o700)
        for name in ("preflight-error.schema.json", "preflight-status.schema.json",
                     "deploy-result.schema.json",
                     "source-publication-error.schema.json", "source-publication-receipt.schema.json"):
            target = self.install_root / "schemas" / name
            shutil.copy2(ROOT / "schemas" / name, target)
            target.chmod(0o600)
        self.registry = root / "registry.json"
        self.manifest = root / "manifest.json"
        self.state = root / "state.json"
        self.consumption = root / "deploy-consumption.json"
        self.consumption_lock = root / "deploy-consumption.lock"
        digest = hashlib.sha256(self.operator.read_bytes()).hexdigest()
        tree_digest = gateway._tree_digest(self.install_root, os.geteuid())
        self.manifest.write_text(json.dumps({"schemaVersion": "quanyu.ai/release-manager-install/v1",
            "sourceSha": self.OPERATOR_SHA,
            "installTreeDigest": f"sha256:{tree_digest}",
            "gatewayDigest": "sha256:" + "5" * 64,
            "commandDigests": {mode: f"sha256:{digest}" for mode in gateway.MODES},
            "deployAuthority": "release-manager/engine/core.py:ReleaseEngine"}))
        self.manifest.chmod(0o600)
        self.registry.write_text(json.dumps({"schemaVersion": "quanyu.ai/release-transport-registry/v1", "bindings": [{
            "environment": "demo", "application": "smart-college", "repository": "quanyu-ai/proj-code-smart-college",
            "operatorSha": self.OPERATOR_SHA, "deployAuthority": None,
            "operatorManifest": str(self.manifest),
            "installRoot": str(self.install_root),
            "commands": {"preflight": [str(self.operator), "preflight-status"],
                         "attest": [str(self.operator), "preflight-status"],
                         "deploy": [str(self.operator), "deploy"],
                         "source-publication": [str(self.operator), "source-publication"]}}]}))
        self.registry.chmod(0o600)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, **overrides):
        value = {"environment": "demo", "application": "smart-college", "sha": self.SHA, "mode": "preflight"}
        value.update(overrides)
        return json.dumps(value).encode()

    def invoke(self, raw):
        return gateway.invoke(raw, self.registry, trusted_owner_uid=os.geteuid())

    def authority(self, binding, sha=None):
        return {"schemaVersion": "quanyu.ai/exact-deploy-authority/v1",
                "approvalId": "owner:DEMO-401-G3:06c5d26c", "environment": binding["environment"],
                "application": binding["application"], "repository": binding["repository"],
                "sha": sha or self.SHA, "issuedStateGeneration": 7, "stateFile": str(self.state),
                "consumptionFile": str(self.consumption),
                "consumptionLockFile": str(self.consumption_lock)}

    def test_unknown_environment_application_and_short_sha_fail(self):
        for raw in (self.request(environment="prod"), self.request(application="other"), self.request(sha="abc")):
            with self.assertRaises(gateway.GatewayError):
                self.invoke(raw)

    def test_authority_override_fields_fail(self):
        for name in ("policyFile", "stateFile", "pm2Home", "secretSource", "uid"):
            value = json.loads(self.request())
            value[name] = "/tmp/override"
            with self.assertRaises(gateway.GatewayError):
                self.invoke(json.dumps(value).encode())

    def test_unsafe_registry_mode_and_symlink_fail(self):
        self.registry.chmod(0o622)
        with self.assertRaises(gateway.GatewayError):
            self.invoke(self.request())
        self.registry.chmod(0o600)
        link = self.registry.with_name("link")
        link.symlink_to(self.registry)
        with self.assertRaises(gateway.GatewayError):
            gateway.invoke(self.request(), link, trusted_owner_uid=os.geteuid())

    def test_deploy_cannot_run_when_host_registry_disables_it(self):
        with patch("gateway.subprocess.run") as run:
            with self.assertRaises(gateway.GatewayError):
                self.invoke(self.request(mode="deploy"))
            run.assert_not_called()
        with patch("gateway.subprocess.run") as run:
            with self.assertRaises(gateway.GatewayError):
                self.invoke(self.request(mode="deploy", sha="b" * 40))
            run.assert_not_called()

    def test_failed_pre_mutation_deploy_preserves_unconsumed_authority(self):
        document = json.loads(self.registry.read_text())
        binding = document["bindings"][0]
        binding["deployAuthority"] = self.authority(binding)
        self.registry.write_text(json.dumps(document))
        failed = type("R", (), {"stdout": json.dumps({
            "schemaVersion": "quanyu.ai/release-manager-deploy-result/v1", "decision": "FAIL_CLOSED",
            "attemptId": "fail-closed", "releaseSha": self.SHA, "artifactDigest": "sha256:" + "0" * 64,
            "stateGeneration": 1, "transitionDigest": "sha256:" + "1" * 64,
        }).encode(), "returncode": 2})()
        with patch("gateway.subprocess.run", return_value=failed):
            result = self.invoke(self.request(mode="deploy"))
        self.assertEqual(2, result["exitCode"])
        self.assertFalse(self.consumption.exists())

    def test_post_commit_retry_consumes_without_operator_reexecution(self):
        document = json.loads(self.registry.read_text())
        binding = document["bindings"][0]
        binding["deployAuthority"] = self.authority(binding)
        self.registry.write_text(json.dumps(document))
        attempt = {"attemptId": "attempt-recovered", "targetSha": self.SHA,
                   "phase": "complete", "outcome": "succeeded"}
        self.state.write_text(json.dumps({"generation": 9, "status": "managed", "attempt": attempt,
            "current": {"releaseSha": self.SHA, "artifactDigest": "sha256:" + "2" * 64}}))
        self.state.chmod(0o600)
        with patch("gateway.subprocess.run") as run:
            result = self.invoke(self.request(mode="deploy"))
        run.assert_not_called()
        self.assertEqual("DEPLOYED", result["result"]["decision"])
        self.assertEqual(9, result["result"]["stateGeneration"])
        self.assertTrue(self.consumption.is_file())

    def test_deploy_authority_is_exactly_bound_and_reaches_only_canonical_writer(self):
        document = json.loads(self.registry.read_text())
        binding = document["bindings"][0]
        binding["deployAuthority"] = self.authority(binding)
        self.registry.write_text(json.dumps(document))
        deployed = type("R", (), {"stdout": json.dumps({
            "schemaVersion": "quanyu.ai/release-manager-deploy-result/v1",
            "decision": "DEPLOYED", "attemptId": "attempt-1", "releaseSha": self.SHA,
            "artifactDigest": "sha256:" + "2" * 64, "stateGeneration": 8,
            "transitionDigest": "sha256:" + "3" * 64,
        }).encode(), "returncode": 0})()
        with patch("gateway.subprocess.run", return_value=deployed) as run:
            result = self.invoke(self.request(mode="deploy"))
        self.assertEqual("deploy", result["mode"])
        argv = run.call_args.args[0]
        self.assertEqual("deploy", argv[1])
        self.assertIn(self.SHA, argv)
        self.assertTrue(self.consumption.is_file())

        with patch("gateway.subprocess.run") as run:
            with self.assertRaises(gateway.GatewayError):
                self.invoke(self.request(mode="deploy"))
            run.assert_not_called()

    def test_generic_or_caller_controlled_deploy_authority_fails_closed(self):
        document = json.loads(self.registry.read_text())
        binding = document["bindings"][0]
        widened = self.authority(binding, "b" * 40)
        widened["allowAnySha"] = True
        for authority in (True, {"sha": self.SHA}, widened):
            binding["deployAuthority"] = authority
            self.registry.write_text(json.dumps(document))
            with patch("gateway.subprocess.run") as run, self.assertRaises(gateway.GatewayError):
                self.invoke(self.request(mode="deploy"))
            run.assert_not_called()

    def test_canonical_operator_is_executable_and_uses_pinned_host_python(self):
        operator = ROOT / "scripts" / "release_manager.py"
        self.assertTrue(operator.stat().st_mode & stat.S_IXUSR)
        self.assertEqual("#!/opt/quanyu/release-manager/runtime/python3.12",
                         operator.read_text().splitlines()[0])

    def test_repeated_read_only_calls_are_reproducible_and_audited(self):
        result = type("R", (), {"stdout": b'{"schemaVersion":"quanyu.ai/release-manager-preflight-error/v1","decision":"FAIL_CLOSED","code":"TEST"}', "returncode": 0})()
        with patch("gateway.subprocess.run", return_value=result):
            one = self.invoke(self.request())
            two = self.invoke(self.request())
        self.assertEqual(one, two)
        self.assertRegex(one["requestDigest"], r"^sha256:[0-9a-f]{64}$")
        self.assertNotIn("secret", json.dumps(one).lower())

    def test_ambient_environment_is_not_forwarded_and_sensitive_output_fails(self):
        clean = type("R", (), {"stdout": b'{"schemaVersion":"quanyu.ai/release-manager-preflight-error/v1","decision":"FAIL_CLOSED","code":"TEST"}', "returncode": 0})()
        with patch("gateway.subprocess.run", return_value=clean) as run:
            self.invoke(self.request())
        self.assertEqual({"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8",
                          "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": ""},
                         run.call_args.kwargs["env"])
        leaked = type("R", (), {"stdout": b'{"password":"do-not-emit"}', "returncode": 0})()
        with patch("gateway.subprocess.run", return_value=leaked), self.assertRaises(gateway.GatewayError):
            self.invoke(self.request())

    def test_client_disables_shell_tty_and_forwarding_and_checks_modes(self):
        root = Path(self.temp.name)
        identity, hosts = root / "identity", root / "known_hosts"
        identity.write_text("not-a-real-key")
        hosts.write_text("not-a-real-host-key")
        identity.chmod(0o600); hosts.chmod(0o600)
        argv = client.ssh_argv(identity, hosts)
        self.assertIn("ClearAllForwardings=yes", argv)
        self.assertIn("RequestTTY=no", argv)
        self.assertIn("StrictHostKeyChecking=yes", argv)
        self.assertEqual("/usr/bin/ssh", argv[0])
        self.assertIn("/dev/null", argv)
        self.assertIn("ProxyCommand=none", argv)
        identity.chmod(0o644)
        with self.assertRaises(RuntimeError):
            client.ssh_argv(identity, hosts)

    def test_client_rejects_mismatched_host_transport_evidence(self):
        root = Path(self.temp.name).resolve()
        identity, hosts = root / "identity", root / "known_hosts"
        identity.write_text("not-a-real-key"); hosts.write_text("not-a-real-host-key")
        identity.chmod(0o600); hosts.chmod(0o600)
        request = {"environment": "demo", "application": "smart-college", "sha": self.SHA, "mode": "preflight"}
        authority = root / "authority.json"
        authority.write_text(json.dumps({"schemaVersion": "quanyu.ai/managed-release-client-authority/v1",
            "canonicalSha": self.OPERATOR_SHA, "installTreeDigest": "sha256:" + "2" * 64,
            "gatewayDigest": "sha256:" + "3" * 64, "operatorEntrypointDigest": "sha256:" + "4" * 64}))
        authority.chmod(0o600)
        bad = type("R", (), {"stdout": json.dumps({"schemaVersion": "quanyu.ai/managed-release-transport-evidence/v1",
            "requestDigest": "sha256:" + "0" * 64, "operatorSha": self.OPERATOR_SHA, "mode": "preflight",
            "exitCode": 0, "result": {}}).encode(), "returncode": 0})()
        with patch("client.ssh_argv", return_value=["/usr/bin/ssh"]), patch("client.subprocess.run", return_value=bad), self.assertRaises(RuntimeError):
            client.invoke(request, authority)

    def test_client_authority_rejects_pre_transport_sha_and_non_hex_digest(self):
        root = Path(self.temp.name).resolve()
        authority = root / "authority.json"
        value = {"schemaVersion": "quanyu.ai/managed-release-client-authority/v1",
                 "canonicalSha": client.PRE_TRANSPORT_SHA, "installTreeDigest": "sha256:" + "2" * 64,
                 "gatewayDigest": "sha256:" + "3" * 64, "operatorEntrypointDigest": "sha256:" + "4" * 64}
        authority.write_text(json.dumps(value)); authority.chmod(0o600)
        with self.assertRaises(RuntimeError):
            client._authority(authority)
        value["canonicalSha"] = self.OPERATOR_SHA
        value["gatewayDigest"] = "sha256:" + "z" * 64
        authority.write_text(json.dumps(value))
        with self.assertRaises(RuntimeError):
            client._authority(authority)


if __name__ == "__main__":
    unittest.main()
