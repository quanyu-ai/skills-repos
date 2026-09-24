#!/usr/bin/env python3
"""Dependency-free validator for the ENV-1b-a JSON Schema subset and semantics."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = ROOT / "schemas"
FIXTURES = ROOT / "fixtures"
MACHINES = ROOT / "spec" / "state-machines.json"

SCHEMA_BY_KIND = {
    "ReleaseContract": "release-contract.schema.json",
    "EnvironmentPolicy": "environment-policy.schema.json",
    "LegacyRestoreDescriptor": "legacy-restore-descriptor.schema.json",
    "ProcessHandle": "process-handle.schema.json",
    "ReleaseState": "state-record.schema.json",
}
SCHEMA_BY_ID = {
    "https://quanyu.ai/schemas/release-contract/v1alpha1": "release-contract.schema.json",
    "https://quanyu.ai/schemas/environment-policy/v1alpha1": "environment-policy.schema.json",
    "https://quanyu.ai/schemas/legacy-restore-descriptor/v1alpha1": "legacy-restore-descriptor.schema.json",
    "https://quanyu.ai/schemas/process-handle/v1alpha1": "process-handle.schema.json",
    "https://quanyu.ai/schemas/state-record/v1alpha1": "state-record.schema.json",
    "https://quanyu.ai/schemas/transition-trace/v1alpha1": "transition-trace.schema.json",
}


class ValidationError(ValueError):
    pass


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _resolve_pointer(root: Any, pointer: str) -> Any:
    node = root
    if pointer:
        for raw in pointer.lstrip("/").split("/"):
            key = raw.replace("~1", "/").replace("~0", "~")
            node = node[key]
    return node


def _type_matches(value: Any, expected: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[expected]


def validate_schema(value: Any, schema: dict[str, Any], path: str = "$", root: dict[str, Any] | None = None) -> None:
    root = schema if root is None else root
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.startswith("#"):
            target_root = root
            target = _resolve_pointer(root, ref[1:])
        else:
            filename, _, fragment = ref.partition("#")
            target_root = load_json(SCHEMAS / SCHEMA_BY_ID.get(filename, filename))
            target = _resolve_pointer(target_root, fragment)
        validate_schema(value, target, path, target_root)
        return

    if "oneOf" in schema:
        matches = 0
        for candidate in schema["oneOf"]:
            try:
                validate_schema(value, candidate, path, root)
                matches += 1
            except ValidationError:
                pass
        if matches != 1:
            raise ValidationError(f"{path}: expected exactly one schema match, got {matches}")

    if "allOf" in schema:
        for candidate in schema["allOf"]:
            validate_schema(value, candidate, path, root)

    if "const" in schema and value != schema["const"]:
        raise ValidationError(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise ValidationError(f"{path}: not in allowed enum")

    expected = schema.get("type")
    if expected and not _type_matches(value, expected):
        raise ValidationError(f"{path}: expected {expected}")

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        missing = [name for name in schema.get("required", []) if name not in value]
        if missing:
            raise ValidationError(f"{path}: missing required fields {missing}")
        if schema.get("additionalProperties") is False:
            unknown = sorted(set(value) - set(properties))
            if unknown:
                raise ValidationError(f"{path}: unknown fields {unknown}")
        for name, child in value.items():
            if name in properties:
                validate_schema(child, properties[name], f"{path}.{name}", root)

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise ValidationError(f"{path}: too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise ValidationError(f"{path}: too many items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True) for item in value]
            if len(encoded) != len(set(encoded)):
                raise ValidationError(f"{path}: duplicate items")
        if "items" in schema:
            for index, child in enumerate(value):
                validate_schema(child, schema["items"], f"{path}[{index}]", root)

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise ValidationError(f"{path}: string too short")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise ValidationError(f"{path}: string too long")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            raise ValidationError(f"{path}: pattern mismatch")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ValidationError(f"{path}: below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            raise ValidationError(f"{path}: above maximum")


def _actions(contract: dict[str, Any]) -> list[dict[str, Any]]:
    actions = [contract["lifecycle"]["build"]]
    prepare = contract["lifecycle"].get("prepare")
    if prepare:
        actions.append(prepare["action"])
    actions.extend(contract["lifecycle"]["verify"])
    return actions


def validate_release_semantics(data: dict[str, Any]) -> None:
    env_names = set(data["runtime"]["envNames"])
    binding = data["runtime"]["binding"]
    if binding["hostEnv"] not in env_names or binding["portEnv"] not in env_names:
        raise ValidationError("$.runtime.binding: host/port names must appear in envNames")
    forbidden = re.compile(r"(^|:)(db:)?migrate($|:)|(^|:)seed($|:)|\bdb\s+push\b", re.I)
    for action in _actions(data):
        tokens = action.get("argv", [action.get("packageScript", "")])
        if forbidden.search(" ".join(tokens)):
            raise ValidationError("lifecycle: database mutation commands are not release actions")


def validate_policy_semantics(data: dict[str, Any]) -> None:
    storage = data["storage"]
    release_root = storage["releaseRoot"].rstrip("/")
    for name in ("stateRoot", "lockFile"):
        if storage[name] == release_root or storage[name].startswith(release_root + "/"):
            raise ValidationError(f"$.storage.{name}: must be outside releaseRoot")
    if data["network"]["publicBaseUrl"].startswith("http://127.0.0.1"):
        raise ValidationError("$.network.publicBaseUrl: cannot be the internal listener")
    for phase in ("build", "runtime"):
        names = [item["name"] for item in data[phase]["values"]]
        if len(names) != len(set(names)):
            raise ValidationError(f"$.{phase}.values: duplicate names")


def validate_legacy_restore_semantics(data: dict[str, Any]) -> None:
    authority = data["observedAuthority"]
    recipe = data["restoreRecipe"]
    release_prefix = authority["releasePath"].rstrip("/") + "/"
    if recipe["source"] != {"releaseSha": authority["releaseSha"], "releasePath": authority["releasePath"]}:
        raise ValidationError("$.restoreRecipe.source: must match observedAuthority")
    for label, path in (
        ("observedAuthority.invocation.cwd", authority["invocation"]["cwd"]),
        ("restoreRecipe.bootstrap.cwd", recipe["bootstrap"]["cwd"]),
        ("restoreRecipe.payload.cwd", recipe["payload"]["cwd"]),
        ("restoreRecipe.payload.executable", recipe["payload"]["executable"]),
    ):
        if not path.startswith(release_prefix):
            raise ValidationError(f"$.{label}: must be contained by observed releasePath")
    if recipe["payload"]["executable"] != authority["invocation"]["executable"] or recipe["payload"]["cwd"] != authority["invocation"]["cwd"]:
        raise ValidationError("$.restoreRecipe.payload: must match observed executable and cwd")
    if recipe["bootstrap"]["args"]:
        raise ValidationError("$.restoreRecipe.bootstrap.args: arbitrary argv is forbidden")
    adaptation = recipe["listenerAdaptation"]
    expected_pairs = {adaptation["hostFlag"]: authority["listener"]["host"], adaptation["portFlag"]: str(authority["listener"]["port"])}
    remaining = []
    seen = set()
    index = 0
    args = authority["invocation"]["args"]
    while index < len(args):
        token = args[index]
        if token in expected_pairs:
            if token in seen or index + 1 >= len(args) or args[index + 1] != expected_pairs[token]:
                raise ValidationError("$.observedAuthority.invocation.args: typed listener mismatch")
            seen.add(token); index += 2; continue
        remaining.append(token); index += 1
    if seen != set(expected_pairs) or recipe["payload"]["args"] != remaining:
        raise ValidationError("$.restoreRecipe.payload.args: only typed listener adaptation is allowed")
    if recipe["listener"] != authority["listener"]:
        raise ValidationError("$.restoreRecipe.listener: must preserve the observed business listener")
    if recipe["probe"]["port"] == recipe["listener"]["port"]:
        raise ValidationError("$.restoreRecipe.probe: must use a non-business port")
    runtime = recipe["runtime"]
    secrets = recipe["secrets"]
    if runtime["requiredSecretNames"] != secrets["requiredNames"]:
        raise ValidationError("$.restoreRecipe.runtime.requiredSecretNames: must equal secrets.requiredNames")
    if runtime["runtimeSecretFile"] != secrets["sourcePath"]:
        raise ValidationError("$.restoreRecipe.runtime.runtimeSecretFile: must equal secrets.sourcePath")
    values = runtime["nonSecretValues"]
    names = [item["name"] for item in values]
    if len(names) != len(set(names)):
        raise ValidationError("$.restoreRecipe.runtime.nonSecretValues: duplicate names")
    if set(names) & set(secrets["requiredNames"]):
        raise ValidationError("$.restoreRecipe.runtime.nonSecretValues: secret names are forbidden")


def compose_health_targets(contract: dict[str, Any], policy: dict[str, Any]) -> tuple[str, str]:
    """Compose targets without allowing either document to override the other's authority."""
    path = contract["health"]["path"]
    host = policy["network"]["internalHost"]
    rendered_host = f"[{host}]" if ":" in host else host
    internal = f"http://{rendered_host}:{policy['network']['internalPort']}{path}"
    public = f"{policy['network']['publicBaseUrl']}{path}"
    return internal, public


