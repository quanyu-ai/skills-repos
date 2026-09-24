#!/usr/bin/env node
"use strict";
const http = require("node:http");
const args = process.argv.slice(2);
if (args.shift() !== "start") process.exit(64);
let host;
let port;
while (args.length) {
  const flag = args.shift();
  const value = args.shift();
  if ((flag === "-H" || flag === "--hostname") && value) host = value;
  else if ((flag === "-p" || flag === "--port") && value) port = Number(value);
  else process.exit(64);
}
if (!host || !Number.isInteger(port)) process.exit(64);
http.createServer((_request, response) => {
  response.writeHead(200, {"content-type": "application/json"});
  response.end(JSON.stringify({ok: true}));
}).listen(port, host);
