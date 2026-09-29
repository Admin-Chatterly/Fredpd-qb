// SPDX-License-Identifier: GPL-3.0-only
// Lua lint for FredPD resources:
//  1. syntax check every .lua file under resources/[fredpd] and tests/lua with luac -p
//  2. reject idle polling loops (IMPLEMENTATION.md §0 rule 3): `while true` and Citizen.CreateThread.
//     A line may opt out with a trailing `-- lint-allow-loop: <reason>` comment (reviewer checks the reason).
//  3. every FredPD source file (.lua .ts .tsx .js .mjs .cjs .sh .ps1 .sql .css outside node_modules, vendored and
//     generated folders) carries `SPDX-License-Identifier: GPL-3.0-only` in its first lines (CLAUDE.md; licence
//     GPL-3.0). Vendored code (tests/lua/vendor) keeps its own licence header and is not checked.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const roots = ['resources/[fredpd]', 'tests/lua'];
const files = [];
function walk(dir) {
  let entries;
  try { entries = readdirSync(dir); } catch { return; }
  for (const name of entries) {
    if (name === 'node_modules' || name === 'vendor') continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p);
    else if (p.endsWith('.lua')) files.push(p);
  }
}
roots.forEach(walk);

let errors = 0;
const luac = ['luac5.4', 'luac54', 'luac'].find((b) => spawnSync(b, ['-v']).status === 0);
if (!luac) console.warn('[lint-lua] luac not found; skipping syntax check');

const banned = [/\bwhile\s+true\s+do\b/, /\bCitizen\.CreateThread\b/];
for (const f of files) {
  if (luac) {
    const r = spawnSync(luac, ['-p', f], { encoding: 'utf8' });
    if (r.status !== 0) { errors++; console.error(r.stderr.trim()); }
  }
  const lines = readFileSync(f, 'utf8').split('\n');
  lines.forEach((line, i) => {
    if (line.includes('lint-allow-loop:')) return;
    const code = line.replace(/--.*$/, '');
    for (const re of banned) {
      if (re.test(code)) { errors++; console.error(`${f}:${i + 1}: polling loop not allowed (${re.source})`); }
    }
  });
}
// 3. SPDX headers
const SPDX = 'SPDX-License-Identifier: GPL-3.0-only';
const SPDX_EXT = /\.(lua|ts|tsx|js|mjs|cjs|sh|ps1|sql|css)$/;
const SPDX_SKIP_DIRS = new Set(['node_modules', 'vendor', 'dist', 'build', 'coverage', '.git']);
// Generated or copied by scripts/build.mjs / fetched upstream (git-ignored).
const SPDX_SKIP_PATHS = new Set([
  join('resources', '[upstream]'), join('apps', 'service', 'data'),
  join('resources', '[fredpd]', 'fredpd_core', 'migrations'), join('resources', '[fredpd]', 'fredpd_core', 'config'),
  join('resources', '[fredpd]', 'fredpd_devtools', 'fixtures'),
]);
const spdxFiles = ['eslint.config.js', 'vitest.config.ts'];
function walkSpdx(dir) {
  let entries;
  try { entries = readdirSync(dir); } catch { return; }
  for (const name of entries) {
    const p = join(dir, name);
    if (SPDX_SKIP_DIRS.has(name) || SPDX_SKIP_PATHS.has(p)) continue;
    if (/^resources[\\/]\[fredpd\][\\/][^\\/]+[\\/]locales$/.test(p)) continue;
    if (statSync(p).isDirectory()) walkSpdx(p);
    else if (SPDX_EXT.test(name)) spdxFiles.push(p);
  }
}
['resources', 'apps', 'packages', 'scripts', 'tests', 'db'].forEach(walkSpdx);
for (const f of spdxFiles) {
  let head;
  try { head = readFileSync(f, 'utf8').split('\n').slice(0, 3).join('\n'); } catch { continue; }
  if (!head.includes(SPDX)) { errors++; console.error(`${f}:1: missing "${SPDX}" header`); }
}

console.log(`[lint-lua] ${files.length} files checked, ${spdxFiles.length} SPDX headers checked, ${errors} problem(s)`);
process.exit(errors ? 1 : 0);
