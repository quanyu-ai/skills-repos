#!/usr/bin/env bash
# Deterministic, external-secret Demo release path.
# Usage: demo-safe.sh <doctor|preflight|dry-run|build-only|deploy|rollback> <app> --version <40-char-sha> [--config file]
set -euo pipefail

cfg() { jq -er --arg a "$APP" ".apps[\$a].$1" "$CONFIG"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/../config/demo-safe.json"
PROC_ROOT="${DEMO_SAFE_PROC_ROOT:-/proc}"

load_config() {
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
  LEGACY_RELEASE="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.release // empty' "$CONFIG")"
  LEGACY_SHA="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.sha // empty' "$CONFIG")"
  LEGACY_CWD="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.cwd // empty' "$CONFIG")"
  LEGACY_EXECUTABLE="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.executable // empty' "$CONFIG")"
  LEGACY_ARGS_JSON="$(jq -c --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.args // []' "$CONFIG")"
  LEGACY_HOST="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.host // empty' "$CONFIG")"
  LEGACY_INTERNAL_PORT="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.internal_port // empty' "$CONFIG")"
  LEGACY_PROBE_PORT="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.probe_port // empty' "$CONFIG")"
  LEGACY_DIST_DIR="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.next_dist_dir // empty' "$CONFIG")"
  LEGACY_SECRET_FILE="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.secret_file // empty' "$CONFIG")"
  LEGACY_REQUIRED_SECRETS="$(jq -r --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.required_runtime_secrets // [] | join(",")' "$CONFIG")"
  LEGACY_SAFE_ENV_JSON="$(jq -c --arg a "$APP" '.apps[$a].legacy_bootstrap_rollback.safe_env // {}' "$CONFIG")"
  BOOTSTRAP_ALLOWED_GENERATED="$(jq -r --arg a "$APP" '.apps[$a].bootstrap_allowed_generated_changes // [] | join(",")' "$CONFIG")"
  BUILD_ALLOWED_TRACKED="$(jq -r --arg a "$APP" '.apps[$a].build_allowed_tracked_changes // [] | join(",")' "$CONFIG")"
  BUILD_PREPARE_SCRIPT="$(jq -er --arg a "$APP" '.apps[$a].build_prepare_script' "$CONFIG")"
  BUILD_PREPARE_OUTPUTS="$(jq -er --arg a "$APP" '.apps[$a].build_prepare_outputs | join(",")' "$CONFIG")"
  RELEASES_DIR="$RELEASE_ROOT/releases"; CURRENT_LINK="$RELEASE_ROOT/current"; PREVIOUS_LINK="$RELEASE_ROOT/previous"
}

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
check_legacy_bootstrap_descriptor() {
  if [ -z "$LEGACY_RELEASE" ] || [ -z "$LEGACY_SHA" ] || [ -z "$LEGACY_CWD" ] \
    || [ -z "$LEGACY_EXECUTABLE" ] || [ -z "$LEGACY_HOST" ] || [ -z "$LEGACY_INTERNAL_PORT" ] \
    || [ -z "$LEGACY_PROBE_PORT" ] || [ -z "$LEGACY_DIST_DIR" ] || [ -z "$LEGACY_SECRET_FILE" ] \
    || [ -z "$LEGACY_REQUIRED_SECRETS" ]; then
    echo "ERROR: complete legacy bootstrap rollback descriptor is required for the first managed cutover" >&2
    return 1
  fi
  is_sha "$LEGACY_SHA" || { echo "ERROR: invalid legacy bootstrap rollback SHA" >&2; return 1; }
  [ -d "$LEGACY_RELEASE" ] || { echo "ERROR: legacy bootstrap rollback release missing" >&2; return 1; }
  [ "$(git -C "$LEGACY_RELEASE" rev-parse HEAD)" = "$LEGACY_SHA" ] \
    || { echo "ERROR: bootstrap rollback SHA mismatch" >&2; return 1; }
  [ "$(readlink -f "$LEGACY_CWD")" = "$(readlink -f "$LEGACY_RELEASE/$APP_SUBDIR")" ] \
    || { echo "ERROR: legacy cwd does not match exact release/app path" >&2; return 1; }
  [ "$(readlink -f "$LEGACY_EXECUTABLE")" = "$(readlink -f "$LEGACY_CWD/node_modules/next/dist/bin/next")" ] \
    || { echo "ERROR: legacy executable is not release-local Next" >&2; return 1; }
  [ -x "$LEGACY_EXECUTABLE" ] || { echo "ERROR: legacy executable missing or not executable" >&2; return 1; }
  [ -f "$LEGACY_CWD/$LEGACY_DIST_DIR/BUILD_ID" ] \
    || { echo "ERROR: bootstrap rollback build artifact missing" >&2; return 1; }
  [[ "$LEGACY_INTERNAL_PORT" =~ ^[0-9]+$ ]] && [ "$LEGACY_INTERNAL_PORT" -ge 1 ] && [ "$LEGACY_INTERNAL_PORT" -le 65535 ] \
    || { echo "ERROR: invalid legacy internal port" >&2; return 1; }
  [ "$LEGACY_INTERNAL_PORT" = "$INTERNAL_PORT" ] \
    || { echo "ERROR: legacy internal port mismatch" >&2; return 1; }
  [ "$LEGACY_HOST" = "127.0.0.1" ] \
    || { echo "ERROR: legacy host must be 127.0.0.1" >&2; return 1; }
  [[ "$LEGACY_PROBE_PORT" =~ ^[0-9]+$ ]] && [ "$LEGACY_PROBE_PORT" -ge 1 ] && [ "$LEGACY_PROBE_PORT" -le 65535 ] \
    && [ "$LEGACY_PROBE_PORT" != "$INTERNAL_PORT" ] && [ "$LEGACY_PROBE_PORT" != "$PUBLIC_PORT" ] \
    || { echo "ERROR: legacy probe port must be numeric and isolated" >&2; return 1; }
  [ "$LEGACY_DIST_DIR" = "$DIST_DIR" ] \
    || { echo "ERROR: legacy Next distDir mismatch" >&2; return 1; }
  [ "$LEGACY_SECRET_FILE" = "$SECRET_FILE" ] \
    || { echo "ERROR: legacy descriptor must use the canonical external secret source" >&2; return 1; }
  [ "$LEGACY_REQUIRED_SECRETS" = "$REQUIRED_SECRETS" ] \
    || { echo "ERROR: legacy descriptor required secret names mismatch" >&2; return 1; }
  jq -e 'type == "array" and length == 1 and .[0] == "start"' <<< "$LEGACY_ARGS_JSON" >/dev/null \
    || { echo "ERROR: legacy args must be the reviewed Next start contract" >&2; return 1; }
  jq -e 'type == "object"
    and all(keys[]; test("^[A-Z_][A-Z0-9_]*$") and (test("(SECRET|TOKEN|PASSWORD|KEY|DATABASE_URL)") | not))
    and all(.[]; type == "string")' <<< "$LEGACY_SAFE_ENV_JSON" >/dev/null \
    || { echo "ERROR: legacy safe_env must contain safe string environment entries" >&2; return 1; }
  local name
  IFS=',' read -r -a names <<< "$LEGACY_REQUIRED_SECRETS"
  for name in "${names[@]}"; do
    jq -e --arg n "$name" 'has($n) | not' <<< "$LEGACY_SAFE_ENV_JSON" >/dev/null \
      || { echo "ERROR: secret name is forbidden in legacy safe_env: $name" >&2; return 1; }
  done
  local dirty path allowed
  dirty="$(git -C "$LEGACY_RELEASE" status --porcelain --untracked-files=no)"
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
  echo "legacy_descriptor=PASS release=$LEGACY_RELEASE sha=$LEGACY_SHA"
}

check_legacy_bootstrap_live() {
  check_legacy_bootstrap_descriptor >/dev/null
  local pid cwd
  pid="$(pm2 pid "$PM2_NAME")"; [ -n "$pid" ] && [ "$pid" != "0" ] \
    || { echo "ERROR: current PM2 process is not running" >&2; return 1; }
  cwd="$(readlink -f "$PROC_ROOT/$pid/cwd")"
  [ "$cwd" = "$(readlink -f "$LEGACY_CWD")" ] \
    || { echo "ERROR: bootstrap rollback is not the current PM2 release" >&2; return 1; }
  echo "rollback_release=PASS path=$LEGACY_RELEASE sha=$LEGACY_SHA contract=legacy-descriptor"
}

build_legacy_runtime_env() {
  local port="$1" entry key value reserved
  LEGACY_RUNTIME_ENV=(
    "RUNTIME_SECRET_FILE=$LEGACY_SECRET_FILE"
    "REQUIRED_RUNTIME_SECRETS=$LEGACY_REQUIRED_SECRETS"
    "LEGACY_EXECUTABLE=$LEGACY_EXECUTABLE"
    "LEGACY_ARGS_JSON=$LEGACY_ARGS_JSON"
    "LEGACY_HOST=$LEGACY_HOST"
    "LEGACY_INTERNAL_PORT=$port"
    "NEXT_DIST_DIR=$LEGACY_DIST_DIR"
  )
  while IFS= read -r entry; do
    key="$(printf '%s' "$entry" | base64 -d | jq -r '.key')"
    value="$(printf '%s' "$entry" | base64 -d | jq -r '.value')"
    reserved="false"
    case "$key" in
      RUNTIME_SECRET_FILE|REQUIRED_RUNTIME_SECRETS|LEGACY_EXECUTABLE|LEGACY_ARGS_JSON|LEGACY_HOST|LEGACY_INTERNAL_PORT|NEXT_DIST_DIR)
        reserved="true" ;;
    esac
    [ "$reserved" = "false" ] || { echo "ERROR: reserved legacy runtime env key: $key" >&2; return 1; }
    LEGACY_RUNTIME_ENV+=("$key=$value")
  done < <(jq -r 'to_entries[] | @base64' <<< "$LEGACY_SAFE_ENV_JSON")
}

