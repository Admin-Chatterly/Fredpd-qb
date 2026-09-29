// Runs the plain-Lua test suite in tests/lua with a local Lua 5.4 interpreter.
import { spawnSync } from 'node:child_process';

const candidates = ['lua5.4', 'lua54', 'lua'];
const lua = candidates.find((bin) => spawnSync(bin, ['-v']).status === 0);
if (!lua) {
  console.warn('[test-lua] no Lua 5.4 interpreter found (tried lua5.4, lua54, lua); skipping Lua tests');
  process.exit(process.env.CI ? 1 : 0);
}
const res = spawnSync(lua, ['tests/lua/run.lua', ...process.argv.slice(2)], { stdio: 'inherit' });
process.exit(res.status ?? 1);
