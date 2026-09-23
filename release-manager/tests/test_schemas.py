#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_validator", ROOT / "scripts" / "validate.py")
validator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(validator)


class SchemaHarnessTest(unittest.TestCase):
    def load_valid(self, name: str) -> dict:
        return json.loads((ROOT / "fixtures" / "valid" / name).read_text())

    def test_valid_fixtures(self) -> None:
        for path in sorted((ROOT / "fixtures" / "valid").glob("*.json")):
            with self.subTest(path=path.name):
                validator.validate_file(path)

    def test_invalid_fixtures_fail_closed(self) -> None:
        expected = {
            "policy-health-path-override.json",
            "release-unknown-field.json",
            "release-arbitrary-install.json",
            "release-unsafe-path.json",
            "release-interpolated-shell.json",
            "release-invalid-migration.json",
            "release-non-frozen-install.json",
            "policy-secret-value.json",
            "process-handle-name-only.json",
            "process-handle-incomplete-provenance.json",
            "state-record-failed-candidate-previous.json",
            "state-record-previous-identity-mismatch.json",
            "transition-illegal.json",
        }
        found = {path.name for path in (ROOT / "fixtures" / "invalid").glob("*.json")}
        self.assertEqual(expected, found)
        for path in sorted((ROOT / "fixtures" / "invalid").glob("*.json")):
            with self.subTest(path=path.name):
                with self.assertRaises((validator.ValidationError, KeyError)):
                    validator.validate_file(path)

    def test_failed_candidate_cannot_become_current(self) -> None:
        data = self.load_valid("state-record.json")
        data["attempt"]["outcome"] = "failed"
        data["attempt"]["phase"] = "failed"
        with self.assertRaisesRegex(validator.ValidationError, "failed target"):
            validator.validate_document(data)

    def test_process_handle_sha_must_match_state(self) -> None:
        data = self.load_valid("state-record.json")
        data["current"]["handle"]["releaseSha"] = "f" * 40
        with self.assertRaisesRegex(validator.ValidationError, "ProcessHandle SHA mismatch"):
            validator.validate_document(data)

    def test_migration_command_is_never_a_release_action(self) -> None:
        data = self.load_valid("release-contract.json")
        data["lifecycle"]["build"] = {"packageScript": "db:migrate"}
        data["migration"]["mode"] = "approval-gated"
        with self.assertRaisesRegex(validator.ValidationError, "database mutation"):
            validator.validate_document(data)

    def test_unknown_nested_field_fails_closed(self) -> None:
        data = self.load_valid("release-contract.json")
        data["runtime"]["typoedPort"] = 3104
        with self.assertRaisesRegex(validator.ValidationError, "unknown fields"):
            validator.validate_document(data)

    def test_unsafe_absolute_repository_path_is_rejected(self) -> None:
        data = self.load_valid("release-contract.json")
        data["artifact"]["appRoot"] = "/tmp/build"
        with self.assertRaisesRegex(validator.ValidationError, "pattern mismatch"):
            validator.validate_document(data)

    def test_interpolated_shell_argument_is_rejected(self) -> None:
        data = self.load_valid("release-contract.json")
        data["lifecycle"]["build"] = {"argv": ["sh", "-c", "echo ${TOKEN}"]}
        with self.assertRaisesRegex(validator.ValidationError, "schema match"):
            validator.validate_document(data)

    def test_install_is_typed_and_frozen(self) -> None:
        data = self.load_valid("release-contract.json")
        self.assertEqual(
            {"operation": "package-manager-frozen-install"},
            data["toolchain"]["install"],
        )
        for invalid in ("release-arbitrary-install.json", "release-non-frozen-install.json"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(validator.ValidationError):
                    validator.validate_file(ROOT / "fixtures" / "invalid" / invalid)

    def test_secret_values_have_no_policy_extension_point(self) -> None:
        data = self.load_valid("environment-policy.json")
        data["secrets"]["values"] = {"DATABASE_URL": "must-not-be-accepted"}
        with self.assertRaisesRegex(validator.ValidationError, "unknown fields"):
            validator.validate_document(data)

    def test_process_handle_cannot_be_name_only(self) -> None:
        path = ROOT / "fixtures" / "invalid" / "process-handle-name-only.json"
        with self.assertRaisesRegex(validator.ValidationError, "missing required"):
            validator.validate_file(path)

    def test_canonical_previous_is_distinct_and_restorable(self) -> None:
        data = self.load_valid("state-record-current-previous.json")
        validator.validate_document(data)
        self.assertTrue(data["previous"]["restorable"])
        self.assertLess(data["previous"]["generation"], data["current"]["generation"])
        self.assertNotEqual(data["previous"]["releaseSha"], data["current"]["releaseSha"])

    def test_first_adoption_uses_legacy_without_canonical_previous(self) -> None:
        data = self.load_valid("state-record-first-adoption.json")
        validator.validate_document(data)
        self.assertIn("legacy", data)
        self.assertNotIn("current", data)
        self.assertNotIn("previous", data)
        self.assertEqual("observed", data["legacy"]["handle"]["provenance"]["origin"])

    def test_previous_cannot_share_current_generation(self) -> None:
        data = self.load_valid("state-record-current-previous.json")
        data["previous"]["generation"] = data["current"]["generation"]
        with self.assertRaisesRegex(validator.ValidationError, "generation must precede"):
            validator.validate_document(data)

    def test_health_targets_have_split_ownership(self) -> None:
        contract = self.load_valid("release-contract.json")
        policy = self.load_valid("environment-policy.json")
        self.assertEqual(
            ("http://127.0.0.1:3104/api/health", "https://demo.example.invalid/api/health"),
            validator.compose_health_targets(contract, policy),
        )
        contract["health"]["path"] = "https://attacker.invalid/health"
        with self.assertRaises(validator.ValidationError):
            validator.validate_document(contract)

    def test_policy_cannot_override_health_path(self) -> None:
        with self.assertRaisesRegex(validator.ValidationError, "unknown fields"):
            validator.validate_file(ROOT / "fixtures" / "invalid" / "policy-health-path-override.json")

    def test_adapter_interface_has_no_state_commit_method(self) -> None:
        declarations = (ROOT / "spec" / "process-adapter.d.ts").read_text()
        adapter = declarations.split("export interface ProcessAdapter", 1)[1].split("}", 1)[0]
        self.assertNotIn("commit", adapter.lower())
        self.assertIn("commitAttestedState", declarations)

    def test_state_machine_catalog_has_required_invariants(self) -> None:
        spec = json.loads((ROOT / "spec" / "state-machines.json").read_text())
        required = {
            "engine-alone-writes-state-store",
            "adapter-never-commits-release-state",
            "process-handle-originates-from-adapter-observe-or-start",
            "failed-candidate-never-current-previous-or-persisted-authority",
            "unknown-process-inventory-fails-closed",
        }
        self.assertTrue(required.issubset(set(spec["invariants"])))
        self.assertEqual({"build", "legacy-adoption", "activation", "rollback"}, set(spec["machines"]))
        for name in ("legacy-adoption", "activation", "rollback"):
            persisted_sources = {
                source
                for source, event, target in spec["machines"][name]["transitions"]
                if event == "ADAPTER_PERSISTED" and target in spec["machines"][name]["terminal"]
            }
            self.assertTrue(persisted_sources)
            self.assertNotIn("CANDIDATE_STARTED", persisted_sources)

    def test_acceptance_catalog_is_unique_and_traceable(self) -> None:
        catalog = json.loads((ROOT / "spec" / "acceptance-tests.json").read_text())
        tests = catalog["tests"]
        ids = [item["id"] for item in tests]
        incidents = [item["incident"] for item in tests]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(incidents), len(set(incidents)))
        self.assertGreaterEqual(len(tests), 20)
        for item in tests:
            self.assertTrue(item["assertion"])
            self.assertRegex(item["phase"], r"^ENV-1b-[a-f]$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
