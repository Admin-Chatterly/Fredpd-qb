// SPDX-License-Identifier: GPL-3.0-only
// One-time setup (docs/dev-loop.md): make the FXServer's resources\[fredpd] a directory junction to this clone's
// resources\[fredpd], so scripts/update.mjs updates the running server without copying anything. An existing
// [fredpd] folder is MOVED next to the resources folder (never deleted). Works in Command Prompt and PowerShell.
//
//   node scripts/link-server.mjs --server "C:\Users\FiveM\Desktop\SalamDevQB\resources"
import { existsSync, lstatSync, readlinkSync, renameSync, symlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const args = process.argv.slice(2);
const serverDir = args.includes('--server') ? args[args.indexOf('--server') + 1] : process.env.FREDPD_SERVER_RESOURCES;
if (!serverDir || !existsSync(serverDir)) {
  console.error('link-server: --server "<FXServer resources folder>" is required (and must exist)');
  process.exit(2);
}

const target = join(root, 'resources', '[fredpd]');
const link = join(serverDir, '[fredpd]');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');

let stat = null;
try { stat = lstatSync(link); } catch { /* does not exist */ }

if (stat && stat.isSymbolicLink()) {
  console.log(`ok     ${link} is already a link -> ${readlinkSync(link)}`);
} else {
  if (stat) {
    // Move the old folder OUT of resources\ so FXServer doesn't find duplicate fredpd_* resources.
    const backup = join(dirname(resolve(serverDir)), `[fredpd].bak-${stamp}`);
    renameSync(link, backup);
    console.log(`backup ${link} -> ${backup}`);
  }
  symlinkSync(target, link, 'junction'); // 'junction' on Windows needs no admin rights; a symlink elsewhere
  console.log(`link   ${link} -> ${target}`);
}

const dup = join(serverDir, '[upstream]');
if (existsSync(dup)) console.warn(`\nWARNING: ${dup} exists on the server. Delete it (it causes duplicate resources).`);
console.log('\nDone. Next: node scripts/patch-server.mjs --server "<same folder>"');
