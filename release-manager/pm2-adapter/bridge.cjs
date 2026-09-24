"use strict";

const fs = require("node:fs");
const pm2 = require("pm2");
const pm2Package = require("pm2/package.json");

function readStdin() {
  return new Promise((resolve, reject) => {
    let body = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { body += chunk; });
    process.stdin.on("end", () => {
      try { resolve(JSON.parse(body || "{}")); } catch (error) { reject(error); }
    });
    process.stdin.on("error", reject);
  });
}

function call(method, ...args) {
  return new Promise((resolve, reject) => {
    pm2[method](...args, (error, result) => error ? reject(error) : resolve(result));
  });
}

function connect() {
  return new Promise((resolve, reject) => pm2.connect((error) => error ? reject(error) : resolve()));
}

function processEvidence(pid) {
  if (process.platform !== "linux" || !fs.existsSync("/proc/self/stat")) {
    throw new Error("PM2 adapter requires Linux /proc process evidence");
  }
  const base = `/proc/${pid}`;
  const stat = fs.readFileSync(`${base}/stat`, "utf8");
  const tail = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
  const startTicks = tail[19];
  const bootId = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  return {
    processStartId: `${bootId}:${startTicks}`,
    procCwd: fs.realpathSync(`${base}/cwd`),
    procExe: fs.realpathSync(`${base}/exe`),
    procCmdline: fs.readFileSync(`${base}/cmdline`).toString("utf8").split("\0").filter(Boolean),
  };
}

function normalizeArgs(value) {
  if (Array.isArray(value)) return value.map(String);
  if (typeof value === "string" && value.length) return value.split(/\s+/);
  return [];
}

function safeRecord(processDescription) {
  const env = processDescription.pm2_env || {};
  const pid = Number(processDescription.pid || 0);
  let evidence = null;
  if (pid > 0 && env.status === "online") {
    try { evidence = processEvidence(pid); } catch (error) {
      if (!error || !["ENOENT", "ESRCH"].includes(error.code)) throw error;
    }
  }
  return {
    adapterId: String(processDescription.pm_id),
    pid,
    name: env.name || processDescription.name || "",
    namespace: env.namespace || "default",
    status: env.status || "unknown",
    executable: fs.realpathSync(env.pm_exec_path),
    args: normalizeArgs(env.args),
    cwd: fs.realpathSync(env.pm_cwd),
    environmentId: env.RELEASE_MANAGER_ENVIRONMENT_ID || null,
    serviceId: env.RELEASE_MANAGER_SERVICE_ID || null,
    releaseSha: env.RELEASE_MANAGER_RELEASE_SHA || null,
    launchToken: env.RELEASE_MANAGER_LAUNCH_TOKEN || null,
    ownedHost: env.RELEASE_MANAGER_OWNED_HOST || null,
    ownedPort: env.RELEASE_MANAGER_OWNED_PORT ? Number(env.RELEASE_MANAGER_OWNED_PORT) : null,
    buildConfigDigest: env.RELEASE_MANAGER_BUILD_CONFIG_DIGEST || null,
    runtimeConfigDigest: env.RELEASE_MANAGER_RUNTIME_CONFIG_DIGEST || null,
    releaseContractDigest: env.RELEASE_MANAGER_RELEASE_CONTRACT_DIGEST || null,
    environmentPolicyDigest: env.RELEASE_MANAGER_ENVIRONMENT_POLICY_DIGEST || null,
    pmUptime: env.pm_uptime || null,
    evidence,
  };
}

async function inventory() {
  const records = await call("list");
  return records.map(safeRecord);
}