def validate_state_semantics(data: dict[str, Any]) -> None:
    attempt = data["attempt"]
    event_sequences = [event["sequence"] for event in attempt["events"]]
    if event_sequences != sorted(set(event_sequences)):
        raise ValidationError("$.attempt.events: sequences must be strictly increasing")
    if attempt["sequence"] > data["generation"]:
        raise ValidationError("$.attempt.sequence: cannot exceed state generation")
    for slot in ("current", "previous", "legacy"):
        release = data.get(slot)
        if not release:
            continue
        sha = release["releaseSha"]
        if release["generation"] > data["generation"]:
            raise ValidationError(f"$.{slot}: release generation exceeds state generation")
        if release["handle"]["releaseSha"] != sha:
            raise ValidationError(f"$.{slot}: ProcessHandle SHA mismatch")
        identity = release["handle"]["identity"]
        if identity["environmentId"] != data["environmentId"] or identity["serviceId"] != data["serviceId"]:
            raise ValidationError(f"$.{slot}: ProcessHandle environment/service identity mismatch")
        if slot == "current" and data["status"] == "managed" and release["handle"]["provenance"]["origin"] == "started":
            digests = release["handle"].get("configurationDigests", {})
            if digests.get("releaseContract") != data["releaseContractDigest"] or digests.get("environmentPolicy") != data["environmentPolicyDigest"]:
                raise ValidationError("$.current: ProcessHandle contract/policy digest context mismatch")
        attestation = release["attestation"]
        if attestation["sourceSha"] != sha or attestation["runtimeSha"] != sha:
            raise ValidationError(f"$.{slot}: attestation SHA mismatch")
    if data["status"] == "managed" and "current" not in data:
        raise ValidationError("$: managed state requires current")
    if "previous" in data and "current" not in data:
        raise ValidationError("$.previous: rollback authority requires current")
    if "current" in data and "previous" in data:
        current, previous = data["current"], data["previous"]
        if previous["generation"] >= current["generation"]:
            raise ValidationError("$.previous: generation must precede current")
        if previous["releaseSha"] == current["releaseSha"]:
            raise ValidationError("$.previous: release must differ from current")
    if "legacy" in data:
        if data["legacy"]["handle"]["provenance"]["origin"] != "observed":
            raise ValidationError("$.legacy: authority must originate from adapter observation")
        if "current" in data or "previous" in data:
            raise ValidationError("$.legacy: first-adoption authority cannot coexist with canonical authority")
    if data["status"] in {"adoption-ready", "activating"} and "current" not in data and "legacy" not in data:
        raise ValidationError("$: first adoption requires legacy restore authority until managed commit")
    if data["status"] == "managed" and "legacy" in data:
        raise ValidationError("$: managed commit supersedes legacy restore authority")
    if attempt["outcome"] == "failed":
        for slot in ("current", "previous"):
            if data.get(slot, {}).get("releaseSha") == attempt["targetSha"]:
                raise ValidationError(f"$.{slot}: failed target cannot be release authority")


