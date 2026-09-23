# release-manager specifications

ENV-1b-a defines the experimental `v1alpha1` contracts. ENV-1b-b adds the contract-driven core engine and a deterministic Fake Adapter for isolated verification. It does not contain a production process adapter or mutate a live environment.

## Files

- `schemas/`: executable JSON Schemas for repository contract, external environment policy, persisted ProcessHandle evidence, State Store record, and state transition traces.
- `spec/`: Engine/Adapter authority boundary and type declarations, state-machine definition, and incident-derived acceptance catalog.
- `fixtures/`: valid and deliberately invalid examples.
- `scripts/validate.py`: dependency-free schema/semantic validator used by the harness.
- `tests/test_schemas.py`: valid, fail-closed, state-transition, and traceability tests.
- `engine/`: core source/build/activation/adoption/rollback/recovery orchestration, atomic State Store, injected ports, and deterministic fakes.
- `tests/test_engine.py`: restart/recovery, crash-boundary, migration-gate, lifecycle, attestation, and restore tests.

## Validation

```bash
python3 release-manager/tests/test_schemas.py
python3 release-manager/tests/test_engine.py
python3 release-manager/scripts/validate.py all
```

Validation is intended to be the first engine step. Unknown fields, unsafe paths, interpolated shell syntax, secret-value fields, invalid migration modes, incomplete ProcessHandles, and illegal state transitions fail closed.

`toolchain.install` is deliberately not a generic command. In `v1alpha1` its only valid operation is `package-manager-frozen-install`; the future engine must resolve the exact repository-declared package manager through Corepack. Repository package scripts remain available only for the explicitly repository-owned prepare/build/verify phases.

Health ownership is split without an override layer: the Release Contract owns the path, while Environment Policy owns the internal host/port and public base URL. Targets compose as `http://<internalHost>:<internalPort><contractPath>` and `<publicBaseUrl><contractPath>` after both documents validate.

The core validates contract and policy before source or process work, acquires and re-attests an exact SHA, resolves an exact repository package manager, invokes only typed frozen install and declared lifecycle actions, verifies artifacts and a restored clean tree, and stops at an approval gate without executing database actions. The Engine alone commits the locked atomic State Store. Process handles must be issued or re-observed by the injected adapter.

The included Fake Adapter models process identity, runtime attestation, secret-name availability, ambiguity, replacement, persistence, and deterministic failures without invoking PM2 or mutating operating-system processes. Production PM2 behavior remains ENV-1b-c scope.

## Frozen deploy-app boundary

`deploy-app` remains transitional recovery knowledge. ENV-1b does not extend it into a generic state engine, contract parser, process adapter, migration orchestrator, or environment registry. Migration proceeds through ENV-1b-b core engine, ENV-1b-c isolated PM2 adapter, ENV-1b-d Quanyu shadow adoption, and a separately authorized ENV-1b-e live adoption.
