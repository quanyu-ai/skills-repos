#!/opt/quanyu/release-manager/runtime/python3.12
"""One-time canonical ReleaseEngine migration for missing managed artifact authority."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine import AtomicStateStore, ReleaseEngine, ReleaseRequest  # noqa: E402
from engine.preflight import _read_json  # noqa: E402
from scripts.release_manager import _load_operator  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(prog="migrate-artifact-authority")
    parser.add_argument("--environment-id", required=True)
    parser.add_argument("--service-id", required=True)
    parser.add_argument("--expected-repository", required=True)
    parser.add_argument("--expected-current-sha", required=True)
    parser.add_argument("--expected-generation", type=int, required=True)
    args = parser.parse_args()
    try:
        operator = _load_operator(args.environment_id, args.service_id)
        binding = operator.binding
        if binding.repository != args.expected_repository:
            raise ValueError("repository authority mismatch")
        policy, _ = _read_json(binding.policy_file, binding.trusted_owner_uids)
        contract, _ = _read_json(binding.contract_file, binding.trusted_owner_uids)
        engine = ReleaseEngine(
            object(),
            object(),
            operator.adapter,
            AtomicStateStore(binding.state_file, binding.lock_file),
            Path(policy["storage"]["releaseRoot"]),
            trusted_path=("/usr/local/bin", "/usr/bin", "/bin"),
        )
        result = engine.migrate_managed_artifact_authority(
            ReleaseRequest(binding.repository, args.expected_current_sha, contract, policy, {}),
            expected_generation=args.expected_generation,
        )
        value = {
            "schemaVersion": "quanyu.ai/artifact-authority-migration-result/v1",
            "status": result.status,
            "generation": result.state["generation"],
            "currentReleaseSha": result.state["current"]["releaseSha"],
            "currentArtifactDigest": result.state["current"]["artifactDigest"],
            "previousReleaseSha": result.state["previous"]["releaseSha"],
            "previousArtifactDigest": result.state["previous"]["artifactDigest"],
            "receiptDigest": None if result.receipt is None else result.receipt["receiptDigest"],
        }
    except Exception:
        value = {
            "schemaVersion": "quanyu.ai/artifact-authority-migration-error/v1",
            "decision": "FAIL_CLOSED",
            "code": "ARTIFACT_AUTHORITY_MIGRATION_UNPROVEN",
        }
        json.dump(value, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
        return 2
    json.dump(value, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
