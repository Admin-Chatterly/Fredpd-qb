// SPDX-License-Identifier: GPL-3.0-only
// Builds the web apps and copies generated/shared files into the FiveM resources:
//   locales/*.json              -> resources/[fredpd]/<each>/locales/
//   config/*.json               -> resources/[fredpd]/fredpd_core/config/
//   db/migrations/*.sql         -> resources/[fredpd]/fredpd_core/migrations/ (+ index.json)
//   packages/types/test/fixtures/*.fixtures.json -> resources/[fredpd]/fredpd_devtools/fixtures/
//   apps/nui/dist               -> resources/[fredpd]/fredpd_mdt/web/build/
// Usage: node scripts/build.mjs [--skip-web]
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '..');
const res = join(root, 'resources', '[fredpd]');
const skipWeb = process.argv.includes('--skip-web');

function copyMatching(fromDir, toDir, predicate) {
  if (!existsSync(fromDir)) return [];
  const names = readdirSync(fromDir).filter((n) => statSync(join(fromDir, n)).isFile() && predicate(n)).sort();
  rmSync(toDir, { recursive: true, force: true });
  mkdirSync(toDir, { recursive: true });
  for (const n of names) cpSync(join(fromDir, n), join(toDir, n));
  return names;
}

if (!skipWeb) {
  const shell = process.platform === 'win32';
  for (const pkg of ['@fredpd/nui', '@fredpd/portal']) {
    const r = spawnSync('pnpm', ['--filter', pkg, 'build'], { cwd: root, stdio: 'inherit', shell });
    if (r.status !== 0) process.exit(r.status ?? 1);
  }
}

const resources = existsSync(res) ? readdirSync(res).filter((n) => statSync(join(res, n)).isDirectory()) : [];
for (const r of resources) copyMatching(join(root, 'locales'), join(res, r, 'locales'), (n) => /^[a-z]{2}\.json$/.test(n));

if (existsSync(join(res, 'fredpd_core'))) {
  copyMatching(join(root, 'config'), join(res, 'fredpd_core', 'config'), (n) => n.endsWith('.json'));
  const migrations = copyMatching(join(root, 'db', 'migrations'), join(res, 'fredpd_core', 'migrations'), (n) => /^\d{3}_.+\.sql$/.test(n));
  writeFileSync(join(res, 'fredpd_core', 'migrations', 'index.json'), JSON.stringify(migrations, null, 2) + '\n');
  // Seeds are applied by the migration runner after migrations; keep them next to the migrations.
  const seedDir = join(root, 'db', 'seed');
  if (existsSync(seedDir)) {
    const seeds = copyMatching(seedDir, join(res, 'fredpd_core', 'migrations', 'seed'), (n) => n.endsWith('.sql'));
    writeFileSync(join(res, 'fredpd_core', 'migrations', 'seed', 'index.json'), JSON.stringify(seeds, null, 2) + '\n');
  }
}

if (existsSync(join(res, 'fredpd_devtools'))) {
  copyMatching(join(root, 'packages', 'types', 'test', 'fixtures'), join(res, 'fredpd_devtools', 'fixtures'), (n) => n.endsWith('.fixtures.json'));
}

const nuiDist = join(root, 'apps', 'nui', 'dist');
if (existsSync(join(res, 'fredpd_mdt')) && existsSync(nuiDist)) {
  rmSync(join(res, 'fredpd_mdt', 'web', 'build'), { recursive: true, force: true });
  cpSync(nuiDist, join(res, 'fredpd_mdt', 'web', 'build'), { recursive: true });
}
console.log(`build: copied shared files into ${resources.length} resource(s)`);
