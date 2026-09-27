#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_manager_cli", ROOT / "scripts/release_manager.py")
cli = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(cli)


class OperatorCliTest(unittest.TestCase):
    def test_deploy_subcommand_calls_only_canonical_writer(self) -> None:
        output = io.StringIO()
        sha = "a" * 40
        result = {"schemaVersion": "quanyu.ai/release-manager-deploy-result/v1", "decision": "DEPLOYED",
                  "attemptId": "attempt-1", "releaseSha": sha, "artifactDigest": "sha256:" + "b" * 64,
                  "stateGeneration": 9, "transitionDigest": "sha256:" + "c" * 64}
        argv = ["release-manager", "deploy", "--environment-id", "demo", "--service-id", "smart-college",
                "--expected-repository", "owner/repo", "--expected-candidate-sha", sha]
        with patch.object(sys, "argv", argv), patch.object(cli, "_deploy", return_value=result) as deploy, redirect_stdout(output):
            self.assertEqual(0, cli.main())
        deploy.assert_called_once_with("demo", "smart-college", "owner/repo", sha)
        self.assertEqual(result, json.loads(output.getvalue()))

    def test_deploy_exception_is_schema_valid_redacted_failure(self) -> None:
        output = io.StringIO()
        sha = "a" * 40
        argv = ["release-manager", "deploy", "--environment-id", "demo", "--service-id", "smart-college",
                "--expected-repository", "owner/repo", "--expected-candidate-sha", sha]
        with patch.object(sys, "argv", argv), patch.object(cli, "_deploy", side_effect=RuntimeError("secret")), redirect_stdout(output):
            self.assertEqual(2, cli.main())
        value = json.loads(output.getvalue())
        self.assertEqual("FAIL_CLOSED", value["decision"])
        self.assertEqual(sha, value["releaseSha"])
        self.assertNotIn("secret", output.getvalue())

    def test_any_runtime_exception_is_one_redacted_fail_closed_record(self) -> None:
        output = io.StringIO()
        argv = ["release-manager", "preflight-status", "--environment-id", "demo", "--service-id", "smart-college", "--expected-repository", "quanyu-ai/proj-code-smart-college"]
        with patch.object(sys, "argv", argv), patch.object(cli, "_load_operator", side_effect=RuntimeError("postgresql://user:secret@example/db")), redirect_stdout(output):
            self.assertEqual(2, cli.main())
        self.assertEqual({"schemaVersion": "quanyu.ai/release-manager-preflight-error/v1", "decision": "FAIL_CLOSED", "code": "PREFLIGHT_AUTHORITY_UNPROVEN"}, json.loads(output.getvalue()))
        self.assertNotIn("secret", output.getvalue())

    def test_inventory_uses_pm2_no_daemon_mode_and_re_attests_connected_daemon(self) -> None:
        bridge = (ROOT / "pm2-adapter/bridge.cjs").read_text()
        self.assertIn('await connect(request.action === "inventory")', bridge)
        self.assertIn('return { records: await inventory(), daemon: daemonAttestation() }', bridge)


if __name__ == "__main__":
    unittest.main()
