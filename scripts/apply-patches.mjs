// SPDX-License-Identifier: GPL-3.0-only
// Applies patches/<resource>.patch to resources/[upstream]/<resource> (IMPLEMENTATION.md §0 rule 8).
// Runs `git apply --check` first; a patch that is already applied (reverse-check passes) is skipped.
// A patch file may also be named <resource>.<nn>-<topic>.patch; they are applied in name order.
import { existsSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '..');
const patchDir = join(root, 'patches');
const upstream = join(root, 'resources', '[upstream]');
const files = existsSync(patchDir) ? readdirSync(patchDir).filter((f) => f.endsWith('.patch')).sort() : [];

const run = (cwd, ...a) => spawnSync('git', a, { cwd, encoding: 'utf8' });
let failed = 0;
for (const file of files) {
  const resource = file.replace(/\.patch$/, '').split('.')[0];
  const dir = join(upstream, resource);
  const patch = join(patchDir, file);
  if (!existsSync(dir)) { console.error(`error ${file}: ${dir} missing (run scripts/fetch-deps.sh)`); failed++; continue; }
  if (run(dir, 'apply', '--reverse', '--check', patch).status === 0) { console.log(`ok    ${file} (already applied)`); continue; }
  const check = run(dir, 'apply', '--check', patch);
  if (check.status !== 0) { console.error(`error ${file}: does not apply cleanly\n${check.stderr}`); failed++; continue; }
  const res = run(dir, 'apply', patch);
  if (res.status !== 0) { console.error(`error ${file}: ${res.stderr}`); failed++; continue; }
  console.log(`apply ${file}`);
}
if (!files.length) console.log('no patches');
process.exit(failed ? 1 : 0);
