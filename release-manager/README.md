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
- `pm2-adapter/`: pinned PM2 programmatic bridge, explicit-process isolated harness, and adapter operational boundary.
- `tests/test_pm2_adapter.py`: Linux `/proc`, external-secret, exact mutation/absence, health, persistence, restart and restore integration tests.

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

Runtime `cwd` and `executable` are always repository/release-root-relative. `artifact.appRoot` describes the application artifact boundary and is not a second runtime path base. The engine resolves runtime paths canonically and rejects symlink or other escapes from the immutable release root.

The build request cannot provide executable lookup precedence. The engine receives a separately configured trusted path list and always replaces request `PATH` with that deterministic value. PM2 IPC variables and undeclared environment values are excluded.

An approval-gated migration handoff uses a typed `MigrationApprovalReceipt`, not a boolean. It binds the approval to the target SHA, the same canonical full-document Release Contract and Environment Policy digests used by candidate/runtime attestation, environment/service identity, waiting attempt, State Store generation, gate identity, and approval time. Only a receipt digest and non-secret event evidence enter persisted release state; the engine still executes no database action.

Interrupted recovery inventories the adapter scope before deciding authority. A uniquely identified uncommitted candidate is removed, then the exact persisted current or legacy handle is re-attested or restored. Ambiguous or unexpected inventory fails closed.

The included Fake Adapter models process identity, runtime attestation, secret-name availability, ambiguity, replacement, persistence, and deterministic failures without invoking PM2 or mutating operating-system processes.

ENV-1b-c adds a PM2 ProcessAdapter behind the same interface. It uses PM2's programmatic API with explicit process objects, derives handles from PM2 plus Linux `/proc` evidence, resolves external secrets by required names, performs scoped fail-closed inventory checks, proves exact absence, attests internal/public health, reconstructs validated restore descriptors, and persists PM2 state only after attestation. Its tests use only temporary `PM2_HOME` directories, disposable processes and dynamic non-business ports; no application environment is configured or contacted.

ENV-1b-e2a adds phase-owned non-secret configuration and a bootstrap-only `LegacyRestoreDescriptor`. Repository contracts classify allowed build/runtime names; external policy supplies literal non-secret values; cross-document validation requires runtime sources to be complete and disjoint from secret and listener bindings. Canonical full-document Release Contract and Environment Policy digests, together with narrower build/runtime digests, are attested from candidate creation through runtime and persisted state. The `SECRET_LIKE` name check is defense-in-depth only: policy authors remain responsible for classifying values by provenance and sensitivity, and secret values must never enter the typed non-secret channels. First adoption loads its legacy descriptor from a restricted external file. Digest-bound `observedAuthority` is used only for exact live observation; the separately typed `restoreRecipe` is used only for isolated preflight and emergency restoration. Both identify the same release/source and payload, while only declared host/port listener adaptation may differ through the trusted bootstrap. Arbitrary environment or argv rewriting is rejected. Descriptor contents and secret values do not enter ProcessHandle or State Store evidence.

## Frozen deploy-app boundary

`deploy-app` remains transitional recovery knowledge. ENV-1b does not extend it into a generic state engine, contract parser, process adapter, migration orchestrator, or environment registry. Migration proceeds through ENV-1b-b core engine, ENV-1b-c isolated PM2 adapter, ENV-1b-d Quanyu shadow adoption, and a separately authorized ENV-1b-e live adoption.
