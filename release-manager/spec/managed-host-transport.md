# Managed host transport

This transport is a forced-command gateway to the existing canonical
`ReleaseEngine`; it is not a second release engine. The caller can submit only
`environment`, `application`, a 40-character lower-case Git SHA, and
`mode=preflight|deploy|attest`. Policy, State Store, lock, PM2, UID, secret
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
restrict,command="/usr/bin/env -i PATH=/usr/bin:/bin LANG=C.UTF-8 /usr/bin/python3 -I -B /opt/quanyu/release-manager/current/transport/gateway.py",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding <PUBLIC-KEY-INSTALLED-OUT-OF-BAND>
```

The `release-runner` home and Python user-site must not be writable by the
service identity. The absolute isolated interpreter command above is part of
the contract; invoking the gateway through its `/usr/bin/env python3` shebang
is not an accepted host installation.

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
executed without a shell. `preflight` and `attest` map
to the canonical read-only operator. `deploy` is disabled until its registered
vector points to the canonical ReleaseEngine writer and `allowDeploy` is
separately enabled; this bootstrap task must leave it disabled.

The gateway discards operator stderr, requires JSON stdout, and returns only a
versioned evidence envelope, request digest, installed operator SHA, mode,
exit code and canonical operator result. It has no raw command, shell, legacy
deploy, manual PM2 or path-override surface.
