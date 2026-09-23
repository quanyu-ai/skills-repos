#!/usr/bin/env bash
# Deterministic, external-secret Demo release path.
# Usage: demo-safe.sh <doctor|preflight|dry-run|deploy|rollback> <app> --version <40-char-sha> [--config file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/../config/demo-safe.json"
ACTION="${1:-}"; APP="${2:-}"; shift 2 2>/dev/null || true
VERSION=""; CONFIG="$DEFAULT_CONFIG"; ROLLBACK_SHA=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --target-sha) ROLLBACK_SHA="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ACTION" in doctor|preflight|dry-run|deploy|rollback) ;; *) echo "Usage: $(basename "$0") <doctor|preflight|dry-run|deploy|rollback> <app> --version <sha> [--config file]" >&2; exit 2;; esac
[ -n "$APP" ] || { echo "ERROR: app is required" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "ERROR: config missing: $CONFIG" >&2; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq missing" >&2; exit 1; }
jq -e . "$CONFIG" >/dev/null || { echo "ERROR: invalid JSON config" >&2; exit 1; }

cfg() { jq -er --arg a "$APP" ".apps[\$a].$1" "$CONFIG"; }
REPO_URL="$(cfg repo_url)"
RELEASE_ROOT="$(cfg release_root)"
APP_SUBDIR="$(cfg app_subdir)"
PM2_NAME="$(cfg pm2_name)"
SECRET_FILE="$(cfg secret_file)"
PUBLIC_PORT="$(cfg public_port)"
INTERNAL_PORT="$(cfg internal_port)"
PUBLIC_HOST="$(cfg public_host)"
HEALTH_PATH="$(cfg health_path)"
NGINX_CONFIG="$(cfg nginx_config)"
DIST_DIR="$(jq -r --arg a "$APP" '.apps[$a].next_dist_dir // ".next"' "$CONFIG")"
LOCK_DIR="$(jq -r --arg a "$APP" '.apps[$a].lock_dir // "/var/lib/openclaw/deploy-locks"' "$CONFIG")"
REQUIRED_SECRETS="$(jq -er --arg a "$APP" '.apps[$a].required_runtime_secrets | join(",")' "$CONFIG")"
BOOTSTRAP_RELEASE="$(jq -r --arg a "$APP" '.apps[$a].bootstrap_rollback_release // empty' "$CONFIG")"
BOOTSTRAP_SHA="$(jq -r --arg a "$APP" '.apps[$a].bootstrap_rollback_sha // empty' "$CONFIG")"
BOOTSTRAP_ALLOWED_GENERATED="$(jq -r --arg a "$APP" '.apps[$a].bootstrap_allowed_generated_changes // [] | join(",")' "$CONFIG")"
RELEASES_DIR="$RELEASE_ROOT/releases"; CURRENT_LINK="$RELEASE_ROOT/current"; PREVIOUS_LINK="$RELEASE_ROOT/previous"

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
secret_metadata_ok() {
  [ -f "$SECRET_FILE" ] || { echo "ERROR: external secret file missing" >&2; return 1; }
  local mode owner
  mode="$(stat -c '%a' "$SECRET_FILE")"; owner="$(stat -c '%U' "$SECRET_FILE")"
  [ "$mode" = "600" ] || { echo "ERROR: external secret file mode must be 600 (actual=$mode)" >&2; return 1; }
  [ "$owner" = "$(id -un)" ] || { echo "ERROR: external secret file owner mismatch (actual=$owner expected=$(id -un))" >&2; return 1; }
  IFS=',' read -r -a names <<< "$REQUIRED_SECRETS"
  local name
  for name in "${names[@]}"; do
    jq -e --arg n "$name" '.[$n] | type == "string" and length > 0' "$SECRET_FILE" >/dev/null \
      || { echo "ERROR: required runtime secret missing or empty: $name" >&2; return 1; }
  done
  echo "secret_source=PASS names=$REQUIRED_SECRETS"
}
check_topology() {
  [ "$PUBLIC_PORT" != "$INTERNAL_PORT" ] || { echo "ERROR: public and internal ports must differ" >&2; return 1; }
  [ -f "$NGINX_CONFIG" ] || { echo "ERROR: nginx config missing: $NGINX_CONFIG" >&2; return 1; }
  grep -Eq "listen[[:space:]]+${PUBLIC_PORT}([[:space:];]|$)" "$NGINX_CONFIG" \
    || { echo "ERROR: nginx public port mismatch" >&2; return 1; }
  grep -Eq "proxy_pass[[:space:]]+http://127\\.0\\.0\\.1:${INTERNAL_PORT}([/;]|$)" "$NGINX_CONFIG" \
    || { echo "ERROR: nginx internal port mismatch" >&2; return 1; }
  echo "port_topology=PASS public=$PUBLIC_PORT internal=$INTERNAL_PORT"
}
check_db() {
  command -v psql >/dev/null || { echo "ERROR: psql missing" >&2; return 1; }
  local url
  url="$(jq -er '.DATABASE_URL' "$SECRET_FILE")"; url="${url%%\?schema=*}"
  psql "$url" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' >/dev/null
  echo "db_connectivity=PASS"
}
checkout_for_preflight() {
  local dst="$1"
  git init -q "$dst"
  git -C "$dst" remote add origin "$REPO_URL"
  git -C "$dst" fetch -q --depth=1 origin "$VERSION"
  git -C "$dst" checkout -q --detach FETCH_HEAD
  local actual
  actual="$(git -C "$dst" rev-parse HEAD)"
  [ "$actual" = "$VERSION" ] || { echo "ERROR: fetched SHA mismatch" >&2; return 1; }
  [ -z "$(git -C "$dst" status --porcelain)" ] || { echo "ERROR: preflight checkout is dirty" >&2; return 1; }
}
check_bootstrap_rollback() {
  if [ -z "$BOOTSTRAP_RELEASE" ] || [ -z "$BOOTSTRAP_SHA" ]; then
    echo "ERROR: bootstrap rollback release and SHA are required for the first managed cutover" >&2
    return 1
  fi
  is_sha "$BOOTSTRAP_SHA" || { echo "ERROR: invalid bootstrap rollback SHA" >&2; return 1; }
  [ -d "$BOOTSTRAP_RELEASE" ] || { echo "ERROR: bootstrap rollback release missing" >&2; return 1; }
  [ "$(git -C "$BOOTSTRAP_RELEASE" rev-parse HEAD)" = "$BOOTSTRAP_SHA" ] \
    || { echo "ERROR: bootstrap rollback SHA mismatch" >&2; return 1; }
  [ -d "$BOOTSTRAP_RELEASE/$APP_SUBDIR/$DIST_DIR" ] \
    || { echo "ERROR: bootstrap rollback build artifact missing" >&2; return 1; }
  local dirty path allowed
  dirty="$(git -C "$BOOTSTRAP_RELEASE" status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    while IFS= read -r line; do
      path="${line:3}"; allowed="false"
      IFS=',' read -r -a generated <<< "$BOOTSTRAP_ALLOWED_GENERATED"
      local candidate
      for candidate in "${generated[@]}"; do [ "$path" = "$candidate" ] && allowed="true"; done
      [ "$allowed" = "true" ] || { echo "ERROR: unexpected tracked change in bootstrap rollback release: $path" >&2; return 1; }
      echo "rollback_generated_change=ALLOWED path=$path"
    done <<< "$dirty"
  fi
  local pid cwd
  pid="$(pm2 pid "$PM2_NAME")"; [ -n "$pid" ] && [ "$pid" != "0" ] \
    || { echo "ERROR: current PM2 process is not running" >&2; return 1; }
  cwd="$(readlink -f "/proc/$pid/cwd")"
  [ "$cwd" = "$BOOTSTRAP_RELEASE/$APP_SUBDIR" ] \
    || { echo "ERROR: bootstrap rollback is not the current PM2 release" >&2; return 1; }
  echo "rollback_release=PASS path=$BOOTSTRAP_RELEASE sha=$BOOTSTRAP_SHA"
}
prepare_bootstrap_rollback() {
  check_bootstrap_rollback >/dev/null
  if [ -n "$BOOTSTRAP_ALLOWED_GENERATED" ]; then
    IFS=',' read -r -a generated <<< "$BOOTSTRAP_ALLOWED_GENERATED"
    local path
    for path in "${generated[@]}"; do
      [ -z "$path" ] || git -C "$BOOTSTRAP_RELEASE" checkout -- "$path"
    done
  fi
  [ -z "$(git -C "$BOOTSTRAP_RELEASE" status --porcelain --untracked-files=no)" ] \
    || { echo "ERROR: bootstrap rollback release is not clean after generated-file cleanup" >&2; return 1; }
  write_runtime_files "$BOOTSTRAP_RELEASE"
  printf '%s\n' "$BOOTSTRAP_SHA" > "$BOOTSTRAP_RELEASE/.release-sha"
  touch "$BOOTSTRAP_RELEASE/.build-verified" "$BOOTSTRAP_RELEASE/.runtime-verified"
  ln -sfn "$BOOTSTRAP_RELEASE" "$PREVIOUS_LINK"
}
check_toolchain() {
  local repo="$1" package_manager pnpm_version actual
  package_manager="$(jq -er '.packageManager' "$repo/package.json")"
  [[ "$package_manager" =~ ^pnpm@([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "ERROR: packageManager must pin pnpm x.y.z" >&2; return 1; }
  pnpm_version="${BASH_REMATCH[1]}"
  command -v node >/dev/null || { echo "ERROR: node missing" >&2; return 1; }
  command -v corepack >/dev/null || { echo "ERROR: corepack missing" >&2; return 1; }
  actual="$(cd "$repo" && env -u NODE_CHANNEL_FD -u NODE_UNIQUE_ID corepack pnpm --version)"
  [ "$actual" = "$pnpm_version" ] || { echo "ERROR: pnpm mismatch declared=$pnpm_version actual=$actual" >&2; return 1; }
  echo "toolchain=PASS node=$(node --version) corepack=$(corepack --version) pnpm=$actual"
}
preflight() {
  is_sha "$VERSION" || { echo "ERROR: --version must be a full 40-character lowercase SHA" >&2; return 1; }
  [ "$(id -u)" -ne 0 ] || { echo "ERROR: root deployment is forbidden" >&2; return 1; }
  for bin in git jq node corepack pm2 curl psql flock; do command -v "$bin" >/dev/null || { echo "ERROR: required command missing: $bin" >&2; return 1; }; done
  secret_metadata_ok
  check_topology
  check_db
  check_bootstrap_rollback
  (
    local tmp
    tmp="$(mktemp -d -t demo-safe-preflight-XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    checkout_for_preflight "$tmp"
    check_toolchain "$tmp"
    [ -d "$tmp/$APP_SUBDIR" ] || { echo "ERROR: app_subdir missing at target SHA" >&2; return 1; }
  )
  if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
    local pid cwd running_sha
    pid="$(pm2 pid "$PM2_NAME")"; cwd="$(readlink -f "/proc/$pid/cwd")"
    running_sha="UNKNOWN"
    if [ -f "$cwd/.release-sha" ]; then
      running_sha="$(cat "$cwd/.release-sha")"
    elif git -C "$cwd" rev-parse HEAD >/dev/null 2>&1; then
      running_sha="$(git -C "$cwd" rev-parse HEAD)"
    fi
    echo "pm2_identity=PASS name=$PM2_NAME cwd=$cwd running_sha=$running_sha"
  else
    echo "pm2_identity=NEW name=$PM2_NAME"
  fi
  echo "target_sha=$VERSION"
  echo "release_path=$RELEASES_DIR/$VERSION"
  echo "rollback_target=$BOOTSTRAP_RELEASE rollback_sha=$BOOTSTRAP_SHA"
  echo "build_env=SANITIZED runtime_env=EXTERNAL_FILE"
  echo "PREFLIGHT_PASS"
}
write_runtime_files() {
  local release="$1" deploy_dir="$release/.deployment"
  mkdir -p "$deploy_dir"
  cat > "$deploy_dir/start.cjs" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const file = process.env.RUNTIME_SECRET_FILE;
const required = (process.env.REQUIRED_RUNTIME_SECRETS || '').split(',').filter(Boolean);
if (!file) throw new Error('RUNTIME_SECRET_FILE is required');
const stat = fs.statSync(file);
if ((stat.mode & 0o077) !== 0) throw new Error('Runtime secret file permissions are too broad');
const secrets = JSON.parse(fs.readFileSync(file, 'utf8'));
for (const name of required) {
  if (typeof secrets[name] !== 'string' || secrets[name].length === 0) throw new Error(`Missing runtime secret: ${name}`);
  process.env[name] = secrets[name];
}
const nextBin = require.resolve('next/dist/bin/next', { paths: [process.cwd()] });
process.argv = [process.execPath, nextBin, 'start', '-H', '127.0.0.1', '-p', process.env.INTERNAL_PORT];
require(nextBin);
JS
  cat > "$deploy_dir/ecosystem.cjs" <<EOF2
module.exports = { apps: [{
  name: ${PM2_NAME@Q},
  cwd: ${release@Q} + '/' + ${APP_SUBDIR@Q},
  script: ${release@Q} + '/.deployment/start.cjs',
  instances: 1,
  exec_mode: 'fork',
  autorestart: true,
  watch: false,
  max_memory_restart: '1G',
  env: {
    NODE_ENV: 'production',
    INTERNAL_PORT: ${INTERNAL_PORT@Q},
    RUNTIME_SECRET_FILE: ${SECRET_FILE@Q},
    REQUIRED_RUNTIME_SECRETS: ${REQUIRED_SECRETS@Q},
    NEXT_DIST_DIR: ${DIST_DIR@Q}
  }
}] };
EOF2
  chmod 700 "$deploy_dir/start.cjs"; chmod 600 "$deploy_dir/ecosystem.cjs"
}
build_release() {
  local release="$1" package_manager pnpm_version shim node_dir
  checkout_for_preflight "$release"
  package_manager="$(jq -er '.packageManager' "$release/package.json")"; pnpm_version="${package_manager#pnpm@}"
  shim="$release/.deployment-bin"; mkdir -p "$shim"
  cat > "$shim/pnpm" <<'SH'
#!/bin/sh
exec corepack pnpm "$@"
SH
  chmod 700 "$shim/pnpm"
  node_dir="$(dirname "$(command -v node)")"
  (
    cd "$release"
    env -i HOME="$HOME" USER="$(id -un)" PATH="$shim:$node_dir:/usr/local/bin:/usr/bin:/bin" CI=true NEXT_DIST_DIR="$DIST_DIR" \
      corepack pnpm install --frozen-lockfile
    env -i HOME="$HOME" USER="$(id -un)" PATH="$shim:$node_dir:/usr/local/bin:/usr/bin:/bin" CI=true NEXT_DIST_DIR="$DIST_DIR" \
      corepack pnpm build
    git checkout -- .
    [ -z "$(git status --porcelain --untracked-files=no)" ]
    [ "$(corepack pnpm --version)" = "$pnpm_version" ]
  )
  printf '%s\n' "$VERSION" > "$release/.release-sha"
  printf '%s\n' "$package_manager" > "$release/.release-package-manager"
  touch "$release/.build-verified"
  write_runtime_files "$release"
}
attest_release() {
  local release="$1" expected="$2"
  [ -f "$release/.build-verified" ] || return 1
  [ "$(cat "$release/.release-sha")" = "$expected" ] || return 1
  [ "$(git -C "$release" rev-parse HEAD)" = "$expected" ] || return 1
  [ -z "$(git -C "$release" status --porcelain --untracked-files=no)" ] || return 1
}
activate() {
  local release="$1" expected="$2"
  attest_release "$release" "$expected" || { echo "ERROR: release attestation failed" >&2; return 1; }
  secret_metadata_ok >/dev/null
  local old=""
  [ -L "$CURRENT_LINK" ] && old="$(readlink -f "$CURRENT_LINK")"
  [ -z "$old" ] || ln -sfn "$old" "$PREVIOUS_LINK"
  ln -sfn "$release" "$CURRENT_LINK"
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  pm2 start "$release/.deployment/ecosystem.cjs" --only "$PM2_NAME" >/dev/null
  pm2 save >/dev/null
  local code="000" i
  for i in $(seq 1 20); do code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${INTERNAL_PORT}${HEALTH_PATH}" || true)"; [[ "$code" =~ ^(2|3) ]] && break; sleep 2; done
  [[ "$code" =~ ^(2|3) ]] || { echo "ERROR: internal health failed HTTP=$code" >&2; return 1; }
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${PUBLIC_HOST}:${PUBLIC_PORT}${HEALTH_PATH}" || true)"
  [[ "$code" =~ ^(2|3) ]] || { echo "ERROR: public health failed HTTP=$code" >&2; return 1; }
  local pid cwd
  pid="$(pm2 pid "$PM2_NAME")"; cwd="$(readlink -f "/proc/$pid/cwd")"
  [ "$cwd" = "$release/$APP_SUBDIR" ] || { echo "ERROR: PM2 cwd attestation failed" >&2; return 1; }
  touch "$release/.runtime-verified"
  echo "source_sha=$expected release_sha=$(cat "$release/.release-sha") running_sha=$(cat "$release/.release-sha")"
  echo "DEPLOY_PASS"
}

case "$ACTION" in
  doctor|preflight)
    preflight
    ;;
  dry-run)
    preflight
    echo "action=DRY_RUN_NO_MUTATION"
    echo "plan=fetch-clean-build-immutable-release,atomic-current-switch,pm2-delete-start,health-and-sha-attestation"
    echo "DRY_RUN_PASS"
    ;;
  deploy)
    preflight
    mkdir -p "$LOCK_DIR" "$RELEASES_DIR"
    exec 9>"$LOCK_DIR/$APP.safe-demo.lock"; flock -n 9 || { echo "ERROR: deployment lock busy" >&2; exit 1; }
    release="$RELEASES_DIR/$VERSION"
    [ ! -e "$release" ] || { echo "ERROR: immutable release already exists: $release" >&2; exit 1; }
    tmp="$RELEASES_DIR/.building-$VERSION-$$"; trap 'rm -rf "${tmp:-}"' EXIT
    build_release "$tmp"; mv "$tmp" "$release"; tmp=""
    if [ ! -L "$PREVIOUS_LINK" ]; then
      prepare_bootstrap_rollback
    fi
    if ! activate "$release" "$VERSION"; then
      echo "ERROR: activation failed; invoking verified rollback" >&2
      "$0" rollback "$APP" --version "$VERSION" --config "$CONFIG"
      exit 1
    fi
    ;;
  rollback)
    secret_metadata_ok >/dev/null; check_topology >/dev/null
    target=""
    if [ -n "$ROLLBACK_SHA" ]; then is_sha "$ROLLBACK_SHA" || { echo "ERROR: invalid rollback SHA" >&2; exit 1; }; target="$RELEASES_DIR/$ROLLBACK_SHA"; else [ -L "$PREVIOUS_LINK" ] && target="$(readlink -f "$PREVIOUS_LINK")"; fi
    [ -n "$target" ] && [ -d "$target" ] || { echo "ERROR: verified rollback release unavailable" >&2; exit 1; }
    target_sha="$(cat "$target/.release-sha")"
    [ -f "$target/.runtime-verified" ] || { echo "ERROR: rollback target was never runtime verified" >&2; exit 1; }
    activate "$target" "$target_sha"
    echo "ROLLBACK_PASS running_sha=$target_sha"
    ;;
esac