probe_legacy_bootstrap() {
  check_legacy_bootstrap_descriptor >/dev/null
  local before_pid before_cwd probe_pid="" code="000" i log node_dir
  before_pid="$(pm2 pid "$PM2_NAME")"
  before_cwd="$(readlink -f "$PROC_ROOT/$before_pid/cwd")"
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LEGACY_PROBE_PORT}${HEALTH_PATH}" || true)"
  [ "$code" = "000" ] || { echo "ERROR: legacy probe port is already serving HTTP" >&2; return 1; }
  log="$(mktemp -t demo-safe-legacy-probe-XXXXXX)"; chmod 600 "$log"
  build_legacy_runtime_env "$LEGACY_PROBE_PORT"
  node_dir="$(dirname "$(command -v node)")"
  (
    cd "$LEGACY_CWD"
    exec env -i HOME="$HOME" USER="$(id -un)" PATH="$node_dir:/usr/local/bin:/usr/bin:/bin" \
      "${LEGACY_RUNTIME_ENV[@]}" node "$SCRIPT_DIR/legacy-bootstrap-start.cjs"
  ) >"$log" 2>&1 & probe_pid=$!
  for i in $(seq 1 "${DEMO_SAFE_HEALTH_ATTEMPTS:-20}"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LEGACY_PROBE_PORT}${HEALTH_PATH}" || true)"
    [[ "$code" =~ ^(2|3) ]] && break
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep "${DEMO_SAFE_HEALTH_SLEEP:-2}"
  done
  kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true
  if ! [[ "$code" =~ ^(2|3) ]]; then
    echo "ERROR: legacy isolated-port startup probe failed HTTP=$code" >&2
    for pattern in 'Incomplete legacy bootstrap runtime metadata' 'Runtime secret file permissions are too broad' \
      'Missing runtime secret' 'Cannot find module' 'EADDRINUSE' 'SyntaxError'; do
      printf 'legacy_probe_error_%s=%s\n' "$(tr -c '[:alnum:]' '_' <<< "$pattern")" "$(grep -Fc "$pattern" "$log" || true)" >&2
    done
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  [ "$(pm2 pid "$PM2_NAME")" = "$before_pid" ] \
    && [ "$(readlink -f "$PROC_ROOT/$before_pid/cwd")" = "$before_cwd" ] \
    || { echo "ERROR: legacy probe changed the live PM2 process" >&2; return 1; }
  echo "legacy_isolated_probe=PASS port=$LEGACY_PROBE_PORT live_service=UNCHANGED"
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

