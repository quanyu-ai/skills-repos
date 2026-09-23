const fs = require('node:fs');

const secretFile = process.env.RUNTIME_SECRET_FILE;
const required = (process.env.REQUIRED_RUNTIME_SECRETS || '').split(',').filter(Boolean);
const executable = process.env.LEGACY_EXECUTABLE;
const args = JSON.parse(process.env.LEGACY_ARGS_JSON || '[]');
const host = process.env.LEGACY_HOST;
const port = process.env.LEGACY_INTERNAL_PORT;

if (!secretFile || !executable || !host || !port) throw new Error('Incomplete legacy bootstrap runtime metadata');
const stat = fs.statSync(secretFile);
if ((stat.mode & 0o077) !== 0) throw new Error('Runtime secret file permissions are too broad');
const secrets = JSON.parse(fs.readFileSync(secretFile, 'utf8'));
for (const name of required) {
  if (typeof secrets[name] !== 'string' || secrets[name].length === 0) throw new Error(`Missing runtime secret: ${name}`);
  process.env[name] = secrets[name];
}

process.argv = [process.execPath, executable, ...args, '-H', host, '-p', port];
require(executable);
