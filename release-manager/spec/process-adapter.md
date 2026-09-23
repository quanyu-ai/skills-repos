# Process Adapter Contract

Status: `v1alpha1`. ENV-1b-c implements the PM2 adapter while preserving this Engine/Adapter boundary.

## Authority boundary

The Release Engine owns validation, state-machine transitions, locks, attempt/generation allocation, and atomic State Store writes. A Process Adapter owns process inventory, exact process mutation, runtime attestation, and adapter persistence. An adapter must never write release state or select a release by itself.

```ts
declare const processHandleBrand: unique symbol;

export type ProcessHandle = Readonly<PersistedProcessHandle> & {
  readonly [processHandleBrand]: "adapter-observed-or-started";
};

export interface ProcessAdapter {
  inventory(service: ServiceIdentity): Promise<ProcessInventory>;
  validatePolicy(policy: ProcessPolicy): Promise<void>;
  observeLegacy(spec: LegacyObservationSpec): Promise<ProcessHandle>;
  assertReplaceable(current: ProcessHandle, candidate: RuntimeSpec): Promise<void>;
  stopExact(handle: ProcessHandle): Promise<void>;
  deleteExact(handle: ProcessHandle): Promise<void>;
  awaitAbsent(handle: ProcessHandle): Promise<AbsenceEvidence>;
  startCandidate(spec: RuntimeSpec): Promise<ProcessHandle>;
  attest(handle: ProcessHandle, expected: RuntimeAttestation): Promise<Attestation>;
  restore(handle: RestorableProcessHandle): Promise<ProcessHandle>;
  persist(attested: ProcessHandle): Promise<PersistedStateReceipt>;
}
```

## ProcessHandle provenance

A handle is opaque to the engine. It can only be returned by `observeLegacy`, `startCandidate`, or `restore`. Parsing a persisted JSON representation validates evidence shape but does not mint the in-memory branded type. Rehydration requires the adapter to observe the process again and match:

- adapter kind, version, and instance;
- environment/service identity and namespace;
- adapter record ID;
- PID plus process-start identity;
- executable, arguments, and cwd;
- exact release SHA;
- invocation fingerprint;
- adapter observation/start receipt as correlation evidence only.

The receipt is not an authentication mechanism and a persisted receipt is never sufficient to recreate an in-memory handle. After adapter restart, rehydration must use a full live inventory and match the exact PM2 record, PID/start identity, `/proc` runtime evidence, release SHA, and invocation fingerprint. The adapter then mints a new observation and receipt. State Store tamper resistance, if required, belongs to a separate integrity/signing design.

Name and namespace are selectors. Neither is authority on its own.

The State Store wraps an attested handle in a restorable runtime-authority record with its introducing generation. `previous` is canonical rollback authority only through that record. A filesystem symlink cannot substitute for it. Before the first managed commit, the adapter-observed legacy handle is the only restore authority and canonical `previous` is absent.

## Fail-closed requirements

- Unknown fields in policy/contract/state fail schema validation.
- Ambiguous inventory or an unexpected overlapping process fails before mutation.
- Stop does not prove absence. Absence requires adapter-record absence, dead prior PID, free owned listener, and a second inventory.
- Broad delete, force start, and name-only deletion are forbidden.
- The adapter persists supervisor state only after the engine requests it with an attested handle.
- Restore failure returns evidence and enters engine-owned `RECOVERY_REQUIRED`; the adapter does not pick another target.

## PM2 v1 implementation constraints

The PM2 adapter uses the programmatic API with an explicit process object. A recognized `*.config.cjs` file is allowed only as a compatibility fixture. Cluster reload is not a v1 capability. Tests use an isolated `PM2_HOME`, disposable processes, fake secrets, Linux `/proc` evidence, and non-business ports.
