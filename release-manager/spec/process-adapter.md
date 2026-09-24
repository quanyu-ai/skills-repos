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
  preflightLegacyRestore(descriptor: LegacyRestoreDescriptor): Promise<ProbeEvidence>;
  observeLegacy(descriptor: LegacyRestoreDescriptor): Promise<ProcessHandle>;
  resolvePersisted(record: PersistedProcessHandle): Promise<ProcessHandle>;
  observeManagedAfterHostRestart(current: PersistedProcessHandle, expected: ManagedAuthority): Promise<HostRestartObservation>;
  assertReplaceable(current: ProcessHandle, candidate: RuntimeSpec): Promise<void>;
  stopExact(handle: ProcessHandle): Promise<void>;
  deleteExact(handle: ProcessHandle): Promise<void>;
  awaitAbsent(handle: ProcessHandle): Promise<AbsenceEvidence>;
  validateRuntimeSpec(spec: RuntimeSpec): Promise<void>;
  removeInterruptedCandidate(spec: RuntimeSpec): Promise<RawOrphanRemovalReceipt>;
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

Host-restart reconciliation is a separate engine operation and never relaxes
normal persisted-handle resolution. The adapter must use a fresh full inventory
and Linux boot identity to distinguish an unchanged exact handle, a permitted
cross-boot volatile identity change, and a forbidden same-boot identity change.
All durable service identity, release, canonical runtime, four configuration
digests, listener ownership and release containment fields must match exactly;
the scope must contain exactly one healthy process with no overlap. The engine
then atomically commits an N+1 State Store generation with a typed receipt while
preserving the current release, previous authority and deployment attempt.
Reconciliation performs no process mutation and never invokes PM2 persist.

Interrupted activation recovery is narrower than normal inventory and never
weakens `resolvePersisted`. When a persisted `candidate-ready` activation has
already removed its prior current process, the adapter may inspect raw PM2
records solely to identify one PID-less orphan. Removal requires an exact match
on service identity, namespace, stable name, target SHA, candidate attempt-root
runtime, listener, all four configuration digests, and a valid release-manager
launch token. Any mismatch, overlap, live PID, or ambiguity fails closed. The
engine validates the current external runtime policy before removal, restores
the persisted prior authority as a fresh process, attests health, persists PM2,
and atomically records an N+1 failed/recovered generation while preserving the
original failed attempt and previous authority.

The State Store wraps an attested handle in a restorable runtime-authority record with its introducing generation. `previous` is canonical rollback authority only through that record. A filesystem symlink cannot substitute for it. Before the first managed commit, the adapter-observed legacy handle is the only restore authority and canonical `previous` is absent.

Candidate handles attest canonical digests of the complete Release Contract and Environment Policy, plus narrower typed build and runtime configuration digests. The complete document digests bind the repository semantics that interpret policy values, including runtime invocation, environment classification, listener bindings, and artifact/runtime fields. Bootstrap legacy handles carry only the digest of a separately loaded, permission-checked `LegacyRestoreDescriptor`; descriptor contents and secret values never enter the ProcessHandle or State Store. Re-observation after adapter restart requires the exact external descriptor and a fresh live PM2 plus `/proc` identity match. A managed persisted handle is rejected when its live or persisted contract/policy digest context differs from its State Store authority.

`LegacyRestoreDescriptor.observedAuthority` and `restoreRecipe` are separate proofs covered by that one digest. `observeLegacy` matches only the immutable observed executable, argv, cwd, process identity, source and listener. `preflightLegacyRestore` and legacy `restore` use only the reviewed recipe. The recipe binds the same release SHA/path, payload executable/cwd and business listener. Payload argv may differ only by removing explicitly declared host/port flag pairs so the bootstrap can inject that business listener or an isolated probe host on a distinct non-business port. The external bootstrap is trusted through its explicit entry in the restricted descriptor plus canonical-path, expected-owner, safe-mode and non-symlink checks; it is not release-contained by implication. Its argv is closed, and runtime secret names/source plus typed non-secret values are explicit.

## Fail-closed requirements

- Unknown fields in policy/contract/state fail schema validation.
- Ambiguous inventory or an unexpected overlapping process fails before mutation.
- Stop does not prove absence. Absence requires adapter-record absence, dead prior PID, free owned listener, and a second inventory.
- Broad delete, force start, and name-only deletion are forbidden.
- Candidate start uses a bounded launch-token-bound observation window. A
  uniquely owned PID-less record that never yields `/proc` evidence is deleted
  through the raw exact-record primitive before the original start failure is
  returned; an ambiguous or live-but-unattestable record is retained and fails
  closed.
- The adapter persists supervisor state only after the engine requests it with an attested handle.
- Restore failure returns evidence and enters engine-owned `RECOVERY_REQUIRED`; the adapter does not pick another target.
- Every candidate runtime environment name has exactly one typed source: non-secret policy value, host/port binding, or required external secret. Missing, duplicate, phase-mismatched, and undeclared sources fail before mutation.
- The `SECRET_LIKE` name check is defense-in-depth only. Policy authors must classify every value by its actual provenance and sensitivity; an innocuous variable name never makes secret material safe for `build.values` or `runtime.values`.
- First adoption requires an isolated executable probe of the exact external Legacy Restore Descriptor before the live legacy handle can be removed.

## PM2 v1 implementation constraints

The PM2 adapter uses the programmatic API with an explicit process object. A recognized `*.config.cjs` file is allowed only as a compatibility fixture. Cluster reload is not a v1 capability. Tests use an isolated `PM2_HOME`, disposable processes, fake secrets, Linux `/proc` evidence, and non-business ports.