check_build_prepare_contract() {
  local repo="$1" command output package_script
  [ "$BUILD_PREPARE_SCRIPT" = "db:generate" ] \
    || { echo "ERROR: only the reviewed db:generate preparation contract is allowed" >&2; return 1; }
  command="$(jq -er --arg script "$BUILD_PREPARE_SCRIPT" '.scripts[$script]' "$repo/package.json")" \
    || { echo "ERROR: repository does not declare $BUILD_PREPARE_SCRIPT" >&2; return 1; }
  [ -n "$BUILD_PREPARE_OUTPUTS" ] \
    || { echo "ERROR: build_prepare_outputs must not be empty" >&2; return 1; }
  IFS=',' read -r -a outputs <<< "$BUILD_PREPARE_OUTPUTS"
  for output in "${outputs[@]}"; do
    [ -n "$output" ] && [[ "$output" != /* ]] && [[ "$output" != *".."* ]] \
      || { echo "ERROR: invalid build preparation output path" >&2; return 1; }
  done
  while IFS= read -r package_file; do
    package_script="$(jq -r --arg script "$BUILD_PREPARE_SCRIPT" '.scripts[$script] // empty' "$repo/$package_file")"
    [ -z "$package_script" ] && continue
    if printf '%s\n' "$package_script" | grep -Eiq 'migrate|db[[:space:]:_-]*push|seed'; then
      echo "ERROR: forbidden database mutation in $package_file $BUILD_PREPARE_SCRIPT" >&2
      return 1
    fi
  done < <(git -C "$repo" ls-files 'package.json' '*/package.json')
  echo "build_prepare_contract=PASS script=$BUILD_PREPARE_SCRIPT outputs=$BUILD_PREPARE_OUTPUTS"
}
preflight() {
  is_sha "$VERSION" || { echo "ERROR: --version must be a full 40-character lowercase SHA" >&2; return 1; }
  [ "$(id -u)" -ne 0 ] || { echo "ERROR: root deployment is forbidden" >&2; return 1; }
  for bin in git jq node corepack pm2 curl psql flock; do command -v "$bin" >/dev/null || { echo "ERROR: required command missing: $bin" >&2; return 1; }; done
  secret_metadata_ok
  check_topology
  check_db
  if [ -L "$CURRENT_LINK" ]; then
    local managed_current managed_sha
    managed_current="$(readlink -f "$CURRENT_LINK")"
    [ -f "$managed_current/.runtime-verified" ] \
      || { echo "ERROR: canonical current release is not runtime verified" >&2; return 1; }
    managed_sha="$(cat "$managed_current/.release-sha")"
    attest_release "$managed_current" "$managed_sha" \
      || { echo "ERROR: canonical current release attestation failed" >&2; return 1; }
    attest_live_process "$managed_current" "$managed_sha" >/dev/null \
      || { echo "ERROR: canonical current release is not live" >&2; return 1; }
    echo "rollback_release=PASS path=$managed_current sha=$managed_sha contract=canonical"
  else
    check_legacy_bootstrap_live
    probe_legacy_bootstrap
  fi
  (
    local tmp
    tmp="$(mktemp -d -t demo-safe-preflight-XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    checkout_for_preflight "$tmp"
    check_toolchain "$tmp"
    check_build_prepare_contract "$tmp"
    [ -d "$tmp/$APP_SUBDIR" ] || { echo "ERROR: app_subdir missing at target SHA" >&2; return 1; }
  )
  if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then
    local pid cwd running_sha
    pid="$(pm2 pid "$PM2_NAME")"; cwd="$(readlink -f "$PROC_ROOT/$pid/cwd")"
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
  if [ -L "$CURRENT_LINK" ]; then
    echo "rollback_target=$(readlink -f "$CURRENT_LINK") rollback_sha=$(cat "$(readlink -f "$CURRENT_LINK")/.release-sha") contract=canonical"
  else
    echo "rollback_target=$LEGACY_RELEASE rollback_sha=$LEGACY_SHA contract=legacy-descriptor"
  fi
  echo "build_env=SANITIZED runtime_env=EXTERNAL_FILE"
  echo "PREFLIGHT_PASS"
}
write_runtime_files() {
  local release="$1"
  local deploy_dir="$release/.deployment"
  local pm2_json release_json app_subdir_json port_json secret_json required_json dist_json
  pm2_json="$(jq -Rn --arg v "$PM2_NAME" '$v')"
  release_json="$(jq -Rn --arg v "$release" '$v')"
  app_subdir_json="$(jq -Rn --arg v "$APP_SUBDIR" '$v')"
  port_json="$(jq -Rn --arg v "$INTERNAL_PORT" '$v')"
  secret_json="$(jq -Rn --arg v "$SECRET_FILE" '$v')"
  required_json="$(jq -Rn --arg v "$REQUIRED_SECRETS" '$v')"
  dist_json="$(jq -Rn --arg v "$DIST_DIR" '$v')"
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
  name: $pm2_json,
  cwd: $release_json + '/' + $app_subdir_json,
  script: $release_json + '/.deployment/start.cjs',
  instances: 1,
  exec_mode: 'fork',
  autorestart: true,
  watch: false,
  max_memory_restart: '1G',
  env: {
    NODE_ENV: 'production',
    INTERNAL_PORT: $port_json,
    RUNTIME_SECRET_FILE: $secret_json,
    REQUIRED_RUNTIME_SECRETS: $required_json,
    NEXT_DIST_DIR: $dist_json
  }
}] };
EOF2
  chmod 700 "$deploy_dir/start.cjs"; chmod 600 "$deploy_dir/ecosystem.cjs"
}
run_sanitized_pnpm() {
  local release="$1"; shift
  local shim node_dir
  shim="$release/.deployment-bin"
  node_dir="$(dirname "$(command -v node)")"
  (
    cd "$release"
    env -i HOME="$HOME" USER="$(id -un)" PATH="$shim:$node_dir:/usr/local/bin:/usr/bin:/bin" \
      CI=true NEXT_DIST_DIR="$DIST_DIR" corepack pnpm "$@"
  )
}

