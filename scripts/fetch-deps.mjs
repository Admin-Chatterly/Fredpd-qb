// SPDX-License-Identifier: GPL-3.0-only
// Clones every upstream resource listed in deps.lock.json at its pinned commit into resources/[upstream]/<name>.
// Idempotent: a checkout already at the pinned commit is left alone. Never tracks "latest" (IMPLEMENTATION.md §8.2).
// Usage: node scripts/fetch-deps.mjs [--only name,name] [--force]
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '..');
const lock = JSON.parse(readFileSync(join(root, 'deps.lock.json'), 'utf8'));
const dest = join(root, 'resources', '[upstream]');
const args = process.argv.slice(2);
const only = args.includes('--only') ? args[args.indexOf('--only') + 1].split(',') : null;
const force = args.includes('--force');

function git(cwd, ...a) {
  const r = spawnSync('git', a, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`git ${a.join(' ')} failed in ${cwd}:\n${r.stderr}`);
  return r.stdout.trim();
}

mkdirSync(dest, { recursive: true });
let failed = 0;
for (const [name, dep] of Object.entries(lock.resources)) {
  if (only && !only.includes(name)) continue;
  if (dep.mode === 'REFERENCE') { console.log(`skip  ${name} (reference only)`); continue; }
  if (!/^[0-9a-f]{40}$/.test(dep.commit)) { console.error(`error ${name}: commit must be a full 40-char sha`); failed++; continue; }
  const dir = join(dest, name);
  try {
    if (existsSync(join(dir, '.git'))) {
      const head = git(dir, 'rev-parse', 'HEAD');
      if (head === dep.commit && !force) { console.log(`ok    ${name} @ ${head.slice(0, 10)}`); continue; }
      if (git(dir, 'status', '--porcelain') && !force) {
        throw new Error('working tree has changes (patched?); re-run with --force to reset it');
      }
    } else if (existsSync(dir)) {
      rmSync(dir, { recursive: true, force: true });
    }
    if (!existsSync(join(dir, '.git'))) {
      mkdirSync(dir, { recursive: true });
      git(dir, 'init', '-q');
      git(dir, 'remote', 'add', 'origin', dep.repo);
    }
    git(dir, 'fetch', '-q', '--depth', '1', 'origin', dep.commit);
    git(dir, 'checkout', '-q', '--force', 'FETCH_HEAD');
    git(dir, 'clean', '-qfdx');
    console.log(`fetch ${name} @ ${dep.commit.slice(0, 10)}`);
  } catch (e) {
    failed++;
    console.error(`error ${name}: ${e.message}`);
  }
}
if (failed) { console.error(`${failed} dependency(ies) failed`); process.exit(1); }
console.log('Done. Next: scripts/apply-patches.sh');