function assertExact(record, expected, requireLive) {
  if (!record || record.adapterId !== String(expected.adapterId)) throw new Error("exact PM2 adapter record not found");
  if (record.name !== expected.name || record.namespace !== expected.namespace) throw new Error("PM2 selector mismatch");
  if (record.executable !== expected.executable || record.cwd !== expected.cwd) throw new Error("PM2 runtime mismatch");
  if (JSON.stringify(record.args) !== JSON.stringify(expected.args)) throw new Error("PM2 args mismatch");
  if (record.environmentId !== expected.environmentId || record.serviceId !== expected.serviceId) throw new Error("PM2 ownership mismatch");
  if (record.releaseSha !== expected.releaseSha) throw new Error("PM2 release SHA mismatch");
  if (record.buildConfigDigest !== (expected.buildConfigDigest || null) || record.runtimeConfigDigest !== (expected.runtimeConfigDigest || null) || record.releaseContractDigest !== (expected.releaseContractDigest || null) || record.environmentPolicyDigest !== (expected.environmentPolicyDigest || null)) throw new Error("PM2 configuration digest mismatch");
  if (requireLive) {
    if (record.status !== "online" || record.pid !== Number(expected.pid)) throw new Error("PM2 live PID mismatch");
    if (!record.evidence || record.evidence.processStartId !== expected.processStartId) throw new Error("process start identity mismatch");
  }
}

function assertRawOwned(record, expected) {
  assertExact(record, expected, false);
  if (!expected.launchToken || record.launchToken !== expected.launchToken) throw new Error("PM2 launch token mismatch");
  if (record.ownedHost !== expected.ownedHost || record.ownedPort !== Number(expected.ownedPort)) throw new Error("PM2 listener ownership mismatch");
  if (record.pid !== 0 || record.evidence !== null) throw new Error("raw PM2 orphan unexpectedly has live process evidence");
}

async function startExplicit(app) {
  await call("start", {
    name: app.name,
    namespace: app.namespace,
    script: app.script,
    args: app.args,
    cwd: app.cwd,
    env: app.env,
    exec_mode: "fork",
    instances: 1,
    autorestart: false,
    watch: false,
    out_file: "/dev/null",
    error_file: "/dev/null",
    merge_logs: true,
  });
  const matches = (await inventory()).filter((record) => record.launchToken === app.env.RELEASE_MANAGER_LAUNCH_TOKEN);
  if (matches.length !== 1) throw new Error(`candidate start produced ${matches.length} owned records`);
  return matches[0];
}

async function main() {
  const request = await readStdin();
  if (request.action === "runtime-version") {
    return { nodeRuntime: process.version, pm2PackageVersion: pm2Package.version };
  }
  await connect();
  try {
    if (request.action === "inventory") return { records: await inventory() };
    if (request.action === "start" || request.action === "test-start") {
      return { record: await startExplicit(request.app) };
    }
    if (request.action === "stop" || request.action === "delete") {
      const records = await inventory();
      const record = records.find((item) => item.adapterId === String(request.expected.adapterId));
      assertExact(record, request.expected, request.action === "stop");
      await call(request.action, Number(request.expected.adapterId));
      return { ok: true };
    }
    if (request.action === "delete-raw-owned") {
      const records = await inventory();
      const matches = records.filter((item) => item.adapterId === String(request.expected.adapterId));
      if (matches.length !== 1) throw new Error("exact raw PM2 owned record not found");
      assertRawOwned(matches[0], request.expected);
      await call("delete", Number(request.expected.adapterId));
      return { ok: true };
    }
    if (request.action === "save") {
      await call("dump");
      return { ok: true };
    }
    if (request.action === "kill-daemon") {
      await call("killDaemon");
      return { ok: true };
    }
    throw new Error("unsupported bridge action");
  } finally {
    pm2.disconnect();
  }
}

main().then(
  (result) => process.stdout.write(JSON.stringify({ ok: true, ...result }), () => process.exit(0)),
  (error) => {
    const message = String(error && error.message ? error.message : error).replace(/[\r\n]+/g, " ").slice(0, 500);
    process.stdout.write(JSON.stringify({ ok: false, error: message }), () => process.exit(1));
  },
);
