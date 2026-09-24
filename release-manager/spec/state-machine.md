# Release State Machines

The executable transition table is [`state-machines.json`](./state-machines.json). The validator rejects traces that contain an unknown transition or continue beyond a terminal state.

## Global ordering

1. Validate Release Contract, Environment Policy, existing State Record, and all referenced records.
2. Allocate a monotonic attempt ID under the environment lock.
3. Acquire and attest exact source SHA in an isolated checkout.
4. Enforce repository toolchain, frozen install, prepare, build, artifact, and clean-tree contracts.
5. Stop at `WAITING_DB_GATE` when `migration.mode=approval-gated`.
6. Obtain ProcessHandles only from adapter observation/start results.
7. Mutate process state only through the selected machine.
8. Commit State Store atomically only after runtime attestation.
9. Ask the adapter to persist supervisor state only after committed runtime attestation.

## State Store rules

- One canonical record per environment/service, outside checkout and release directories.
- Writes use create-temp, fsync, atomic rename, directory fsync.
- `generation` and attempt `sequence` increase monotonically.
- Attempts and attestation evidence remain auditable.
- `current` and `previous` require full ProcessHandle plus health/SHA attestation.
- Every runtime authority carries the State Store generation that introduced it and `restorable=true`.
- Canonical `previous` must be older than and distinct from `current`, match the same environment/service identity, and remain fully runtime-attested.
- During first adoption there is no canonical `previous`; the adapter-observed `legacy` record is the sole restore authority until the candidate is attested and the managed state is atomically committed.
- A failed attempt target cannot become `current` or `previous`.
- Filesystem symlinks are derived compatibility outputs, never canonical authority.
- Only the engine writes the State Store. Adapters return evidence and receipts.
- Host-restart reconciliation is the sole path that may replace volatile
  ProcessHandle identity without a deployment. It requires a proven Linux boot
  boundary, exact durable authority and health, commits one N+1 generation with
  a typed receipt, preserves `previous` and `attempt`, and does not persist PM2.

## Database gate

`migration.mode=none` performs no database action. `approval-gated` stops before process mutation. The release manager never detects an ORM and never runs migrate, db push, or seed implicitly.

## Health target composition

The Release Contract exclusively owns `health.path`. Environment Policy cannot override it and owns the internal bind host/port plus `publicBaseUrl`. After independent validation, the engine composes:

- internal: `http://<internalHost>:<internalPort><contract.health.path>`;
- public: `<publicBaseUrl><contract.health.path>`.

The contract path is origin-relative and cannot contain a scheme, host, traversal, or double slash. The policy base URL cannot contain a path or user information.
