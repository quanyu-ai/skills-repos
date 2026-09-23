from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any

from .errors import ContractError

SECRET_LIKE = ("SECRET", "TOKEN", "PASSWORD", "PRIVATE_KEY", "API_KEY", "DATABASE_URL")


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


def compose_health_targets(contract: dict[str, Any], policy: dict[str, Any]) -> tuple[str, str]:
    validate_contract_and_policy(contract, policy)
    return _validator.compose_health_targets(contract, policy)
