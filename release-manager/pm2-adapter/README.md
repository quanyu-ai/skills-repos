# PM2 Process Adapter

ENV-1b-c implements the `v1alpha1` ProcessAdapter with PM2's programmatic API and explicit process objects. It does not use the PM2 CLI, ecosystem files, force start, name-only mutation, `delete all`, reload, or stale dump state as authority.

The Python adapter owns policy checks, external secret-name resolution, scoped inventory reconciliation, ProcessHandle provenance, health verification, absence proof, restore descriptors, and persist-after-attest ordering. The one-shot Node bridge owns only PM2 programmatic calls and safe `/proc` observations. Bridge output deliberately excludes the child environment and secret values.

## Runtime requirements

- Linux with `/proc` mounted;
- Node.js supported by pinned PM2 `7.0.4`;
- Python 3.11 or newer for the current core implementation;
- server-local regular, non-symlink external JSON secret file owned by the trusted configured service UID with mode exactly `0400` or `0600`;
- a dedicated PM2 home and namespace for each managed environment.

`runtime_policy` is required when a persisted ProcessHandle must remain restorable after adapter restart. It supplies external secret names/source, listener binding, and health policy from the validated Environment Policy and Release Contract. Secret values never enter that policy, a ProcessHandle, State Store, bridge output, test snapshot, or exception.

At construction, the adapter queries the same loaded Node/PM2 module path used by the bridge and records adapter, Node runtime/executable, and PM2 client package versions as non-secret evidence. The client package must exactly match pinned `7.0.4`; Node must satisfy the adapter's supported major-version floor. This construction check does not connect to or start a PM2 daemon.

Before every managed observation or mutation, the adapter separately attests the connected daemon from Linux `/proc`: exact PM2 `7.0.4`, live PID/start identity, the same trusted Node executable/runtime, and no forbidden ambient `NODE_CHANNEL_FD` or `NODE_UNIQUE_ID`. A global or stale daemon fails closed even when the bridge client package is correct.

`bootstrap_pinned_daemon(restart=...)` is the only canonical daemon bootstrap/restart operation. It uses the installed PM2 `7.0.4` package with deterministic trusted Node/PATH and a sanitized bridge environment. Existing `dump.pm2` bytes are preserved, and the operation returns daemon evidence only; it never claims application authority.

Failed managed starts retain at most five bounded, structured, redacted `0600` diagnostic records under a dedicated `0700` directory inside `PM2_HOME`. Raw stdout/stderr files are removed, successful-start files are unlinked, and diagnostics never contain known secret variants or live inside release/secret paths.

Persisted `adapterReceipt` values are correlation evidence, not authentication. Restart recovery performs a full live inventory, matches exact PM2 and `/proc` identity plus runtime fingerprint and release SHA, and mints a new observed handle. It fails closed on any ambiguous or modified authority field.

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
| Persisted handle tampering | Receipt-only changes are discarded and reminted from live evidence; PM2 ID, PID/start identity, runtime, fingerprint, and SHA mismatches fail closed. |
| Secret source substitution | Symlink, non-regular, wrong-owner, and unsafe-mode sources fail before value reads and PM2 mutation. |
| Runtime dependency drift | Loaded PM2 and Node versions are self-attested; a PM2 version other than the pinned build dependency fails before daemon connection. |
| Connected daemon drift after reboot | Fresh Linux `/proc` evidence rejects a non-7.0.4 daemon, mismatched Node runtime, stale PID/start identity, or forbidden ambient IPC variables before managed start/recover/activate. |
| Failed managed child had no retained error | Per-launch raw logs are strictly permissioned, redacted and bounded into a small retained diagnostic record after exact residual cleanup. |
