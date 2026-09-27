#!/opt/quanyu/release-manager/runtime/python3.12
"""Host-bound Release Manager operator. This command intentionally has no path or shell options."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine.pm2_adapter import PM2ProcessAdapter  # noqa: E402
from engine.preflight import OperatorBinding, PreflightError, PreflightStatusOperator, _read_json  # noqa: E402
from engine.source_publication import SourcePublicationBinding, publish  # noqa: E402


REGISTRY = Path("/etc/quanyu/release-manager/operator-registry.v1.json")
ALLOWED_ENTRY_KEYS = {"environmentId", "serviceId", "repository", "policyFile", "contractFile", "stateFile", "lockFile", "sourceMirror", "maxStateAgeSeconds", "trustedOwnerUids", "pm2", "sourcePublication"}
ALLOWED_PM2_KEYS = {"home", "nodeModules", "instanceId", "stableName", "serviceUid"}
ALLOWED_PUBLICATION_KEYS = {"identityFile", "knownHostsFile"}


def _load_binding(environment_id: str, service_id: str) -> tuple[OperatorBinding, dict[str, object], dict[str, object]]:
    try:
        document, _ = _read_json(REGISTRY, (0,))
        if set(document) != {"schemaVersion", "operators"} or document["schemaVersion"] != "quanyu.ai/release-manager-operator-registry/v1" or not isinstance(document["operators"], list):
            raise PreflightError("operator registry schema is invalid")
        matches = [item for item in document["operators"] if item.get("environmentId") == environment_id and item.get("serviceId") == service_id]
        if len(matches) != 1:
            raise PreflightError("operator identity is not uniquely registered")
        item = matches[0]
        if (set(item) != ALLOWED_ENTRY_KEYS or set(item["pm2"]) != ALLOWED_PM2_KEYS
                or set(item["sourcePublication"]) != ALLOWED_PUBLICATION_KEYS):
            raise PreflightError("operator registry entry is invalid")
        binding = OperatorBinding(environment_id, service_id, item["repository"], Path(item["policyFile"]), Path(item["contractFile"]), Path(item["stateFile"]), Path(item["lockFile"]), Path(item["sourceMirror"]), int(item["maxStateAgeSeconds"]), tuple(item["trustedOwnerUids"]))
        return binding, item["pm2"], item["sourcePublication"]
    except PreflightError:
        raise
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError) as error:
        raise PreflightError("operator registry cannot be loaded safely") from error


def _load_operator(environment_id: str, service_id: str) -> PreflightStatusOperator:
    binding, pm2, _ = _load_binding(environment_id, service_id)
    adapter = PM2ProcessAdapter(pm2_home=Path(pm2["home"]), node_modules=Path(pm2["nodeModules"]),
        instance_id=pm2["instanceId"], stable_name=pm2["stableName"], secret_owner_uid=int(pm2["serviceUid"]))
    return PreflightStatusOperator(binding, adapter)


def main() -> int:
    parser = argparse.ArgumentParser(prog="release-manager")
    subcommands = parser.add_subparsers(dest="operation", required=True)
    command = subcommands.add_parser("preflight-status")
    command.add_argument("--environment-id", required=True)
    command.add_argument("--service-id", required=True)
    command.add_argument("--expected-repository", required=True)
    command.add_argument("--expected-candidate-sha")
    publication = subcommands.add_parser("source-publication")
    publication.add_argument("--environment-id", required=True)
    publication.add_argument("--service-id", required=True)
    publication.add_argument("--expected-repository", required=True)
    publication.add_argument("--expected-candidate-sha", required=True)
    args = parser.parse_args()
    try:
        if args.operation == "source-publication":
            item, _, publication_config = _load_binding(args.environment_id, args.service_id)
            result = publish(SourcePublicationBinding(item.environment_id, item.service_id, item.repository,
                item.source_mirror, item.state_file, item.lock_file, item.trusted_owner_uids,
                Path(publication_config["identityFile"]), Path(publication_config["knownHostsFile"])),
                args.environment_id, args.service_id, args.expected_repository, args.expected_candidate_sha)
        else:
            operator = _load_operator(args.environment_id, args.service_id)
            result = operator.observe(args.environment_id, args.service_id, args.expected_repository, args.expected_candidate_sha)
    except Exception:
        if args.operation == "source-publication":
            error = {"schemaVersion": "quanyu.ai/managed-source-publication-error/v1", "decision": "FAIL_CLOSED", "code": "SOURCE_PUBLICATION_AUTHORITY_UNPROVEN"}
        else:
            error = {"schemaVersion": "quanyu.ai/release-manager-preflight-error/v1", "decision": "FAIL_CLOSED", "code": "PREFLIGHT_AUTHORITY_UNPROVEN"}
        json.dump(error, sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
        return 2
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
