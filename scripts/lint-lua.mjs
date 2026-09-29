// Lua lint for FredPD resources:
//  1. syntax check every .lua file under resources/[fredpd] and tests/lua with luac -p
//  2. reject idle polling loops (IMPLEMENTATION.md §0 rule 3): `while true` and Citizen.CreateThread.
//     A line may opt out with a trailing `-- lint-allow-loop: <reason>` comment (reviewer checks the reason).
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
console.log(`[lint-lua] ${files.length} files checked, ${errors} problem(s)`);
process.exit(errors ? 1 : 0);