run_sanitized_build_prepare() {
  local release="$1" database_url shim node_dir
  shim="$release/.deployment-bin"
  node_dir="$(dirname "$(command -v node)")"
  database_url="$(jq -er '.DATABASE_URL' "$SECRET_FILE")"
  (
    cd "$release"
    env -i HOME="$HOME" USER="$(id -un)" PATH="$shim:$node_dir:/usr/local/bin:/usr/bin:/bin" \
      CI=true NEXT_DIST_DIR="$DIST_DIR" DATABASE_URL="$database_url" \
      corepack pnpm "$BUILD_PREPARE_SCRIPT"
  )
}

run_repository_build() {
  local release="$1" output
  check_build_prepare_contract "$release" >/dev/null
  run_sanitized_pnpm "$release" install --frozen-lockfile || return 1
  echo "build_prepare=START script=$BUILD_PREPARE_SCRIPT"
  run_sanitized_build_prepare "$release" \
    || { echo "ERROR: build preparation failed: $BUILD_PREPARE_SCRIPT" >&2; return 1; }
  IFS=',' read -r -a outputs <<< "$BUILD_PREPARE_OUTPUTS"
  for output in "${outputs[@]}"; do
    [ -e "$release/$output" ] \
      || { echo "ERROR: expected generated output missing: $output" >&2; return 1; }
  done
  echo "build_prepare=PASS script=$BUILD_PREPARE_SCRIPT"
  run_sanitized_pnpm "$release" build || return 1
  clean_allowed_build_changes "$release" || return 1
}

