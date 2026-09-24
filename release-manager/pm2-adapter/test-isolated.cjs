"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");

const bridge = path.join(__dirname, "bridge.cjs");
const httpFixture = path.join(__dirname, "../tests/fixtures/disposable-http-service.cjs");
const idleFixture = path.join(__dirname, "../tests/fixtures/disposable-idle-service.cjs");

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function context() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "env1b-c-node-"));
  const pm2Home = path.join(root, "pm2-home");
  return { root, pm2Home };
}

function invoke(ctx, request, expectedSuccess = true) {
  const result = spawnSync(process.execPath, [bridge], {
    input: JSON.stringify(request),
    encoding: "utf8",
    env: {
      HOME: ctx.pm2Home,
      PATH: "/usr/local/bin:/usr/bin:/bin",
      PM2_HOME: ctx.pm2Home,
      NODE_PATH: path.join(__dirname, "node_modules"),
    },
    timeout: 30000,
  });
  let response;
  try { response = JSON.parse(result.stdout); } catch (_) {
    throw new Error(`bridge returned invalid JSON (exit ${result.status})`);
  }
  if (expectedSuccess) assert.equal(response.ok, true, response.error);
  else assert.equal(response.ok, false);
  return response;
}

function release(ctx, sha, status = 200) {
  const root = path.join(ctx.root, "releases", sha);
  fs.mkdirSync(root, { recursive: true });
  const script = path.join(root, "service.cjs");
  fs.copyFileSync(httpFixture, script);
  return { root, script, status };
}

function app(releaseSpec, port, token, name = "env1b-c-service", namespace = "env1b-c-isolated") {
  return {
    name,
    namespace,
    script: releaseSpec.script,
    args: [],
    cwd: releaseSpec.root,
    env: {
      HOST: "127.0.0.1",
      PORT: String(port),
      TEST_SECRET: "fake-secret-must-not-appear",
      TEST_HEALTH_STATUS: String(releaseSpec.status),
      RELEASE_MANAGER_ENVIRONMENT_ID: "env1b-c-test",
      RELEASE_MANAGER_SERVICE_ID: "disposable-web",
      RELEASE_MANAGER_RELEASE_SHA: path.basename(releaseSpec.root),
      RELEASE_MANAGER_LAUNCH_TOKEN: token,
      RELEASE_MANAGER_OWNED_HOST: "127.0.0.1",
      RELEASE_MANAGER_OWNED_PORT: String(port),
    },
  };
}

function expected(record) {
  return {
    adapterId: record.adapterId,
    pid: record.pid,
    processStartId: record.evidence.processStartId,
    name: record.name,
    namespace: record.namespace,
    environmentId: record.environmentId,
    serviceId: record.serviceId,
    releaseSha: record.releaseSha,
    executable: record.executable,
    cwd: record.cwd,
    args: record.args,
  };
}

async function status(url) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      return await new Promise((resolve, reject) => {
        const request = http.get(url, { timeout: 1000 }, (response) => {
          response.resume();
          response.on("end", () => resolve(response.statusCode));
        });
        request.on("error", reject);
        request.on("timeout", () => request.destroy(new Error("timeout")));
      });
    } catch (_) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error("health endpoint did not respond");
}

function cleanup(ctx) {
  try { invoke(ctx, { action: "kill-daemon" }); } catch (_) {}
  fs.rmSync(ctx.root, { recursive: true, force: true });
}

test("explicit process object yields exact proc-backed record without secret output", async () => {
  const ctx = context();
  try {
    const spec = release(ctx, "a".repeat(40));
    const port = await freePort();
    const response = invoke(ctx, { action: "start", app: app(spec, port, "start-a") });
    const serialized = JSON.stringify(response);
    assert.equal(serialized.includes("fake-secret-must-not-appear"), false);
    assert.equal(response.record.name, "env1b-c-service");
    assert.equal(response.record.namespace, "env1b-c-isolated");
    assert.equal(response.record.releaseSha, "a".repeat(40));
    assert.ok(response.record.pid > 0);
    assert.ok(response.record.evidence.processStartId);
    assert.equal(response.record.evidence.procCwd, spec.root);
    assert.equal(path.basename(response.record.evidence.procExe), "node");
    assert.ok(response.record.evidence.procCmdline.some((item) => item.endsWith("ProcessContainerFork.js")));
    assert.equal(await status(`http://127.0.0.1:${port}/health`), 200);
    invoke(ctx, { action: "save" });
  } finally { cleanup(ctx); }
});

