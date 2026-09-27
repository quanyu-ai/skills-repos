from __future__ import annotations

import json
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from engine import source_publication as publication
from engine.source_publication import SourcePublicationBinding, SourcePublicationError

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_SPEC = importlib.util.spec_from_file_location("source_publication_validator", ROOT / "scripts/validate.py")
validator = importlib.util.module_from_spec(VALIDATOR_SPEC)
assert VALIDATOR_SPEC.loader
VALIDATOR_SPEC.loader.exec_module(validator)


class SourcePublicationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.mirror = self.root / "mirror"
        (self.mirror / "objects").mkdir(parents=True)
        self.state = self.root / "state.json"
        self.lock = self.root / "operator.lock"
        self.identity = self.root / "identity"
        self.known_hosts = self.root / "known_hosts"
        self.state.write_text('{"generation":7}\n')
        self.lock.write_text("")
        self.identity.write_text("fixture-private-key\n"); self.identity.chmod(0o400)
        self.known_hosts.write_text("github.com fixture-host-key\n"); self.known_hosts.chmod(0o444)
        self.binding = SourcePublicationBinding(publication.ENVIRONMENT, publication.APPLICATION,
            publication.REPOSITORY, self.mirror, self.state, self.lock, (os.geteuid(),),
            self.identity, self.known_hosts)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_rejects_every_caller_controlled_identity_before_git_or_mutation(self) -> None:
        cases = [("other", publication.APPLICATION, publication.REPOSITORY, publication.EXPECTED_SHA),
                 (publication.ENVIRONMENT, "other", publication.REPOSITORY, publication.EXPECTED_SHA),
                 (publication.ENVIRONMENT, publication.APPLICATION, "evil/repository", publication.EXPECTED_SHA),
                 (publication.ENVIRONMENT, publication.APPLICATION, publication.REPOSITORY, "a" * 40)]
        for values in cases:
            with self.subTest(values=values), patch.object(publication, "_run") as run, \
                    self.assertRaises(SourcePublicationError):
                publication.publish(self.binding, *values)
            run.assert_not_called()

    def test_existing_exact_ref_is_idempotent_and_state_is_unchanged(self) -> None:
        calls = []
        def ref(_mirror, name, _env):
            self.assertEqual(publication.FINAL_REF, name)
            return publication.EXPECTED_SHA
        def git(_mirror, args, _env, **_kwargs):
            calls.append(args)
            values = {"--format=%T": publication.EXPECTED_TREE,
                      "--format=%s": publication.EXPECTED_SUBJECT, "--format=%ct": publication.EXPECTED_COMMITTER_EPOCH}
            if args[0] == "rev-parse": return publication.EXPECTED_SHA.encode()
            if args[0] == "cat-file": return f"tree {publication.EXPECTED_TREE}\nparent {publication.EXPECTED_PARENT}\n".encode()
            return values[args[2]].encode()
        with patch.object(publication, "_ref", side_effect=ref), patch.object(publication, "_git", side_effect=git), patch.object(publication, "_run") as run:
            result = publication.publish(self.binding, publication.ENVIRONMENT, publication.APPLICATION,
                                         publication.REPOSITORY, publication.EXPECTED_SHA)
        run.assert_not_called()
        self.assertEqual(["rev-parse", "--verify", f"{publication.FINAL_REF}^{{commit}}"], calls[0])
        self.assertTrue(result["mutationProof"]["idempotent"])
        self.assertEqual(result["mutationProof"]["stateBeforeDigest"], result["mutationProof"]["stateAfterDigest"])
        self.assertNotIn("token", json.dumps(result).lower())
        validator.validate_schema(result, json.loads((ROOT / "schemas/source-publication-receipt.schema.json").read_text()))

    def test_new_publication_uses_only_fixed_remote_ref_and_atomic_ref_transaction(self) -> None:
        refs = iter([None, publication.EXPECTED_SHA, publication.EXPECTED_SHA])
        runs = []
        git_calls = []
        class Temporary:
            def __init__(self, **_kwargs): self.path = self_root / "quarantine"
            def __enter__(self): self.path.mkdir(); return str(self.path)
            def __exit__(self, *_args): return False
        self_root = self.root
        def run(argv, **_kwargs):
            runs.append(argv)
            return type("Completed", (), {"returncode": 0, "stdout": b""})()
        def git(_repo, args, _env, **kwargs):
            git_calls.append((args, kwargs.get("input_bytes")))
            if args[:2] == ["rev-parse", "--verify"]:
                return publication.EXPECTED_SHA.encode()
            if args[:3] == ["show", "-s", "--format=%T"]:
                return publication.EXPECTED_TREE.encode()
            if args[:2] == ["cat-file", "-p"]:
                return f"tree {publication.EXPECTED_TREE}\nparent {publication.EXPECTED_PARENT}\n".encode()
            if args[:3] == ["show", "-s", "--format=%s"]:
                return publication.EXPECTED_SUBJECT.encode()
            if args[:3] == ["show", "-s", "--format=%ct"]:
                return publication.EXPECTED_COMMITTER_EPOCH.encode()
            return b""
        with patch.object(publication, "_ref", side_effect=lambda *_args: next(refs)), \
             patch.object(publication, "_run", side_effect=run), \
             patch.object(publication, "_git", side_effect=git):
            result = publication.publish(self.binding, publication.ENVIRONMENT, publication.APPLICATION,
                publication.REPOSITORY, publication.EXPECTED_SHA, temporary_directory=Temporary)
        rendered = json.dumps(runs)
        self.assertIn(publication.CANONICAL_URL, rendered)
        self.assertIn("+" + publication.EXPECTED_SHA + ":" + publication.TEMP_REF, rendered)
        self.assertIn("+" + publication.TEMP_REF + ":" + publication.TEMP_REF, rendered)
        ssh_env = publication._git_env(self.binding)
        self.assertIn("BatchMode=yes", ssh_env["GIT_SSH_COMMAND"])
        self.assertIn("StrictHostKeyChecking=yes", ssh_env["GIT_SSH_COMMAND"])
        self.assertIn(str(self.identity), ssh_env["GIT_SSH_COMMAND"])
        transaction = next(value for args, value in git_calls if args == ["update-ref", "--stdin"])
        self.assertIn(f"create {publication.FINAL_REF} {publication.EXPECTED_SHA}".encode(), transaction)
        self.assertIn(f"delete {publication.TEMP_REF} {publication.EXPECTED_SHA}".encode(), transaction)
        self.assertFalse(result["mutationProof"]["idempotent"])
        validator.validate_schema(result, json.loads((ROOT / "schemas/source-publication-receipt.schema.json").read_text()))

    def test_unsafe_mirror_mode_fails_before_any_git_command(self) -> None:
        self.mirror.chmod(0o777)
        with patch.object(publication, "_run") as run, self.assertRaises(SourcePublicationError):
            publication.publish(self.binding, publication.ENVIRONMENT, publication.APPLICATION,
                                publication.REPOSITORY, publication.EXPECTED_SHA)
        run.assert_not_called()

    def test_credential_metadata_is_strict(self) -> None:
        self.identity.chmod(0o600)
        with patch.object(publication, "_run") as run, self.assertRaises(SourcePublicationError):
            publication.publish(self.binding, publication.ENVIRONMENT, publication.APPLICATION,
                                publication.REPOSITORY, publication.EXPECTED_SHA)
        run.assert_not_called()

    def test_shallow_commit_parent_is_read_from_raw_commit_object(self) -> None:
        env = publication._git_env(self.binding)
        def git(_repository, args, _env, **_kwargs):
            if args[0] == "rev-parse": return publication.EXPECTED_SHA.encode()
            if args[0] == "cat-file": return f"tree {publication.EXPECTED_TREE}\nparent {publication.EXPECTED_PARENT}\n".encode()
            return {"--format=%T": publication.EXPECTED_TREE, "--format=%s": publication.EXPECTED_SUBJECT,
                    "--format=%ct": publication.EXPECTED_COMMITTER_EPOCH}[args[2]].encode()
        with patch.object(publication, "_git", side_effect=git):
            publication._attest_commit(self.mirror, publication.TEMP_REF, env)


if __name__ == "__main__":
    unittest.main()