build_release() {
  local release="$1" package_manager pnpm_version shim
  checkout_for_preflight "$release"
  package_manager="$(jq -er '.packageManager' "$release/package.json")"; pnpm_version="${package_manager#pnpm@}"
  shim="$release/.deployment-bin"; mkdir -p "$shim"
  cat > "$shim/pnpm" <<'SH'
#!/bin/sh
exec corepack pnpm "$@"
SH
  chmod 700 "$shim/pnpm"
  run_repository_build "$release" || return 1
  [ "$(cd "$release" && env -u NODE_CHANNEL_FD -u NODE_UNIQUE_ID corepack pnpm --version)" = "$pnpm_version" ]
  printf '%s\n' "$VERSION" > "$release/.release-sha"
  printf '%s\n' "$package_manager" > "$release/.release-package-manager"
  touch "$release/.build-verified"
  write_runtime_files "$release"
}

clean_allowed_build_changes() {
  local release="$1" dirty line path allowed candidate
  dirty="$(git -C "$release" status --porcelain --untracked-files=no)"
  [ -n "$dirty" ] || return 0
  while IFS= read -r line; do
    path="${line:3}"; allowed="false"
    IFS=',' read -r -a generated <<< "$BUILD_ALLOWED_TRACKED"
    for candidate in "${generated[@]}"; do
      [ -n "$candidate" ] && [ "$path" = "$candidate" ] && allowed="true"
    done
    [ "$allowed" = "true" ] \
      || { echo "ERROR: unexpected tracked build mutation: $path" >&2; return 1; }
    git -C "$release" checkout -- "$path"
    echo "build_tracked_change=RESTORED path=$path"
  done <<< "$dirty"
  [ -z "$(git -C "$release" status --porcelain --untracked-files=no)" ] \
    || { echo "ERROR: tracked build mutations remain after cleanup" >&2; return 1; }
}
attest_release() {
  local release="$1" expected="$2"
  [ -f "$release/.build-verified" ] || return 1
  [ "$(cat "$release/.release-sha")" = "$expected" ] || return 1
  [ "$(git -C "$release" rev-parse HEAD)" = "$expected" ] || return 1
  [ -z "$(git -C "$release" status --porcelain --untracked-files=no)" ] || return 1
}

