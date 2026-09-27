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
        validator.chmod(0o700)
        (self.install_root / "schemas").mkdir(mode=0o700)
        for name in ("preflight-error.schema.json", "preflight-status.schema.json"):
            target = self.install_root / "schemas" / name
            shutil.copy2(ROOT / "schemas" / name, target)
            target.chmod(0o600)
        self.registry = root / "registry.json"
        self.manifest = root / "manifest.json"
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
            "operatorSha": self.OPERATOR_SHA, "allowDeploy": False,
            "operatorManifest": str(self.manifest),
            "installRoot": str(self.install_root),
            "commands": {"preflight": [str(self.operator), "preflight-status"],
                         "attest": [str(self.operator), "preflight-status"],
                         "deploy": [str(self.operator), "deploy"]}}]}))
        self.registry.chmod(0o600)

    def tearDown(self):
        self.temp.cleanup()

    def request(self, **overrides):
        value = {"environment": "demo", "application": "smart-college", "sha": self.SHA, "mode": "preflight"}
        value.update(overrides)
        return json.dumps(value).encode()

    def invoke(self, raw):
        return gateway.invoke(raw, self.registry, trusted_owner_uid=os.geteuid())

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


if __name__ == "__main__":
    unittest.main()
