// SPDX-License-Identifier: GPL-3.0-only
// One-command update for a server that runs FredPD straight from this clone (docs/dev-loop.md):
//   1. git pull --ff-only (skipped with --no-pull)
//   2. pnpm install --frozen-lockfile        only when the lockfile or a package.json changed (or node_modules is missing)
//   3. build: web apps + copy into resources only when apps/, packages/, locales/, config/, db/ or the build script changed
//      (Lua-only changes need no build; the server reads resources/[fredpd] directly)
//   4. upstream patches: applied in place to the server's own copies (FREDPD_SERVER_RESOURCES) when patch files changed
//   5. restart: over RCON when FREDPD_RCON_PASSWORD is set (fredpd_reload [patched upstreams]), else prints the
//      console command to type in txAdmin. The service is restarted with NSSM when apps/service changed (Windows).
// Flags: --force (do every step), --no-pull, --no-restart.
// Env: FREDPD_SERVER_RESOURCES (FXServer resources folder), FREDPD_RCON_PASSWORD, FREDPD_RCON_HOST (127.0.0.1), FREDPD_RCON_PORT (30120), FREDPD_SERVICE_NAME (fredpd_service).
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import dgram from 'node:dgram';

const root = resolve(import.meta.dirname, '..');
const args = process.argv.slice(2);
const force = args.includes('--force');
const shell = process.platform === 'win32';

function sh(cmd, argv, opts = {}) {
  const r = spawnSync(cmd, argv, { cwd: root, encoding: 'utf8', shell, ...opts });
  if (opts.stdio !== 'inherit' && r.status !== 0 && !opts.allowFail) {
    console.error(r.stdout || '', r.stderr || '');
  }
  return r;
}
function step(title) { console.log(`\n== ${title}`); }
function fail(msg) { console.error(`\nupdate: ${msg}`); process.exit(1); }

// 1. pull ------------------------------------------------------------------------------------------------------
const before = sh('git', ['rev-parse', 'HEAD']).stdout.trim();
if (!args.includes('--no-pull')) {
  step('git pull');
  const r = sh('git', ['pull', '--ff-only'], { stdio: 'inherit' });
  if (r.status !== 0) fail('git pull failed (local changes? run `git status`). Nothing else was done.');
}
const after = sh('git', ['rev-parse', 'HEAD']).stdout.trim();
const changed = before === after ? [] : sh('git', ['diff', '--name-only', before, after]).stdout.split('\n').filter(Boolean);
console.log(before === after ? 'already up to date' : `${changed.length} file(s) changed ${before.slice(0, 7)}..${after.slice(0, 7)}`);
const touched = (re) => force || changed.some((f) => re.test(f));

// 2. install ----------------------------------------------------------------------------------------------------
if (touched(/(^|\/)package\.json$|^pnpm-lock\.yaml$/) || !existsSync(join(root, 'node_modules'))) {
  step('pnpm install');
  if (sh('pnpm', ['install', '--frozen-lockfile'], { stdio: 'inherit' }).status !== 0) fail('pnpm install failed');
}

// 3. build ------------------------------------------------------------------------------------------------------
const webChanged = touched(/^(apps\/(nui|portal)|packages)\//) || !existsSync(join(root, 'apps', 'nui', 'dist'));
const copyChanged = touched(/^(locales|config|db|scripts\/build\.mjs)\//) || touched(/^packages\/types\/test\/fixtures\//);
if (webChanged || copyChanged) {
  step(webChanged ? 'build (web + copy)' : 'build (copy only)');
  const r = sh('node', ['scripts/build.mjs', ...(webChanged ? [] : ['--skip-web'])], { stdio: 'inherit' });
  if (r.status !== 0) fail('build failed');
}

// 4. patches: applied IN PLACE to the server's own copies (scripts/patch-server.mjs) -----------------------------
const patched = new Set();
for (const f of changed) {
  const m = /^patches\/([^.]+)\./.exec(f);
  if (m) patched.add(m[1]);
}
if (force) for (const f of sh('git', ['ls-files', 'patches']).stdout.split('\n')) { const m = /^patches\/([^.]+)\./.exec(f); if (m) patched.add(m[1]); }
patched.delete('qb-core'); // items are registered at runtime; qb-core is never patched live
const refetch = [...patched];
if (refetch.length) {
  step(`patches: ${refetch.join(', ')}`);
  const serverDir = process.env.FREDPD_SERVER_RESOURCES;
  if (!serverDir) {
    console.log('Set FREDPD_SERVER_RESOURCES to your FXServer resources folder to apply them automatically, or run:\n'
      + `    node scripts/patch-server.mjs --server "<resources folder>" --only ${refetch.join(',')}`);
  } else {
    const r = sh('node', ['scripts/patch-server.mjs', '--server', serverDir, '--only', refetch.join(','),
      ...(before !== after ? ['--since', before] : [])], { stdio: 'inherit' });
    if (r.status !== 0) console.log('Some patches did not apply (see above); the rest of the update continues.');
  }
}

// 5. restart ----------------------------------------------------------------------------------------------------
const serviceChanged = touched(/^(apps\/service|packages\/types)\//);
const liveRestartable = refetch.filter((n) => !['qb-core', 'qbx_core', 'ox_lib', 'oxmysql', 'ox_inventory', 'qb-inventory'].includes(n));
const needsServerRestart = refetch.filter((n) => !liveRestartable.includes(n));
const reloadCmd = ['fredpd_reload', ...liveRestartable].join(' ');

function rcon(command) {
  const password = process.env.FREDPD_RCON_PASSWORD;
  if (!password) return Promise.resolve(null);
  const host = process.env.FREDPD_RCON_HOST || '127.0.0.1';
  const port = Number(process.env.FREDPD_RCON_PORT || 30120);
  return new Promise((done) => {
    const sock = dgram.createSocket('udp4');
    const msg = Buffer.concat([Buffer.from([0xff, 0xff, 0xff, 0xff]), Buffer.from(`rcon ${password} ${command}`)]);
    const timer = setTimeout(() => { sock.close(); done('no answer (is rcon_password set in server.cfg?)'); }, 3000);
    sock.on('message', (buf) => { clearTimeout(timer); sock.close(); done(buf.subarray(4).toString('utf8').replace(/^print\n?/, '').trim() || 'ok'); });
    sock.send(msg, port, host, (err) => { if (err) { clearTimeout(timer); sock.close(); done(`send failed: ${err.message}`); } });
  });
}

if (!args.includes('--no-restart') && (changed.length || force)) {
  step('restart');
  const answer = await rcon(reloadCmd);
  if (answer === null) console.log(`Type this in the txAdmin live console:\n\n    ${reloadCmd}\n\n(or set FREDPD_RCON_PASSWORD to do it automatically)`);
  else console.log(`rcon ${reloadCmd}: ${answer}`);
  if (needsServerRestart.length) console.log(`Restart the whole server for: ${needsServerRestart.join(', ')} (cannot be reloaded live)`);
  if (serviceChanged) {
    const name = process.env.FREDPD_SERVICE_NAME || 'fredpd_service';
    if (process.platform === 'win32' && sh('nssm', ['status', name], { allowFail: true }).status === 0) {
      console.log(sh('nssm', ['restart', name], { allowFail: true }).stdout || `restarted ${name}`);
    } else {
      console.log(`The service changed: restart it (Windows: nssm restart ${name}; dev: cd apps/service && pnpm start).`);
    }
  }
}
console.log('\nupdate: done');