live_release() {
  local pid cwd suffix="/$APP_SUBDIR"
  pid="$(pm2 pid "$PM2_NAME")"
  [ -n "$pid" ] && [ "$pid" != "0" ] || return 1
  cwd="$(readlink -f "$PROC_ROOT/$pid/cwd")"
  [[ "$cwd" = *"$suffix" ]] || return 1
  printf '%s\n' "${cwd%$suffix}"
}

attest_live_process() {
  local expected_release="$1" expected_sha="$2" actual_release marker git_sha
  expected_release="$(cd "$expected_release" && pwd -P)"
  actual_release="$(live_release)" \
    || { echo "ERROR: cannot resolve live PM2 release" >&2; return 1; }
  [ "$actual_release" = "$expected_release" ] \
    || { echo "ERROR: live PM2 release mismatch" >&2; return 1; }
  marker="$(cat "$actual_release/.release-sha")"
  git_sha="$(git -C "$actual_release" rev-parse HEAD)"
  [ "$marker" = "$expected_sha" ] && [ "$git_sha" = "$expected_sha" ] \
    || { echo "ERROR: live source/release SHA mismatch" >&2; return 1; }
  echo "live_attestation=PASS source_sha=$git_sha release_sha=$marker running_sha=$marker"
}

health_check() {
  local code="000" i
  for i in $(seq 1 "${DEMO_SAFE_HEALTH_ATTEMPTS:-20}"); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${INTERNAL_PORT}${HEALTH_PATH}" || true)"
    [[ "$code" =~ ^(2|3) ]] && break
    sleep "${DEMO_SAFE_HEALTH_SLEEP:-2}"
  done
  [[ "$code" =~ ^(2|3) ]] \
    || { echo "ERROR: internal health failed HTTP=$code" >&2; return 1; }
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${PUBLIC_HOST}:${PUBLIC_PORT}${HEALTH_PATH}" || true)"
  [[ "$code" =~ ^(2|3) ]] \
    || { echo "ERROR: public health failed HTTP=$code" >&2; return 1; }
}

start_release() {
  local release="$1"
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  pm2 start "$release/.deployment/ecosystem.cjs" --only "$PM2_NAME" >/dev/null
}

start_legacy_bootstrap() {
  local entry
  build_legacy_runtime_env "$LEGACY_INTERNAL_PORT"
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  (
    for entry in "${LEGACY_RUNTIME_ENV[@]}"; do export "$entry"; done
    pm2 start "$SCRIPT_DIR/legacy-bootstrap-start.cjs" \
      --name "$PM2_NAME" --cwd "$LEGACY_CWD" --interpreter "$(command -v node)" --update-env >/dev/null
  )
}

