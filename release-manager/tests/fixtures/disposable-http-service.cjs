"use strict";

const fs = require("node:fs");
const http = require("node:http");

const host = process.env.HOST;
const port = Number(process.env.PORT);
const status = Number(process.env.TEST_HEALTH_STATUS || "200");

if (process.env.TEST_ENV_REPORT) {
  fs.writeFileSync(process.env.TEST_ENV_REPORT, JSON.stringify({
    hasNodeChannelFd: Object.hasOwn(process.env, "NODE_CHANNEL_FD"),
    hasNodeUniqueId: Object.hasOwn(process.env, "NODE_UNIQUE_ID"),
    hasAmbientPoison: Object.hasOwn(process.env, "AMBIENT_POISON"),
  }));
}

http.createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: status >= 200 && status < 300 }));
    return;
  }
  response.writeHead(404);
  response.end();
}).listen(port, host);