def validate_transition_trace(data: dict[str, Any]) -> None:
    spec = load_json(MACHINES)["machines"][data["machine"]]
    allowed = {tuple(item) for item in spec["transitions"]}
    state = spec["initial"]
    terminal = set(spec["terminal"])
    for index, transition in enumerate(data["transitions"]):
        triple = (transition["from"], transition["event"], transition["to"])
        if transition["from"] != state or triple not in allowed:
            raise ValidationError(f"$.transitions[{index}]: illegal transition {triple}")
        state = transition["to"]
        if state in terminal and index != len(data["transitions"]) - 1:
            raise ValidationError(f"$.transitions[{index}]: transition continues after terminal state")


def validate_document(data: dict[str, Any], schema_name: str | None = None) -> None:
    if schema_name is None:
        if "machine" in data and "transitions" in data:
            schema_name = "transition-trace.schema.json"
        else:
            schema_name = SCHEMA_BY_KIND.get(data.get("kind", ""))
    if not schema_name:
        raise ValidationError("$: unknown document kind")
    schema = load_json(SCHEMAS / schema_name)
    validate_schema(data, schema)
    kind = data.get("kind")
    if kind == "ReleaseContract":
        validate_release_semantics(data)
    elif kind == "EnvironmentPolicy":
        validate_policy_semantics(data)
    elif kind == "LegacyRestoreDescriptor":
        validate_legacy_restore_semantics(data)
    elif kind == "ReleaseState":
        validate_state_semantics(data)
    elif schema_name == "transition-trace.schema.json":
        validate_transition_trace(data)


def validate_file(path: Path, schema_name: str | None = None) -> None:
    validate_document(load_json(path), schema_name)


def validate_all_fixtures() -> None:
    valid = sorted((FIXTURES / "valid").glob("*.json"))
    invalid = sorted((FIXTURES / "invalid").glob("*.json"))
    for path in valid:
        validate_file(path)
        print(f"VALID PASS {path.relative_to(ROOT)}")
    for path in invalid:
        try:
            validate_file(path)
        except (ValidationError, KeyError):
            print(f"INVALID REJECTED {path.relative_to(ROOT)}")
        else:
            raise ValidationError(f"invalid fixture unexpectedly passed: {path}")


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 2 and argv[1] == "all":
            validate_all_fixtures()
        elif len(argv) in (2, 3):
            validate_file(Path(argv[1]), argv[2] if len(argv) == 3 else None)
            print(f"VALID PASS {argv[1]}")
        else:
            print("usage: validate.py all | <document.json> [schema-file]", file=sys.stderr)
            return 2
    except (ValidationError, KeyError, json.JSONDecodeError, OSError) as error:
        print(f"VALIDATION FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
