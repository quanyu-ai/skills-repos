from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any

from .errors import ContractError

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


def validate_state_record(record: dict[str, Any]) -> None:
    try:
        _validator.validate_document(record)
    except (_validator.ValidationError, KeyError) as error:
        raise ContractError(str(error)) from error


def compose_health_targets(contract: dict[str, Any], policy: dict[str, Any]) -> tuple[str, str]:
    validate_contract_and_policy(contract, policy)
    return _validator.compose_health_targets(contract, policy)