attest_legacy_live_process() {
  local pid cwd git_sha
  pid="$(pm2 pid "$PM2_NAME")"; [ -n "$pid" ] && [ "$pid" != "0" ] \
    || { echo "ERROR: legacy PM2 process is not running" >&2; return 1; }
  cwd="$(readlink -f "$PROC_ROOT/$pid/cwd")"
  [ "$cwd" = "$(readlink -f "$LEGACY_CWD")" ] \
    || { echo "ERROR: live legacy cwd mismatch" >&2; return 1; }
  git_sha="$(git -C "$cwd" rev-parse HEAD)"
  [ "$git_sha" = "$LEGACY_SHA" ] \
    || { echo "ERROR: live legacy SHA mismatch" >&2; return 1; }
  echo "legacy_live_attestation=PASS source_sha=$git_sha running_sha=$git_sha"
}

restore_legacy_bootstrap() {
  check_legacy_bootstrap_descriptor >/dev/null
  start_legacy_bootstrap || return 1
  health_check || return 1
  attest_legacy_live_process || return 1
  rm -f "$CURRENT_LINK" "$PREVIOUS_LINK"
  pm2 save >/dev/null || return 1
  echo "LEGACY_RESTORE_PASS running_sha=$LEGACY_SHA"
}

restore_known_good() {
  local release="$1" expected="$2"
  [ -f "$release/.runtime-verified" ] \
    || { echo "ERROR: known-good release lacks runtime verification" >&2; return 1; }
  attest_release "$release" "$expected" \
    || { echo "ERROR: known-good release attestation failed" >&2; return 1; }
  start_release "$release" || return 1
  health_check || return 1
  attest_live_process "$release" "$expected" || return 1
  ln -sfn "$release" "$CURRENT_LINK"
  pm2 save >/dev/null || return 1
  echo "RESTORE_PASS running_sha=$expected"
}

activate_candidate() {
  local release="$1" expected="$2" known_good="$3" known_sha="$4"
  attest_release "$release" "$expected" \
    || { echo "ERROR: release attestation failed" >&2; return 1; }
  [ -f "$known_good/.runtime-verified" ] \
    || { echo "ERROR: rollback target was never runtime verified" >&2; return 1; }
  attest_release "$known_good" "$known_sha" \
    || { echo "ERROR: rollback target attestation failed" >&2; return 1; }
  secret_metadata_ok >/dev/null
  if ! start_release "$release" || ! health_check || ! attest_live_process "$release" "$expected"; then
    echo "ERROR: candidate activation failed; restoring exact known-good SHA=$known_sha" >&2
    restore_known_good "$known_good" "$known_sha"
    return 1
  fi
  if ! touch "$release/.runtime-verified" \
    || ! ln -sfn "$known_good" "$PREVIOUS_LINK" \
    || ! ln -sfn "$release" "$CURRENT_LINK" \
    || ! pm2 save >/dev/null \
    || ! attest_live_process "$release" "$expected"; then
    rm -f "$release/.runtime-verified"
    echo "ERROR: activation metadata commit failed; restoring exact known-good SHA=$known_sha" >&2
    restore_known_good "$known_good" "$known_sha"
    return 1
  fi
  echo "DEPLOY_PASS"
}

activate_first_candidate() {
  local release="$1" expected="$2"
  attest_release "$release" "$expected" \
    || { echo "ERROR: release attestation failed" >&2; return 1; }
  check_legacy_bootstrap_live >/dev/null
  secret_metadata_ok >/dev/null
  if ! start_release "$release" || ! health_check || ! attest_live_process "$release" "$expected"; then
    echo "ERROR: first-cutover candidate activation failed; restoring exact legacy SHA=$LEGACY_SHA" >&2
    restore_legacy_bootstrap
    return 1
  fi
  if ! touch "$release/.runtime-verified" \
    || ! ln -sfn "$release" "$CURRENT_LINK" \
    || ! rm -f "$PREVIOUS_LINK" \
    || ! pm2 save >/dev/null \
    || ! attest_live_process "$release" "$expected"; then
    rm -f "$release/.runtime-verified" "$CURRENT_LINK"
    echo "ERROR: first-cutover metadata commit failed; restoring exact legacy SHA=$LEGACY_SHA" >&2
    restore_legacy_bootstrap
    return 1
  fi
  echo "DEPLOY_PASS transition=legacy-to-canonical"
}

