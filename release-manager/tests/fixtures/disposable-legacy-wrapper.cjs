"use strict";
const http = require("node:http");
const fs = require("node:fs");
const required = JSON.parse(process.env.REQUIRED_RUNTIME_SECRETS || "[]");
const secrets = JSON.parse(fs.readFileSync(process.env.RUNTIME_SECRET_FILE, "utf8"));
if (required.some((name) => !secrets[name])) process.exit(64);
const host = process.env.LEGACY_HOST;
const port = Number(process.env.LEGACY_INTERNAL_PORT);
http.createServer((_request, response) => {
  response.writeHead(200, {"content-type": "application/json"});
  response.end(JSON.stringify({ok: true}));
}).listen(port, host);
