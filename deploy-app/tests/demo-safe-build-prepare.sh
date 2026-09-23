#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../scripts/demo-safe.sh
source "$SCRIPT_DIR/../scripts/demo-safe.sh"

ROOT="$(mktemp -d -t demo-safe-build-prepare-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
REPO="$ROOT/repo"
LOG="$ROOT/order.log"
mkdir -p "$REPO/packages/db"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
cat > "$REPO/package.json" <<'JSON'
{
  "packageManager": "pnpm@9.15.4",
  "scripts": {
    "db:generate": "turbo run db:generate",
    "build": "turbo run build"
  }
}
JSON
cat > "$REPO/packages/db/package.json" <<'JSON'
{
  "scripts": {
    "db:generate": "prisma generate"
  }
}
JSON
git -C "$REPO" add package.json packages/db/package.json
git -C "$REPO" commit -qm fixture

BUILD_PREPARE_SCRIPT="db:generate"
BUILD_PREPARE_OUTPUTS="packages/db/prisma/generated"
BUILD_ALLOWED_TRACKED=""
DIST_DIR=".next-demo"
check_build_prepare_contract "$REPO" >/dev/null

cp "$REPO/packages/db/package.json" "$ROOT/db-package.json"
jq '.scripts["db:generate"] = "prisma migrate deploy"' "$REPO/packages/db/package.json" > "$REPO/packages/db/package.json.tmp"
mv "$REPO/packages/db/package.json.tmp" "$REPO/packages/db/package.json"
if check_build_prepare_contract "$REPO" >/dev/null 2>&1; then
  echo "FAIL: mutating preparation command was accepted" >&2
  exit 1
fi
cp "$ROOT/db-package.json" "$REPO/packages/db/package.json"

run_sanitized_pnpm() {
  local release="$1"; shift
  printf '%s\n' "$*" >> "$LOG"
}
run_sanitized_build_prepare() {
  local release="$1"
  printf 'db:generate\n' >> "$LOG"
  mkdir -p "$release/packages/db/prisma/generated"
  printf 'generated\n' > "$release/packages/db/prisma/generated/index.js"
}

run_repository_build "$REPO"
[ "$(sed -n '1p' "$LOG")" = "install --frozen-lockfile" ]
[ "$(sed -n '2p' "$LOG")" = "db:generate" ]
[ "$(sed -n '3p' "$LOG")" = "build" ]

: > "$LOG"
rm -rf "$REPO/packages/db/prisma/generated"
ACTIVATED="$ROOT/activated"
run_sanitized_pnpm() {
  local _release="$1"; shift
  printf '%s\n' "$*" >> "$LOG"
}
run_sanitized_build_prepare() {
  printf 'db:generate\n' >> "$LOG"
  return 1
}
build_release() { run_repository_build "$REPO"; }
activate_candidate() { touch "$ACTIVATED"; }
PREVIOUS_LINK="$ROOT/previous"
VERSION="$(git -C "$REPO" rev-parse HEAD)"
if deploy_candidate_release "$ROOT/final-release" "$ROOT/building-release"; then
  echo "FAIL: generation failure unexpectedly completed deployment" >&2
  exit 1
fi
[ ! -e "$ACTIVATED" ]
[ ! -e "$ROOT/final-release" ]
[ "$(sed -n '1p' "$LOG")" = "install --frozen-lockfile" ]
[ "$(sed -n '2p' "$LOG")" = "db:generate" ]
[ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ]

echo "generation_before_build=PASS"
echo "generation_failure_no_build=PASS"
echo "generation_failure_no_activation=PASS"
echo "mutating_prepare_command=REJECTED"
