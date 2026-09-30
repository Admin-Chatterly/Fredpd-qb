// SPDX-License-Identifier: GPL-3.0-only
// Apply FredPD's patches/*.patch IN PLACE to the server's own copies of the upstream resources (docs/dev-loop.md),
// instead of replacing them with clean upstream checkouts: the server keeps its own configs (door lists, police
// locations, items, jobs). Every file a patch touches is backed up first to .server-backups/ (git-ignored).
//
//   node scripts/patch-server.mjs --server "C:\...\resources" [--only qb-policejob,ps-dispatch] [--since <git-rev>] [--dry-run]
//
// Per patch: already applied (reverse-applies) -> skipped; applies cleanly -> backed up + applied; does not apply
// (the server's copy was customised in the same place) -> reported with git's reason, nothing changed for it.
// --since <rev>: for patch files that changed since <rev>, the OLD version is reverted first (if applied), so an
// updated patch replaces its previous version. scripts/update.mjs passes this automatically.
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';

const root = resolve(import.meta.dirname, '..');
const args = process.argv.slice(2);
const opt = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const serverDir = opt('--server') || process.env.FREDPD_SERVER_RESOURCES;
const only = opt('--only') ? opt('--only').split(',') : null;
const since = opt('--since');
const dryRun = args.includes('--dry-run');
if (!serverDir || !existsSync(serverDir)) {
  console.error('patch-server: --server <FXServer resources folder> (or env FREDPD_SERVER_RESOURCES) is required');
  process.exit(2);
}

/** Folder names a patched resource may have on a server (txAdmin's Qbox recipe installs qbx_police as 'qbx_police'). */
const ALIASES = { qbx_policejob: ['qbx_police'] };

/** Find a resource folder by name (or alias) under the server's resources (category folders like [qb] included). */
function findResource(name) {
  for (const candidate of [name, ...(ALIASES[name] || [])]) {
    const found = findFolder(candidate);
    if (found) return found;
  }
  return null;
}

function findFolder(name) {
  const queue = [[serverDir, 0]];
  while (queue.length) {
    const [dir, depth] = queue.shift();
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (!e.isDirectory() && !e.isSymbolicLink()) continue;
      if (e.name === '[upstream]' || e.name === '[fredpd]' || e.name.includes('.bak-')) continue;
      const p = join(dir, e.name);
      if (e.name === name && existsSync(join(p, 'fxmanifest.lua'))) return p;
      if (e.name.startsWith('[') && depth < 3) queue.push([p, depth + 1]);
    }
  }
  return null;
}

/** git apply outside any repository (GIT_CEILING_DIRECTORIES stops repo discovery above the resource). */
function gitApply(dir, patchFile, extra = []) {
  return spawnSync('git', ['apply', ...extra, patchFile], {
    cwd: dir, encoding: 'utf8', env: { ...process.env, GIT_CEILING_DIRECTORIES: dirname(dir) },
  });
}
const touchedFiles = (text) => [...text.matchAll(/^\+\+\+ b\/(.+)$/gm)].map((m) => m[1]);

const stamp = new Date().toISOString().replace(/[:.]/g, '-');
function backup(resource, dir, files) {
  for (const f of files) {
    const src = join(dir, f);
    if (!existsSync(src)) continue;
    const dst = join(root, '.server-backups', resource, stamp, f);
    mkdirSync(dirname(dst), { recursive: true });
    cpSync(src, dst);
  }
}

const patchFiles = readdirSync(join(root, 'patches')).filter((f) => f.endsWith('.patch')).sort();
const byResource = new Map();
for (const f of patchFiles) {
  const resource = f.split('.')[0];
  if (only && !only.includes(resource)) continue;
  // qb-core is never patched on a live server: FredPD registers pd_tablet/pd_ram at runtime (bridge
  // inventory/qb_inventory.lua ensureItems via qb-core's AddItem export). The patch file stays for reference/tests.
  if (!only && resource === 'qb-core') continue;
  if (!byResource.has(resource)) byResource.set(resource, []);
  byResource.get(resource).push(f);
}

let failed = 0;
for (const [resource, files] of byResource) {
  const dir = findResource(resource);
  if (!dir) { console.log(`skip  ${resource} (not on this server)`); continue; }
  for (const f of files) {
    const patch = join(root, 'patches', f);
    const text = readFileSync(patch, 'utf8');
    // Revert the previous version of a changed patch first.
    if (since) {
      const old = spawnSync('git', ['show', `${since}:patches/${f}`], { cwd: root, encoding: 'utf8' });
      if (old.status === 0 && old.stdout !== text) {
        const oldFile = join(tmpdir(), `fredpd-old-${process.pid}-${f}`);
        writeFileSync(oldFile, old.stdout);
        if (gitApply(dir, oldFile, ['--reverse', '--check']).status === 0) {
          console.log(`revert ${f} (previous version) in ${dir}`);
          if (!dryRun) { backup(resource, dir, touchedFiles(old.stdout)); gitApply(dir, oldFile, ['--reverse']); }
        }
      }
    }
    if (gitApply(dir, patch, ['--reverse', '--check']).status === 0) { console.log(`ok    ${f} (already applied)`); continue; }
    const check = gitApply(dir, patch, ['--check']);
    if (check.status !== 0) {
      failed++;
      console.error(`FAIL  ${f} does not apply to ${dir}:\n${check.stderr.trim()}\n      (that file was customised; apply the hunk by hand or ask for help)`);
      continue;
    }
    if (dryRun) { console.log(`would apply ${f} -> ${dir}`); continue; }
    backup(resource, dir, touchedFiles(text));
    const r = gitApply(dir, patch);
    if (r.status !== 0) { failed++; console.error(`FAIL  ${f}: ${r.stderr}`); continue; }
    console.log(`apply ${f} -> ${dir}`);
  }
}
if (!dryRun && existsSync(join(root, '.server-backups'))) console.log(`backups: ${join(root, '.server-backups')}`);
process.exit(failed ? 1 : 0);
