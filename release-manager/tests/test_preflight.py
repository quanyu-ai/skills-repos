#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
import importlib.util
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine.contracts import canonical_document_digest  # noqa: E402
from engine.fake_adapter import FakeProcessAdapter, FakeProcessRuntime  # noqa: E402
from engine.preflight import OperatorBinding, PreflightError, PreflightStatusOperator, _digest  # noqa: E402

VALIDATOR_SPEC = importlib.util.spec_from_file_location("release_validator", ROOT / "scripts/validate.py")
validator = importlib.util.module_from_spec(VALIDATOR_SPEC)
assert VALIDATOR_SPEC.loader
VALIDATOR_SPEC.loader.exec_module(validator)


NOW = datetime(2026, 9, 26, 14, 0, tzinfo=timezone.utc)
SHA_A = "a" * 40
SHA_B = "b" * 40


class PreflightHarness(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.policy = json.loads((ROOT / "fixtures/valid/environment-policy.json").read_text())
        self.contract = json.loads((ROOT / "fixtures/valid/release-contract.json").read_text())
        self.policy["metadata"].update({"environmentId": "demo", "serviceId": "smart-college", "application": "smart-college"})
        self.contract["metadata"]["application"] = "smart-college"
        self.policy["storage"] = {"releaseRoot": str(self.root / "releases"), "stateRoot": str(self.root / "state"), "lockFile": str(self.root / "state/operator.lock")}
        self.policy["process"].update({"namespace": "smart-demo", "stableName": "smart-college"})
        self.policy_file = self.root / "policy.json"
        self.contract_file = self.root / "contract.json"
        self.state_file = self.root / "state/state.json"
        self.lock_file = self.root / "state/operator.lock"
        self.mirror = self.root / "mirror"
        self.lock_file.parent.mkdir()
        self.lock_file.write_text("")
        self.policy_file.write_text(json.dumps(self.policy))
        self.contract_file.write_text(json.dumps(self.contract))
        subprocess.run(["git", "init", "-q", str(self.mirror)], check=True)
        subprocess.run(["git", "-C", str(self.mirror), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.mirror), "config", "user.name", "Fixture"], check=True)
        (self.mirror / "README").write_text("fixture\n")
        subprocess.run(["git", "-C", str(self.mirror), "add", "README"], check=True)
        subprocess.run(["git", "-C", str(self.mirror), "commit", "-qm", "fixture"], check=True)
        self.candidate = subprocess.check_output(["git", "-C", str(self.mirror), "rev-parse", "HEAD"], text=True).strip()
        self.runtime = FakeProcessRuntime()
        self.adapter = FakeProcessAdapter(self.runtime)
        digests = self.configuration_digests()
        previous_handle = self.make_handle(SHA_B, digests)
        self.runtime.records[previous_handle["identity"]["adapterId"]]["status"] = "stopped"
        current_handle = self.make_handle(SHA_A, digests)
        self.state = self.make_state(current_handle, previous_handle)
        self.write_state()
        binding = OperatorBinding("demo", "smart-college", "quanyu-ai/proj-code-smart-college", self.policy_file, self.contract_file, self.state_file, self.lock_file, self.mirror, max_state_age_seconds=3600, trusted_owner_uids=(os.getuid(),))
        self.operator = PreflightStatusOperator(binding, self.adapter, now=lambda: NOW)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def configuration_digests(self) -> dict[str, str]:
        return {"releaseContract": canonical_document_digest(self.contract), "environmentPolicy": canonical_document_digest(self.policy), "build": _digest(self.policy["build"]), "runtime": _digest({"runtime": self.policy["runtime"], "network": self.policy["network"], "secrets": self.policy["secrets"]})}

    def make_handle(self, sha: str, digests: dict[str, str]) -> dict:
        release = (self.root / "releases" / sha).resolve()
        executable = release / self.contract["runtime"]["executable"]
        cwd = release / self.contract["runtime"]["cwd"]
        artifact = release / self.contract["artifact"]["required"][0]
        executable.parent.mkdir(parents=True, exist_ok=True)
        cwd.mkdir(parents=True, exist_ok=True)
        artifact.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("fixture executable\n")
        artifact.write_text("fixture artifact\n")
        spec = {"environmentId": "demo", "serviceId": "smart-college", "namespace": "smart-demo", "stableName": "smart-college", "releaseSha": sha, "releasePath": str(release), "runtime": {"executable": str(executable), "args": self.contract["runtime"]["args"], "cwd": str(cwd)}, "observedAt": "2026-09-26T13:59:00Z", "listener": {"host": "127.0.0.1", "port": 3271}, "configurationDigests": digests}
        return self.adapter._new_handle(spec, "started").record

    def authority(self, generation: int, sha: str, handle: dict) -> dict:
        release = (self.root / "releases" / sha).resolve()
        from engine.preflight import _artifact_digest
        return {"generation": generation, "releaseSha": sha, "releasePath": str(release), "restorable": True, "artifactDigest": _artifact_digest(release, self.contract), "handle": copy.deepcopy(handle), "attestation": {"attestedAt": "2026-09-26T13:59:30Z", "sourceSha": sha, "runtimeSha": sha, "internalHealth": "pass", "publicHealth": "pass", "evidenceDigest": "sha256:" + "e" * 64}}

    def make_state(self, current: dict, previous: dict) -> dict:
        digests = self.configuration_digests()
        return {"apiVersion": "quanyu.ai/state-record/v1alpha1", "kind": "ReleaseState", "environmentId": "demo", "serviceId": "smart-college", "generation": 7, "updatedAt": "2026-09-26T13:59:30Z", "status": "managed", "releaseContractDigest": digests["releaseContract"], "environmentPolicyDigest": digests["environmentPolicy"], "current": self.authority(7, SHA_A, current), "previous": self.authority(6, SHA_B, previous), "attempt": {"attemptId": "123e4567-e89b-42d3-a456-426614174002", "sequence": 7, "targetSha": SHA_A, "releaseContractDigest": digests["releaseContract"], "environmentPolicyDigest": digests["environmentPolicy"], "phase": "complete", "outcome": "succeeded", "events": [{"sequence": 1, "at": "2026-09-26T13:59:30Z", "type": "RUNTIME_ATTESTED", "evidenceDigest": "sha256:" + "e" * 64}]}}

    def write_state(self) -> None:
        self.state_file.write_text(json.dumps(self.state))

    def observe(self, candidate: str | None = None) -> dict:
        return self.operator.observe("demo", "smart-college", "quanyu-ai/proj-code-smart-college", candidate)

    def test_current_previous_and_optional_candidate(self) -> None:
        without = self.observe()
        with_candidate = self.observe(self.candidate)
        self.assertEqual(SHA_A, without["current"]["releaseSha"])
        self.assertEqual(SHA_B, without["previous"]["releaseSha"])
        self.assertEqual({"provided": False, "sha": None, "reachable": None}, without["candidate"])
        self.assertTrue(with_candidate["candidate"]["reachable"])
        schema = json.loads((ROOT / "schemas/preflight-status.schema.json").read_text())
        validator.validate_schema(without, schema)
        validator.validate_schema(with_candidate, schema)

    def test_stale_and_tampered_state_fail_closed(self) -> None:
        for mutate, message in ((lambda s: s.__setitem__("updatedAt", "2026-09-20T00:00:00Z"), "stale"), (lambda s: s.__setitem__("environmentPolicyDigest", "sha256:" + "0" * 64), "digest")):
            with self.subTest(message=message):
                original = copy.deepcopy(self.state)
                mutate(self.state); self.write_state()
                with self.assertRaises(PreflightError): self.observe()
                self.state = original; self.write_state()

    def test_contract_and_policy_digest_mismatch(self) -> None:
        self.policy["health"]["attempts"] += 1
        self.policy_file.write_text(json.dumps(self.policy))
        with self.assertRaisesRegex(PreflightError, "digest mismatch"): self.observe()

    def test_live_identity_and_multiple_process_fail_closed(self) -> None:
        current_id = self.state["current"]["handle"]["identity"]["adapterId"]
        self.runtime.records[current_id]["record"]["identity"]["pid"] += 1
        with self.assertRaises(PreflightError): self.observe()
        self.runtime.records[current_id]["record"] = copy.deepcopy(self.state["current"]["handle"])
        self.runtime.ambiguous_inventory = True
        with self.assertRaises(PreflightError): self.observe()

    def test_unrecoverable_authorities_and_unreachable_candidate(self) -> None:
        self.state["previous"]["restorable"] = False; self.write_state()
        with self.assertRaises(PreflightError): self.observe()
        self.state["previous"]["restorable"] = True; self.write_state()
        with self.assertRaisesRegex(PreflightError, "unreachable"): self.observe("f" * 40)

    def test_tampered_artifact_fails_closed(self) -> None:
        artifact = (self.root / "releases" / SHA_A / self.contract["artifact"]["required"][0]).resolve()
        artifact.write_text("tampered\n")
        with self.assertRaisesRegex(PreflightError, "artifact attribution"): self.observe()

    def test_incomplete_health_evidence_fails_closed(self) -> None:
        self.adapter.observe_preflight = lambda *_args: {"result": "pass"}
        with self.assertRaisesRegex(PreflightError, "health attestation"): self.observe()

    def test_secret_redaction_and_repeated_calls_have_no_external_side_effect(self) -> None:
        secret = "postgresql://user:password@example/db"
        secret_file = self.root / "secret.json"; secret_file.write_text(json.dumps({"DATABASE_URL": secret}))
        before = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in (self.policy_file, self.contract_file, self.state_file, self.lock_file, secret_file)}
        first = self.observe(); second = self.observe()
        after = {p: (p.stat().st_mtime_ns, p.read_bytes()) for p in before}
        self.assertEqual(before, after)
        self.assertNotIn(secret, json.dumps(first) + json.dumps(second))
        self.assertNotIn("events", first)

    def test_wrong_repository_and_bad_sha_are_rejected_without_io(self) -> None:
        with self.assertRaises(PreflightError): self.operator.observe("demo", "smart-college", "evil/repository")
        with self.assertRaises(PreflightError): self.observe("HEAD")


if __name__ == "__main__":
    unittest.main()
