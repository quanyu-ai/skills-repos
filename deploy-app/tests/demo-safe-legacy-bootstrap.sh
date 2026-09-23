#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/demo-safe.sh
source "$SCRIPT_DIR/../scripts/demo-safe.sh"

ROOT="$(mktemp -d -t demo-safe-legacy-bootstrap-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
export DEMO_SAFE_PROC_ROOT="$ROOT/proc"
PROC_ROOT="$DEMO_SAFE_PROC_ROOT"
export DEMO_SAFE_HEALTH_ATTEMPTS=1 DEMO_SAFE_HEALTH_SLEEP=0

APP_SUBDIR="apps/web"
PM2_NAME="demo-test"
INTERNAL_PORT=3104
PUBLIC_PORT=3204
PUBLIC_HOST=127.0.0.1
HEALTH_PATH=/health
DIST_DIR=.next-demo
RELEASE_ROOT="$ROOT/releases-root"
RELEASES_DIR="$RELEASE_ROOT/releases"
CURRENT_LINK="$RELEASE_ROOT/current"
PREVIOUS_LINK="$RELEASE_ROOT/previous"
mkdir -p "$RELEASES_DIR" "$PROC_ROOT/4242"

make_git_release() {
  local dir="$1" label="$2"
  mkdir -p "$dir/$APP_SUBDIR"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
  printf '%s\n' "$label" > "$dir/fixture.txt"
  git -C "$dir" add fixture.txt
  git -C "$dir" commit -qm fixture
}

LEGACY="$ROOT/legacy"
CANDIDATE="$ROOT/candidate"
NEXT="$ROOT/next-canonical"
make_git_release "$LEGACY" legacy
make_git_release "$CANDIDATE" candidate
make_git_release "$NEXT" next
LEGACY_SHA="$(git -C "$LEGACY" rev-parse HEAD)"
CANDIDATE_SHA="$(git -C "$CANDIDATE" rev-parse HEAD)"
NEXT_SHA="$(git -C "$NEXT" rev-parse HEAD)"
LEGACY_RELEASE="$(cd "$LEGACY" && pwd -P)"
LEGACY_CWD="$LEGACY_RELEASE/$APP_SUBDIR"
LEGACY_EXECUTABLE="$LEGACY_CWD/node_modules/next/dist/bin/next"
LEGACY_ARGS_JSON='["start"]'
LEGACY_HOST=127.0.0.1
LEGACY_INTERNAL_PORT="$INTERNAL_PORT"
LEGACY_PROBE_PORT=3114
LEGACY_DIST_DIR=.next-demo
LEGACY_SECRET_FILE="$ROOT/secrets.json"
LEGACY_REQUIRED_SECRETS=DATABASE_URL,JWT_ACCESS_SECRET,JWT_REFRESH_SECRET,SYNC_OUTBOX_TOKEN
LEGACY_SAFE_ENV_JSON='{"NODE_ENV":"production","DEPLOY_ENV":"demo","HOST":"127.0.0.1","PORT":"3104"}'
REQUIRED_SECRETS="$LEGACY_REQUIRED_SECRETS"
SECRET_FILE="$LEGACY_SECRET_FILE"
BOOTSTRAP_ALLOWED_GENERATED=""
BUILD_ALLOWED_TRACKED=""

mkdir -p "$(dirname "$LEGACY_EXECUTABLE")" "$LEGACY_CWD/$LEGACY_DIST_DIR"
cat > "$LEGACY_EXECUTABLE" <<'JS'
const http = require('node:http');
const port = Number(process.argv[process.argv.indexOf('-p') + 1]);
const server = http.createServer((req, res) => { res.statusCode = 200; res.end('ok'); });
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => server.close(() => process.exit(0)));
JS
chmod 755 "$LEGACY_EXECUTABLE"
printf 'legacy-build\n' > "$LEGACY_CWD/$LEGACY_DIST_DIR/BUILD_ID"
printf '{"DATABASE_URL":"test","JWT_ACCESS_SECRET":"test","JWT_REFRESH_SECRET":"test","SYNC_OUTBOX_TOKEN":"test"}\n' > "$LEGACY_SECRET_FILE"
chmod 600 "$LEGACY_SECRET_FILE"

for release in "$CANDIDATE" "$NEXT"; do
  sha="$(git -C "$release" rev-parse HEAD)"
  printf '%s\n' "$sha" > "$release/.release-sha"
  touch "$release/.build-verified"
done
write_runtime_files "$CANDIDATE"
write_runtime_files "$NEXT"
node --check "$CANDIDATE/.deployment/ecosystem.cjs" >/dev/null
node --check "$NEXT/.deployment/ecosystem.cjs" >/dev/null
[ ! -e "$LEGACY/.deployment" ]
CANDIDATE_RUNTIME_HASH="$(sha256sum "$CANDIDATE/.deployment/ecosystem.cjs" | cut -d ' ' -f1)"
grep -Fq "$CANDIDATE" "$CANDIDATE/.deployment/ecosystem.cjs"

ln -s "$LEGACY_CWD" "$PROC_ROOT/4242/cwd"
LOG="$ROOT/pm2.log"
ATTESTED_SHA=""
FORCE_CANDIDATE_FAILURE=true