deploy_candidate_release() {
  local release="$1" tmp="$2" known_good known_sha
  build_release "$tmp" || return 1
  mv "$tmp" "$release"
  if [ ! -L "$CURRENT_LINK" ]; then
    activate_first_candidate "$release" "$VERSION"
    return
  fi
  known_good="$(live_release)" \
    || { echo "ERROR: cannot capture current known-good release" >&2; return 1; }
  known_sha="$(cat "$known_good/.release-sha")"
  activate_candidate "$release" "$VERSION" "$known_good" "$known_sha"
}

main() {
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
  case "$ACTION" in doctor|preflight|dry-run|build-only|deploy|rollback) ;; *) echo "Usage: $(basename "$0") <doctor|preflight|dry-run|build-only|deploy|rollback> <app> --version <sha> [--config file]" >&2; exit 2;; esac
  [ -n "$APP" ] || { echo "ERROR: app is required" >&2; exit 2; }
  [ -f "$CONFIG" ] || { echo "ERROR: config missing: $CONFIG" >&2; exit 2; }
  command -v jq >/dev/null || { echo "ERROR: jq missing" >&2; exit 1; }
  jq -e . "$CONFIG" >/dev/null || { echo "ERROR: invalid JSON config" >&2; exit 1; }
  load_config

  case "$ACTION" in
  doctor|preflight)
    preflight
    ;;
  dry-run)
    preflight
    echo "action=DRY_RUN_NO_MUTATION"
    echo "plan=fetch-clean-build-immutable-release,capture-known-good,start-and-attest,commit-metadata-or-exact-restore"
    echo "DRY_RUN_PASS"
    ;;
  build-only)
    preflight
    mkdir -p "$LOCK_DIR" "$RELEASES_DIR"
    exec 9>"$LOCK_DIR/$APP.safe-demo.lock"; flock -n 9 || { echo "ERROR: deployment lock busy" >&2; exit 1; }
    tmp="$RELEASES_DIR/.build-only-$VERSION-$$"; trap 'rm -rf "${tmp:-}"' EXIT
    build_release "$tmp"
    attest_release "$tmp" "$VERSION"
    echo "action=BUILD_ONLY_NO_ACTIVATION"
    echo "BUILD_ONLY_PASS source_sha=$VERSION"
    ;;
  deploy)
    preflight
    mkdir -p "$LOCK_DIR" "$RELEASES_DIR"
    exec 9>"$LOCK_DIR/$APP.safe-demo.lock"; flock -n 9 || { echo "ERROR: deployment lock busy" >&2; exit 1; }
    release="$RELEASES_DIR/$VERSION"
    [ ! -e "$release" ] || { echo "ERROR: immutable release already exists: $release" >&2; exit 1; }
    tmp="$RELEASES_DIR/.building-$VERSION-$$"; trap 'rm -rf "${tmp:-}"' EXIT
    deploy_candidate_release "$release" "$tmp"; tmp=""
    ;;
  rollback)
    secret_metadata_ok >/dev/null; check_topology >/dev/null
    target=""
    if [ -n "$ROLLBACK_SHA" ]; then is_sha "$ROLLBACK_SHA" || { echo "ERROR: invalid rollback SHA" >&2; exit 1; }; target="$RELEASES_DIR/$ROLLBACK_SHA"; else [ -L "$PREVIOUS_LINK" ] && target="$(readlink -f "$PREVIOUS_LINK")"; fi
    [ -n "$target" ] && [ -d "$target" ] || { echo "ERROR: verified rollback release unavailable" >&2; exit 1; }
    target_sha="$(cat "$target/.release-sha")"
    [ -f "$target/.runtime-verified" ] || { echo "ERROR: rollback target was never runtime verified" >&2; exit 1; }
    current="$(live_release)" || { echo "ERROR: cannot capture current release" >&2; exit 1; }
    current_sha="$(cat "$current/.release-sha")"
    if ! restore_known_good "$target" "$target_sha"; then
      echo "ERROR: rollback target failed; restoring original running release" >&2
      restore_known_good "$current" "$current_sha"
      exit 1
    fi
    [ "$current" = "$target" ] || ln -sfn "$current" "$PREVIOUS_LINK"
    echo "ROLLBACK_PASS running_sha=$target_sha"
    ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
