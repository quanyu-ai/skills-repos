# PM2 Process Adapter

ENV-1b-c implements the `v1alpha1` ProcessAdapter with PM2's programmatic API and explicit process objects. It does not use the PM2 CLI, ecosystem files, force start, name-only mutation, `delete all`, reload, or stale dump state as authority.

The Python adapter owns policy checks, external secret-name resolution, scoped inventory reconciliation, ProcessHandle provenance, health verification, absence proof, restore descriptors, and persist-after-attest ordering. The one-shot Node bridge owns only PM2 programmatic calls and safe `/proc` observations. Bridge output deliberately excludes the child environment and secret values.

## Runtime requirements

- Linux with `/proc` mounted;
- Node.js supported by pinned PM2 `7.0.4`;
- Python 3.11 or newer for the current core implementation;
- server-local external JSON secret file owned by the adapter user with mode `0400` or `0600`;
- a dedicated PM2 home and namespace for each managed environment.

`runtime_policy` is required when a persisted ProcessHandle must remain restorable after adapter restart. It supplies external secret names/source, listener binding, and health policy from the validated Environment Policy and Release Contract. Secret values never enter that policy, a ProcessHandle, State Store, bridge output, test snapshot, or exception.

## Isolated verification

```bash
npm ci --ignore-scripts
npm audit --omit=dev
npm run test:isolated
PM2_NODE_MODULES="$PWD/node_modules" python3 ../tests/test_pm2_adapter.py
```

The integration suites must run with disposable releases, a temporary `PM2_HOME`, fake secret values, and dynamically allocated non-business ports. They terminate the isolated daemon and remove temporary files. They must never point at a shared or Demo PM2 home.

## Incident coverage

| Incident | Automated evidence |
|---|---|
| `ecosystem.cjs` executed as the wrong process | Wrong-name residual remains visible and blocks replacement/start. |
| Duplicate script/name/namespace records | Full inventory exposes duplicates; overlap and scoped ambiguity fail closed. |
| PM2 stop mistaken for deletion | Test proves stopped record remains; absence requires record removal, dead PID, and free port. |
| Unexpected residual process | `assert_replaceable` and `start_candidate` reject before candidate authority is returned. |
| Candidate HTTP failure | Failed candidate is removed and exact captured runtime is restored and re-attested. |
| Stale PM2 persisted state | `persist` fails until runtime and both health targets have passed attestation. |
| Secret/ambient environment leakage | Only required secret names are resolved; unsafe source permissions fail; handle/bridge evidence excludes values and PM2 IPC poison variables. |
| Adapter restart before rollback | Persisted handle is exactly re-observed; validated runtime policy reconstructs an exact restore descriptor. |
