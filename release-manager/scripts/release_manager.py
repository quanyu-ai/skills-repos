#!/usr/bin/env python3
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


REGISTRY = Path("/etc/quanyu/release-manager/operator-registry.v1.json")
ALLOWED_ENTRY_KEYS = {"environmentId", "serviceId", "repository", "policyFile", "contractFile", "stateFile", "lockFile", "sourceMirror", "maxStateAgeSeconds", "trustedOwnerUids", "pm2"}
ALLOWED_PM2_KEYS = {"home", "nodeModules", "instanceId", "stableName", "serviceUid"}


def _load_operator(environment_id: str, service_id: str) -> PreflightStatusOperator:
    try:
        document, _ = _read_json(REGISTRY, (0,))
        if set(document) != {"schemaVersion", "operators"} or document["schemaVersion"] != "quanyu.ai/release-manager-operator-registry/v1" or not isinstance(document["operators"], list):
            raise PreflightError("operator registry schema is invalid")
        matches = [item for item in document["operators"] if item.get("environmentId") == environment_id and item.get("serviceId") == service_id]
        if len(matches) != 1:
            raise PreflightError("operator identity is not uniquely registered")
        item = matches[0]
        if set(item) != ALLOWED_ENTRY_KEYS or set(item["pm2"]) != ALLOWED_PM2_KEYS:
            raise PreflightError("operator registry entry is invalid")
        binding = OperatorBinding(environment_id, service_id, item["repository"], Path(item["policyFile"]), Path(item["contractFile"]), Path(item["stateFile"]), Path(item["lockFile"]), Path(item["sourceMirror"]), int(item["maxStateAgeSeconds"]), tuple(item["trustedOwnerUids"]))
        pm2 = item["pm2"]
        adapter = PM2ProcessAdapter(pm2_home=Path(pm2["home"]), node_modules=Path(pm2["nodeModules"]), instance_id=pm2["instanceId"], stable_name=pm2["stableName"], secret_owner_uid=int(pm2["serviceUid"]))
        return PreflightStatusOperator(binding, adapter)
    except PreflightError:
        raise
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError) as error:
        raise PreflightError("operator registry cannot be loaded safely") from error


def main() -> int:
    parser = argparse.ArgumentParser(prog="release-manager")
    subcommands = parser.add_subparsers(dest="operation", required=True)
    command = subcommands.add_parser("preflight-status")
    command.add_argument("--environment-id", required=True)
    command.add_argument("--service-id", required=True)
    command.add_argument("--expected-repository", required=True)
    command.add_argument("--expected-candidate-sha")
    args = parser.parse_args()
    try:
        result = _load_operator(args.environment_id, args.service_id).observe(args.environment_id, args.service_id, args.expected_repository, args.expected_candidate_sha)
    except Exception:
        json.dump({"schemaVersion": "quanyu.ai/release-manager-preflight-error/v1", "decision": "FAIL_CLOSED", "code": "PREFLIGHT_AUTHORITY_UNPROVEN"}, sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
        return 2
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
