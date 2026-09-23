#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/demo-safe.sh
source "$SCRIPT_DIR/../scripts/demo-safe.sh"

ROOT="$(mktemp -d -t demo-safe-failure-XXXXXX)"
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
RELEASE_ROOT="$ROOT/releases-root"
CURRENT_LINK="$RELEASE_ROOT/current"
PREVIOUS_LINK="$RELEASE_ROOT/previous"
mkdir -p "$RELEASE_ROOT" "$PROC_ROOT/4242"

make_release() {
  local dir="$1" label="$2"
  mkdir -p "$dir/$APP_SUBDIR" "$dir/.deployment"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name test
  printf '%s\n' "$label" > "$dir/fixture.txt"
  git -C "$dir" add fixture.txt
  git -C "$dir" commit -qm fixture
  local sha
  sha="$(git -C "$dir" rev-parse HEAD)"
  printf '%s\n' "$sha" > "$dir/.release-sha"
  touch "$dir/.build-verified"
  printf 'module.exports = {}\n' > "$dir/.deployment/ecosystem.cjs"
  printf '%s\n' "$sha"
}

KNOWN="$ROOT/known-good"
CANDIDATE="$ROOT/candidate"
PRIOR="$ROOT/prior-verified"
KNOWN_SHA="$(make_release "$KNOWN" known-good)"
CANDIDATE_SHA="$(make_release "$CANDIDATE" unhealthy-candidate)"
make_release "$PRIOR" prior-verified >/dev/null
KNOWN="$(cd "$KNOWN" && pwd -P)"
CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"
PRIOR="$(cd "$PRIOR" && pwd -P)"
touch "$KNOWN/.runtime-verified" "$PRIOR/.runtime-verified"
ln -s "$KNOWN" "$CURRENT_LINK"
ln -s "$PRIOR" "$PREVIOUS_LINK"
ln -s "$KNOWN/$APP_SUBDIR" "$PROC_ROOT/4242/cwd"
LOG="$ROOT/pm2.log"
eval "$(declare -f attest_live_process | sed '1s/attest_live_process/original_attest_live_process/')"
ATTESTED_SHA=""
attest_live_process() {
  original_attest_live_process "$@" || return 1
  ATTESTED_SHA="$2"
}

pm2() {
  case "$1" in
    pid) printf '4242\n' ;;
    delete) rm -f "$PROC_ROOT/4242/cwd" ;;
    start)
      local release="${2%/.deployment/ecosystem.cjs}"
      ln -sfn "$release/$APP_SUBDIR" "$PROC_ROOT/4242/cwd"
      printf 'start:%s\n' "$(cat "$release/.release-sha")" >> "$LOG"
      ;;
    save)
      local live
      live="$(live_release)"
      [ "$(cat "$live/.release-sha")" = "$ATTESTED_SHA" ] || {
        echo "FAIL: pm2 save occurred before live SHA attestation" >&2
        return 1
      }
      printf 'save:%s\n' "$(cat "$live/.release-sha")" >> "$LOG"
      ;;
    *) return 1 ;;
  esac
}

curl() {
  local live
  live="$(live_release 2>/dev/null || true)"
  if [ "$live" = "$CANDIDATE" ]; then printf '500'; else printf '200'; fi
}

secret_metadata_ok() { return 0; }

if activate_candidate "$CANDIDATE" "$CANDIDATE_SHA" "$KNOWN" "$KNOWN_SHA"; then
  echo "FAIL: unhealthy candidate unexpectedly activated" >&2
  exit 1
fi

[ "$(live_release)" = "$KNOWN" ]
[ "$(readlink -f "$CURRENT_LINK")" = "$KNOWN" ]
[ "$(readlink -f "$PREVIOUS_LINK")" = "$PRIOR" ]
[ ! -e "$CANDIDATE/.runtime-verified" ]
[ "$(grep -c '^save:' "$LOG")" = "1" ]
grep -qx "save:$KNOWN_SHA" "$LOG"
! grep -q "save:$CANDIDATE_SHA" "$LOG"
[ "$(sed -n '1p' "$LOG")" = "start:$CANDIDATE_SHA" ]
[ "$(sed -n '2p' "$LOG")" = "start:$KNOWN_SHA" ]
[ "$(sed -n '3p' "$LOG")" = "save:$KNOWN_SHA" ]

: > "$LOG"
ATTESTED_SHA=""
rm -f "$PROC_ROOT/4242/cwd" "$CANDIDATE/.runtime-verified"
ln -s "$KNOWN/$APP_SUBDIR" "$PROC_ROOT/4242/cwd"
ln -sfn "$KNOWN" "$CURRENT_LINK"
ln -sfn "$PRIOR" "$PREVIOUS_LINK"
curl() { printf '200'; }
activate_candidate "$CANDIDATE" "$CANDIDATE_SHA" "$KNOWN" "$KNOWN_SHA" >/dev/null
[ "$(live_release)" = "$CANDIDATE" ]
[ "$(readlink -f "$CURRENT_LINK")" = "$CANDIDATE" ]
[ "$(readlink -f "$PREVIOUS_LINK")" = "$KNOWN" ]
[ -f "$CANDIDATE/.runtime-verified" ]
[ "$(grep -c '^save:' "$LOG")" = "1" ]
grep -qx "save:$CANDIDATE_SHA" "$LOG"

BUILD="$ROOT/build"
make_release "$BUILD" build-fixture >/dev/null
printf 'allowed\n' > "$BUILD/allowed.txt"
printf 'unexpected\n' > "$BUILD/unexpected.txt"
git -C "$BUILD" add allowed.txt unexpected.txt
git -C "$BUILD" commit -qm tracked
BUILD_SHA="$(git -C "$BUILD" rev-parse HEAD)"
printf 'changed\n' > "$BUILD/allowed.txt"
printf 'changed\n' > "$BUILD/unexpected.txt"
BUILD_ALLOWED_TRACKED="allowed.txt"
if clean_allowed_build_changes "$BUILD" >/dev/null 2>&1; then
  echo "FAIL: unexpected tracked build mutation was accepted" >&2
  exit 1
fi
git -C "$BUILD" checkout -- .
printf 'changed\n' > "$BUILD/allowed.txt"
clean_allowed_build_changes "$BUILD" >/dev/null
[ -z "$(git -C "$BUILD" status --porcelain --untracked-files=no)" ]
[ "$(git -C "$BUILD" rev-parse HEAD)" = "$BUILD_SHA" ]

echo "failure_injection=PASS restored_running_sha=$KNOWN_SHA"
echo "failed_candidate_rollback_target=REJECTED"
echo "pm2_save_order=PASS verified_known_good_only"
echo "successful_activation_order=PASS attest_before_pm2_save"
echo "build_mutation_allowlist=PASS"