eval "$(declare -f attest_live_process | sed '1s/attest_live_process/original_attest_live_process/')"
attest_live_process() {
  original_attest_live_process "$@" || return 1
  ATTESTED_SHA="$2"
}
eval "$(declare -f attest_legacy_live_process | sed '1s/attest_legacy_live_process/original_attest_legacy_live_process/')"
attest_legacy_live_process() {
  original_attest_legacy_live_process "$@" || return 1
  ATTESTED_SHA="$LEGACY_SHA"
}

pm2() {
  case "$1" in
    pid) printf '4242\n' ;;
    delete) rm -f "$PROC_ROOT/4242/cwd" ;;
    start)
      if [ "$(basename "$2")" = "legacy-bootstrap-start.cjs" ]; then
        ln -sfn "$LEGACY_CWD" "$PROC_ROOT/4242/cwd"
        printf 'start:legacy:%s\n' "$LEGACY_SHA" >> "$LOG"
      else
        local release="${2%/.deployment/ecosystem.cjs}"
        ln -sfn "$release/$APP_SUBDIR" "$PROC_ROOT/4242/cwd"
        printf 'start:canonical:%s\n' "$(cat "$release/.release-sha")" >> "$LOG"
      fi
      ;;
    save)
      local live
      live="$(live_release)"
      [ "$(git -C "$live" rev-parse HEAD)" = "$ATTESTED_SHA" ] || {
        echo "FAIL: pm2 save occurred before exact live SHA attestation" >&2
        return 1
      }
      printf 'save:%s\n' "$ATTESTED_SHA" >> "$LOG"
      ;;
    describe) return 0 ;;
    *) return 1 ;;
  esac
}

curl() {
  local live
  live="$(live_release 2>/dev/null || true)"
  if [ "$FORCE_CANDIDATE_FAILURE" = true ] && [ "$live" = "$(cd "$CANDIDATE" && pwd -P)" ]; then printf '500'; else printf '200'; fi
}
secret_metadata_ok() { return 0; }

check_legacy_bootstrap_live >/dev/null
[ "$(sha256sum "$CANDIDATE/.deployment/ecosystem.cjs" | cut -d ' ' -f1)" = "$CANDIDATE_RUNTIME_HASH" ]
[ ! -e "$LEGACY/.deployment" ]

if activate_first_candidate "$CANDIDATE" "$CANDIDATE_SHA"; then
  echo "FAIL: unhealthy first-cutover candidate unexpectedly activated" >&2
  exit 1
fi
[ "$(live_release)" = "$(cd "$LEGACY" && pwd -P)" ]
[ ! -e "$CURRENT_LINK" ]
[ ! -e "$PREVIOUS_LINK" ]
[ ! -e "$CANDIDATE/.runtime-verified" ]
[ ! -e "$LEGACY/.deployment" ]
[ "$(grep -c '^save:' "$LOG")" = 1 ]
grep -qx "save:$LEGACY_SHA" "$LOG"
! grep -q "save:$CANDIDATE_SHA" "$LOG"

: > "$LOG"; ATTESTED_SHA=""; FORCE_CANDIDATE_FAILURE=false
activate_first_candidate "$CANDIDATE" "$CANDIDATE_SHA" >/dev/null
[ "$(live_release)" = "$(cd "$CANDIDATE" && pwd -P)" ]
[ "$(readlink -f "$CURRENT_LINK")" = "$(cd "$CANDIDATE" && pwd -P)" ]
[ ! -e "$PREVIOUS_LINK" ]
[ -f "$CANDIDATE/.runtime-verified" ]
[ ! -e "$LEGACY/.deployment" ]
grep -qx "save:$CANDIDATE_SHA" "$LOG"

: > "$LOG"; ATTESTED_SHA=""
activate_candidate "$NEXT" "$NEXT_SHA" "$CANDIDATE" "$CANDIDATE_SHA" >/dev/null
[ "$(live_release)" = "$(cd "$NEXT" && pwd -P)" ]
[ "$(readlink -f "$CURRENT_LINK")" = "$(cd "$NEXT" && pwd -P)" ]
[ "$(readlink -f "$PREVIOUS_LINK")" = "$(cd "$CANDIDATE" && pwd -P)" ]
[ -f "$NEXT/.runtime-verified" ]
grep -qx "save:$NEXT_SHA" "$LOG"

! grep -Eq 'local[[:space:]]+release=.*\$release' "$SCRIPT_DIR/../scripts/demo-safe.sh"
echo "dependent_local_regression=PASS"
echo "legacy_release_canonical_files=ABSENT"
echo "candidate_runtime_files=UNCHANGED"
echo "legacy_first_cutover_failure_restore=PASS running_sha=$LEGACY_SHA"
echo "failed_candidate_rollback_target=REJECTED"
echo "legacy_restore_save_order=PASS attestation_before_save"
echo "first_success_transition=PASS canonical_current=$CANDIDATE_SHA"
echo "canonical_followup_rollback_metadata=PASS previous=$CANDIDATE_SHA"