test("stop retains record while delete plus pid and port checks prove absence", async () => {
  const ctx = context();
  try {
    const spec = release(ctx, "b".repeat(40));
    const port = await freePort();
    const record = invoke(ctx, { action: "start", app: app(spec, port, "start-b") }).record;
    invoke(ctx, { action: "stop", expected: expected(record) });
    const stopped = invoke(ctx, { action: "inventory" }).records.find((item) => item.adapterId === record.adapterId);
    assert.equal(stopped.status, "stopped");
    invoke(ctx, { action: "delete", expected: expected(record) });
    const remaining = invoke(ctx, { action: "inventory" }).records;
    assert.equal(remaining.some((item) => item.adapterId === record.adapterId), false);
    assert.equal(fs.existsSync(`/proc/${record.pid}/stat`), false);
    const rebound = net.createServer();
    await new Promise((resolve, reject) => rebound.once("error", reject).listen(port, "127.0.0.1", resolve));
    await new Promise((resolve) => rebound.close(resolve));
  } finally { cleanup(ctx); }
});

test("raw orphan delete requires exact launch token, ownership and pidless evidence", async () => {
  const ctx = context();
  try {
    const spec = release(ctx, "e".repeat(40));
    const port = await freePort();
    const record = invoke(ctx, { action: "start", app: app(spec, port, "raw-owned-e") }).record;
    invoke(ctx, { action: "stop", expected: expected(record) });
    const raw = invoke(ctx, { action: "inventory" }).records.find((item) => item.adapterId === record.adapterId);
    assert.equal(raw.pid, 0);
    assert.equal(raw.evidence, null);
    const tampered = { ...raw, launchToken: "wrong-token" };
    invoke(ctx, { action: "delete-raw-owned", expected: tampered }, false);
    assert.equal(invoke(ctx, { action: "inventory" }).records.some((item) => item.adapterId === record.adapterId), true);
    invoke(ctx, { action: "delete-raw-owned", expected: raw });
    assert.equal(invoke(ctx, { action: "inventory" }).records.some((item) => item.adapterId === record.adapterId), false);
  } finally { cleanup(ctx); }
});

test("ecosystem.cjs wrong-name and duplicate script/namespace records remain visible", async () => {
  const ctx = context();
  try {
    const cwd = path.join(ctx.root, "residual");
    fs.mkdirSync(cwd);
    const ecosystem = path.join(cwd, "ecosystem.cjs");
    fs.copyFileSync(idleFixture, ecosystem);
    const first = app({ root: cwd, script: ecosystem, status: 200 }, await freePort(), "residual-a", "ecosystem", "env1b-c-isolated");
    const second = app({ root: cwd, script: ecosystem, status: 200 }, await freePort(), "residual-b", "duplicate", "env1b-c-other");
    invoke(ctx, { action: "test-start", app: first });
    invoke(ctx, { action: "test-start", app: second });
    const records = invoke(ctx, { action: "inventory" }).records;
    assert.equal(records.filter((item) => item.executable === ecosystem).length, 2);
    assert.ok(records.some((item) => item.name === "ecosystem"));
    assert.ok(records.some((item) => item.namespace === "env1b-c-other"));
  } finally { cleanup(ctx); }
});

test("health failure candidate is deleted before exact prior invocation is restored", async () => {
  const ctx = context();
  try {
    const currentSpec = release(ctx, "c".repeat(40), 200);
    const currentPort = await freePort();
    const currentApp = app(currentSpec, currentPort, "current-c");
    const current = invoke(ctx, { action: "start", app: currentApp }).record;
    assert.equal(await status(`http://127.0.0.1:${currentPort}/health`), 200);
    invoke(ctx, { action: "stop", expected: expected(current) });
    invoke(ctx, { action: "delete", expected: expected(current) });

    const failedSpec = release(ctx, "d".repeat(40), 503);
    const failedPort = await freePort();
    const failed = invoke(ctx, { action: "start", app: app(failedSpec, failedPort, "failed-d") }).record;
    assert.equal(await status(`http://127.0.0.1:${failedPort}/health`), 503);
    invoke(ctx, { action: "stop", expected: expected(failed) });
    invoke(ctx, { action: "delete", expected: expected(failed) });

    currentApp.env.RELEASE_MANAGER_LAUNCH_TOKEN = "restored-c";
    const restored = invoke(ctx, { action: "start", app: currentApp }).record;
    assert.equal(restored.releaseSha, "c".repeat(40));
    assert.equal(await status(`http://127.0.0.1:${currentPort}/health`), 200);
    const online = invoke(ctx, { action: "inventory" }).records.filter((item) => item.status === "online");
    assert.deepEqual(online.map((item) => item.releaseSha), ["c".repeat(40)]);
  } finally { cleanup(ctx); }
});
