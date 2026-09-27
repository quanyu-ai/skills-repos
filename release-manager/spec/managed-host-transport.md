# Managed host transport

This transport is a forced-command gateway to the existing canonical
`ReleaseEngine`; it is not a second release engine. The caller can submit only
`environment`, `application`, a 40-character lower-case Git SHA, and
`mode=preflight|deploy|attest|source-publication`. Policy, State Store, lock, PM2, UID, secret
source and rollback authority are resolved solely from root-owned host
registries. Unknown fields and non-unique bindings fail closed.

The fixed Demo client uses host `8.138.118.28`, service account
`release-runner`, identity `/Users/Cloud/.ssh/deploy_local` and dedicated
known-hosts file `/Users/Cloud/.ssh/release_demo_known_hosts`. Both files must
be regular, non-symlink, caller-owned files with mode `0600`. SSH is invoked in
batch mode with strict host-key checking, identities-only, no TTY and all
forwarding cleared. It always requests the literal command `release-runner`.
The client also requires `/Users/Cloud/.ssh/release_demo_authority.json` at
mode `0600`, containing the post-merge canonical SHA, complete install-tree
digest, gateway digest and canonical operator entrypoint digest from durable
capability evidence.

The corresponding `authorized_keys` entry must be installed by a trusted host
administrator with all of these restrictions:

```text
restrict,command="/usr/bin/sudo -n -u openclaw -- /usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 /opt/quanyu/release-manager/runtime/python3.12 -I -B /opt/quanyu/release-manager/current/transport/gateway.py",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding <PUBLIC-KEY-INSTALLED-OUT-OF-BAND>
```

The `release-runner` home and Python user-site must not be writable by the
service identity. `/opt/quanyu/release-manager/runtime/python3.12` must be a
root-owned, non-symlink Python 3.12 executable whose parent chain is not
group/other-writable. The absolute isolated interpreter command above is part
of the contract; invoking the gateway through its `/usr/bin/env python3`
shebang is not an accepted host installation. The canonical operator
entrypoint uses the same absolute interpreter in its shebang and is installed
executable so the gateway can open, hash and execute one measured file
descriptor.

The service identity cannot safely inspect the separately owned managed
process through Linux `/proc`. A root-owned `0440` sudoers fragment must allow
`release-runner` to run as `openclaw` only the exact `/usr/bin/env -i ...`
gateway vector shown above, with `NOPASSWD`; no wildcard, shell, alternate
argument, interpreter, environment or command is allowed. The forced command
must include `sudo -n` so a policy mismatch fails closed without a password
prompt. The gateway still selects only root-owned measured operator vectors,
and host authority keeps deploy disabled independently.

The pre-Transport Operator SHA
`e0ccf99ddc3b33d881d8942ae86602d7c96883e8` is historical base evidence only
and must never be installed or attested as the Managed Host Transport version.

The host transport registry is
`/etc/quanyu/release-manager/transport-registry.v1.json`. It binds the one Demo
environment/application pair to an installation manifest containing the exact
post-merge Transport-capable source SHA from durable evidence, a complete installation-tree
digest and per-entrypoint digests, and to three absolute command vectors.
The gateway opens and hashes the entrypoint once, then executes that same file
descriptor on Linux; registries, manifests, the entire install tree and their
parent chain must be root-owned and non-writable by group/other. Commands are
executed only from owner-executable files. The schema validator is opened and
hashed under the same root-owner and no-write checks, but remains a non-executable
data/code file. Root-owned registries and manifests contain no secrets and must
be readable, but never writable, by the service identity. Commands are
executed without a shell. `preflight` and `attest` map
to the canonical read-only operator. `deploy` is disabled unless its registered
vector points to the canonical ReleaseEngine writer and the root-owned binding
contains an `exact-deploy-authority/v1` object. That authority binds one Owner
approval identifier to the registered environment, application, repository and
one lowercase 40-character SHA. A boolean switch, missing field, additional
field, scope mismatch or requested-SHA mismatch fails before the operator is
executed. The caller envelope has no approval or authority field and therefore
cannot widen or replace this binding. After the approved deployment, the host
administrator removes the authority while installing the next measured
registry; until then it remains replayable only for the same exact scope and
SHA, never for an arbitrary candidate.

The registered `deploy` operation enters `ReleaseEngine.activate`; it does not
reimplement release transitions in the transport. Its host runtime acquires
the exact commit only from the registered local mirror, checks out a detached
worktree without a shell, and runs frozen install and typed lifecycle actions
through fixed argv subprocesses. Package scripts use the contract's exact
`packageManager` version through a registry-bound absolute Node executable,
Corepack program, Corepack cache directory and toolchain binary directory. The
runner invokes the top-level toolchain by absolute paths and prepends only the
validated toolchain directory to the sanitized child PATH, allowing workspace
task shims to resolve the same Node and Corepack. Raw lifecycle executable
resolution retains the narrower trusted PATH. The runner never invokes a shell.
The registry also binds the sole
synthetic `DATABASE_URL` accepted for the typed `db:generate` prepare action:
an unauthenticated loopback port 1 URL that cannot reach the runtime database.
The runner injects it only for Prisma client generation, never for install,
build, verify, or runtime. That action remains in Turbo strict environment mode
and receives the fixed `--global-env=DATABASE_URL` argument after the package
manager's `--` argument boundary, so only this one
synthetic value crosses Turbo's task boundary; arbitrary ambient variables stay
filtered. Repository identity, policy,
contract, State Store, lock, release root, PM2 adapter and secret source remain
host-registry or policy bound. Any source, toolchain, build, runtime or adapter
failure returns a redacted schema-valid `FAIL_CLOSED` deploy result.

`source-publication` is a one-commit infrastructure repair, not a generic
fetch surface. It is frozen to `smart-college-demo` / `smart-college-web`, the
registered `quanyu-ai/proj-code-smart-college` mirror, merged PR #29, commit
`06c5d26c54b3dbce528766eb3fcf44b72432efbf` and tree
`abe957be9dcf979e420eab018a2720ffd636177c`. The operator first verifies the
frozen GitHub PR evidence (repository identity, base `main`, merged state/time,
merge commit, parent, tree and subject), then fetches only the frozen commit
from the fixed canonical Git SSH URL. The root-owned operator registry supplies
the only accepted identity and known-hosts paths; the identity must be an
operator-owned `0400` regular file and known-hosts a trusted-owner `0444`
regular file. Git and SSH run non-interactively with a fixed command, strict
host-key checking, identities-only, no TTY, no forwarding, no proxy and no
caller override. The operator verifies the commit object in a temporary bare quarantine,
imports it into the existing mirror under a temporary ref, and atomically
creates an immutable publication ref while deleting the temporary ref. It
never checks out a worktree, invokes deployment, writes State Store, or calls
PM2, a database, or a secret provider. Its receipt proves State Store
immutability and whether the exact publication was already present.

The gateway discards operator stderr, requires JSON stdout, and returns only a
versioned evidence envelope, request digest, installed operator SHA, mode,
exit code and canonical operator result. It has no raw command, shell, legacy
deploy, manual PM2 or path-override surface.
