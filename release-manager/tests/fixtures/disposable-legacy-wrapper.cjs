"use strict";
const fs = require("node:fs");
const {spawn} = require("node:child_process");
const rawRequired = process.env.REQUIRED_RUNTIME_SECRETS || "";
const required = rawRequired.trim().startsWith("[")
  ? JSON.parse(rawRequired)
  : rawRequired.split(",").filter(Boolean);
const secrets = JSON.parse(fs.readFileSync(process.env.RUNTIME_SECRET_FILE, "utf8"));
if (required.some((name) => !secrets[name])) process.exit(64);
const host = process.env.LEGACY_HOST;
const port = Number(process.env.LEGACY_INTERNAL_PORT);
const executable = process.env.LEGACY_EXECUTABLE;
const args = JSON.parse(process.env.LEGACY_ARGS_JSON || "[]");
if (!executable || !host || !Number.isInteger(port)) process.exit(64);
const child = spawn(executable, [...args, "-H", host, "-p", String(port)], {
  env: process.env,
  stdio: "inherit",
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("error", () => process.exit(64));
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 64);
});
