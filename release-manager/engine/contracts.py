from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
from typing import Any

from .errors import ContractError

SECRET_LIKE = ("SECRET", "TOKEN", "PASSWORD", "PRIVATE_KEY", "API_KEY", "DATABASE_URL")


def canonical_document_digest(document: dict[str, Any]) -> str:
    """Digest one fully validated contract/policy document using canonical JSON."""
    payload = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def _values(policy: dict[str, Any], phase: str) -> dict[str, str]:
    return {item["name"]: item["value"] for item in policy[phase]["values"]}

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_manager_validator", ROOT / "scripts" / "validate.py")
_validator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(_validator)


def validate_contract_and_policy(contract: dict[str, Any], policy: dict[str, Any]) -> None:
    try:
        _validator.validate_document(contract)
        _validator.validate_document(policy)
    except (_validator.ValidationError, KeyError) as error:
        raise ContractError(str(error)) from error
    try:
        build_declared = set(contract["buildEnvironment"]["nonSecretEnvNames"])
        runtime_declared = set(contract["runtime"]["nonSecretEnvNames"])
        build_values = _values(policy, "build")
        runtime_values = _values(policy, "runtime")
        secrets = set(policy["secrets"]["requiredNames"])
        binding = {contract["runtime"]["binding"]["hostEnv"], contract["runtime"]["binding"]["portEnv"]}
        total = set(contract["runtime"]["envNames"])
        if set(build_values) != build_declared:
            raise ContractError("build non-secret bindings are incomplete or undeclared")
        if set(runtime_values) != runtime_declared:
            raise ContractError("runtime non-secret bindings are incomplete or undeclared")
        if runtime_declared & secrets or runtime_declared & binding or secrets & binding:
            raise ContractError("runtime environment sources must be disjoint")
        if total != runtime_declared | secrets | binding:
            raise ContractError("runtime environment classification must be complete")
        for name in build_declared | runtime_declared:
            if any(marker in name for marker in SECRET_LIKE):
                raise ContractError("secret-like name cannot use non-secret bindings")
        for name in build_declared & runtime_declared:
            if build_values[name] != runtime_values[name]:
                raise ContractError("build/runtime binding mismatch")
    except KeyError as error:
        raise ContractError(f"configuration binding is incomplete: {error}") from error


def validate_state_record(record: dict[str, Any]) -> None:
    try:
        _validator.validate_document(record)
    except (_validator.ValidationError, KeyError) as error:
        raise ContractError(str(error)) from error


def validate_legacy_restore_descriptor(descriptor: dict[str, Any]) -> None:
    try:
        _validator.validate_document(descriptor)
    except (_validator.ValidationError, KeyError) as error:
        raise ContractError(str(error)) from error
    observed = descriptor["observedAuthority"]
    recipe = descriptor["restoreRecipe"]
    source = recipe["source"]
    if source != {"releaseSha": observed["releaseSha"], "releasePath": observed["releasePath"]}:
        raise ContractError("legacy restore source must match observed authority")

    observed_invocation = observed["invocation"]
    payload = recipe["payload"]
    if payload["executable"] != observed_invocation["executable"] or payload["cwd"] != observed_invocation["cwd"]:
        raise ContractError("legacy restore payload must match observed executable and cwd")
    if recipe["bootstrap"]["args"]:
        raise ContractError("legacy restore bootstrap does not allow arbitrary argv")

    adaptation = recipe["listenerAdaptation"]
    expected_pairs = {
        adaptation["hostFlag"]: observed["listener"]["host"],
        adaptation["portFlag"]: str(observed["listener"]["port"]),
    }
    remaining: list[str] = []
    seen: set[str] = set()
    args = observed_invocation["args"]
    index = 0
    while index < len(args):
        value = args[index]
        if value in expected_pairs:
            if value in seen or index + 1 >= len(args) or args[index + 1] != expected_pairs[value]:
                raise ContractError("legacy observed listener argv does not match typed adaptation")
            seen.add(value)
            index += 2
            continue
        remaining.append(value)
        index += 1
    if seen != set(expected_pairs) or payload["args"] != remaining:
        raise ContractError("legacy restore payload argv exceeds typed listener adaptation")

    runtime = recipe["runtime"]
    secrets = recipe["secrets"]
    if runtime["requiredSecretNames"] != secrets["requiredNames"] or runtime["runtimeSecretFile"] != secrets["sourcePath"]:
        raise ContractError("legacy restore secret source binding mismatch")
    non_secret_names = [item["name"] for item in runtime["nonSecretValues"]]
    if len(non_secret_names) != len(set(non_secret_names)) or set(non_secret_names) & set(secrets["requiredNames"]):
        raise ContractError("legacy restore runtime sources overlap")


def compose_health_targets(contract: dict[str, Any], policy: dict[str, Any]) -> tuple[str, str]:
    validate_contract_and_policy(contract, policy)
    return _validator.compose_health_targets(contract, policy)
