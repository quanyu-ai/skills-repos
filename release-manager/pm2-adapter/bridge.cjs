"use strict";

const fs = require("node:fs");
const crypto = require("node:crypto");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const pm2 = require("pm2");
const pm2Package = require("pm2/package.json");

const FORBIDDEN_DAEMON_ENV = ["NODE_CHANNEL_FD", "NODE_UNIQUE_ID"];

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

function connect(noDaemon = false) {
  return new Promise((resolve, reject) => pm2.connect(noDaemon, (error) => error ? reject(error) : resolve()));
}

function disconnect() {
  try { pm2.disconnect(); } catch (_) {}
}

function fileDigest(file) {
  if (!fs.existsSync(file)) return null;
  return `sha256:${crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex")}`;
}

function daemonPid() {
  const file = path.join(process.env.PM2_HOME, "pm2.pid");
  if (!fs.existsSync(file)) throw new Error("connected PM2 daemon pid file is unavailable");
  const pid = Number(fs.readFileSync(file, "utf8").trim());
  if (!Number.isSafeInteger(pid) || pid <= 0 || !fs.existsSync(`/proc/${pid}/stat`)) {
    throw new Error("connected PM2 daemon PID is not live");
  }
  return pid;
}

function daemonAttestation() {
  const pid = daemonPid();
  const evidence = processEvidence(pid);
  const command = fs.readFileSync(`/proc/${pid}/cmdline`).toString("utf8").split("\0").filter(Boolean).join(" ");
  const versionMatch = command.match(/PM2 v([^: ]+): God Daemon/);
  if (!versionMatch) throw new Error("connected process is not an identifiable PM2 daemon");
  const executable = fs.realpathSync(`/proc/${pid}/exe`);
  const version = spawnSync(executable, ["--version"], {
    encoding: "utf8",
    env: { PATH: process.env.PATH || "" },
    timeout: 5000,
  });
  if (version.status !== 0) throw new Error("connected PM2 daemon Node runtime is not determinable");
  const ambientNames = fs.readFileSync(`/proc/${pid}/environ`).toString("utf8")
    .split("\0").filter(Boolean).map((item) => item.split("=", 1)[0]).sort();
  return {
    daemonPm2Version: versionMatch[1],
    daemonPid: pid,
    daemonProcessStartId: evidence.processStartId,
    daemonNodeExecutable: executable,
    daemonNodeRuntime: version.stdout.trim(),
    ambientEnvironmentNames: ambientNames,
    forbiddenAmbientNames: FORBIDDEN_DAEMON_ENV.filter((name) => ambientNames.includes(name)),
  };
}

async function waitDaemonAbsent(pid) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (!fs.existsSync(`/proc/${pid}/stat`)) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("previous PM2 daemon did not become absent");
}

async function waitDaemonReady() {
  const pidFile = path.join(process.env.PM2_HOME, "pm2.pid");
  const rpcSocket = path.join(process.env.PM2_HOME, "rpc.sock");
  const pubSocket = path.join(process.env.PM2_HOME, "pub.sock");
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (fs.existsSync(pidFile) && fs.existsSync(rpcSocket) && fs.existsSync(pubSocket)) {
      try {
        return daemonAttestation();
      } catch (error) {
        if (!error || !["ENOENT", "ESRCH"].includes(error.code)) throw error;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("pinned PM2 daemon did not become ready");
}

function launchPinnedDaemonWithoutIpc() {
  const daemonEntry = require.resolve("pm2/lib/Daemon.js");
  const logFile = path.join(process.env.PM2_HOME, "pm2.log");
  fs.mkdirSync(process.env.PM2_HOME, { recursive: true, mode: 0o700 });
  const log = fs.openSync(logFile, "a", 0o600);
  const environment = {
    HOME: process.env.HOME,
    PATH: process.env.PATH,
    PM2_HOME: process.env.PM2_HOME,
    NODE_PATH: process.env.NODE_PATH,
    SILENT: "true",
  };
  const child = spawn(process.execPath, [daemonEntry], {
    detached: true,
    cwd: process.env.PM2_HOME,
    windowsHide: true,
    env: environment,
    stdio: ["ignore", log, log],
  });
  fs.closeSync(log);
  child.unref();
}

async function bootstrapDaemon(restart) {
  const dump = path.join(process.env.PM2_HOME, "dump.pm2");
  const dumpBefore = fileDigest(dump);
  const pidFile = path.join(process.env.PM2_HOME, "pm2.pid");
  if (restart && fs.existsSync(pidFile)) {
    const priorPid = daemonPid();
    await connect();
    await call("killDaemon");
    disconnect();
    await waitDaemonAbsent(priorPid);
  } else if (!restart && fs.existsSync(pidFile)) {
    throw new Error("PM2 daemon already exists; explicit restart is required");
  }
  launchPinnedDaemonWithoutIpc();
  const attestation = await waitDaemonReady();
  await connect();
  disconnect();
  const dumpAfter = fileDigest(dump);
  if (dumpAfter !== dumpBefore) throw new Error("PM2 daemon bootstrap changed the persisted dump");
  return { ...attestation, dumpDigest: dumpAfter, dumpPreserved: true };
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
    exitCode: Number.isInteger(env.exit_code) ? env.exit_code : null,
    exitSignal: typeof env.exit_signal === "string" ? env.exit_signal : null,
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
    out_file: app.outFile || "/dev/null",
    error_file: app.errorFile || "/dev/null",
    merge_logs: true,
  });
  const matches = (await inventory()).filter((record) => record.launchToken === app.env.RELEASE_MANAGER_LAUNCH_TOKEN);
  if (matches.length !== 1) throw new Error(`candidate start produced ${matches.length} owned records`);
  return matches[0];
}

async function main() {
  const request = await readStdin();
  if (request.action === "runtime-version") {
    return {
      nodeRuntime: process.version,
      nodeExecutable: fs.realpathSync(process.execPath),
      pm2PackageVersion: pm2Package.version,
    };
  }
  if (request.action === "daemon-attestation") {
    return { daemon: daemonAttestation() };
  }
  if (request.action === "bootstrap-daemon") {
    return { daemon: await bootstrapDaemon(request.restart === true) };
  }
  // Inventory is the Operator read path. noDaemon=true guarantees a vanished
  // daemon is never recreated by a supposedly read-only call.
  await connect(request.action === "inventory");
  try {
    if (request.action === "inventory") return { records: await inventory(), daemon: daemonAttestation() };
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
    disconnect();
  }
}

main().then(
  (result) => process.stdout.write(JSON.stringify({ ok: true, ...result }), () => process.exit(0)),
  (error) => {
    const message = String(error && error.message ? error.message : error).replace(/[\r\n]+/g, " ").slice(0, 500);
    process.stdout.write(JSON.stringify({ ok: false, error: message }), () => process.exit(1));
  },
);
