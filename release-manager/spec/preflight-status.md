# Read-only preflight-status Operator

`release-manager preflight-status` is the sole Control Tower-facing read operation. The caller can supply only `environmentId`, `serviceId`, expected repository identity and an optional exact candidate commit SHA. Host paths, PM2 identity, service UID, source mirror and freshness limit are resolved from the root-owned `/etc/quanyu/release-manager/operator-registry.v1.json`.

The operation opens the pre-existing writer lock with `O_RDONLY|O_NOFOLLOW`, takes `LOCK_SH`, reads regular non-symlink authority files through file descriptors, validates their schemas and canonical digests, and rejects drift between path, descriptor and final metadata. It never invokes `AtomicStateStore.locked()` because that API may create a lock directory/file.

The current live process is selected by the complete environment/service/namespace scope, then re-observed through its exact persisted ProcessHandle. PM2 adapter ID, PID, Linux boot/start identity, executable, argv, cwd, listener, SHA and configuration digests must all agree. The adapter performs fresh internal and public HTTP health reads. Previous authority is never started: its immutable release, runtime payload, required artifacts, Handle and declared restorable state are verified in place.

Candidate reachability uses a fixed argument vector for `git cat-file -e <sha>^{commit}` against the registered local source mirror. The operator does not fetch, update refs, invoke a shell or accept a repository path.

Successful output validates against `schemas/preflight-status.schema.json`. Only allowlisted identity fields and digests are emitted. Environment values, secret values, secret paths, connection strings, PM2 dumps and raw process environments are excluded. Failures return only `PREFLIGHT_AUTHORITY_UNPROVEN`; detailed exceptions are not printed.

## Control Tower contract

```text
release-manager preflight-status \
  --environment-id demo \
  --service-id smart-college \
  --expected-repository quanyu-ai/proj-code-smart-college \
  [--expected-candidate-sha <40-lowercase-hex>]
```

Exit `0` plus `decision=PASS` is usable evidence for the same observation instant. Exit `2` is fail-closed and cannot authorize deployment or no-deploy acceptance.

## Runbook and rollback

Install only after an approved host-change package names the exact source SHA, target host/service and root-owned registry values. Validate registry ownership/mode, run once without a candidate and once with a known mirror commit, validate JSON against the versioned schema, and compare State Store plus PM2 state before/after.

Rollback is removal of the operator entry point and registry entry only. It must not alter State Store, release directories, PM2 processes, PM2 dump, application configuration, database, IAM or secrets. If any authority check fails, leave runtime untouched, retain the failure code, and repair the authoritative writer/deployment workflow under a separate approval.

## Known authority-model limitation

The v1alpha1 State Store now records the build-time required-artifact manifest digest on each newly minted managed authority; the Operator requires and rechecks it for both current and previous. Older authorities without this field fail closed and need a separately approved managed release cycle before this Operator can return PASS. State records still have no external signature/integrity anchor, so the Operator cannot prove cryptographic resistance to a privileged actor rewriting every root-owned authority file consistently. Adding signed records is a separate contract change.
