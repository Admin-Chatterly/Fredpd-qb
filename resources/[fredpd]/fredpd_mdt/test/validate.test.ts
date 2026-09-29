// SPDX-License-Identifier: GPL-3.0-only
// The tablet action inputs of docs/contracts.md §C12 exist twice: the zod schemas (packages/types/src/mdt.ts,
// dispatch.ts, evidence.ts) used by the NUI and the portal, and the Lua mirror fredpd_mdt/shared/validate.lua used by
// the server dispatcher. Both are checked against packages/types/test/fixtures/mdt-inputs.fixtures.json (this file
// for zod, tests/lua/mdt_validate_test.lua for Lua). On top of that, when lua5.4 is on PATH, a generated corpus of
// ~675 edge-case inputs is run through both sides and every accept/refuse decision and cleaned value must agree.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { MDT_ACTIONS, TabletIssueInputSchema } from '../../../../packages/types/src/mdt';
import { DISPATCH_ACTIONS } from '../../../../packages/types/src/dispatch';
import { EVIDENCE_ACTIONS } from '../../../../packages/types/src/evidence';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..', '..');

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
interface Sample { input: Json; output?: Json; why?: string }
interface Fixtures {
  actions: Record<string, { shape: string; grant: [string, string] | null }>;
  shapes: Record<string, { valid: Sample[]; invalid: Sample[] }>;
}
/** The part of a zod schema used here (zod is resolved from packages/types, not from resources/). */
interface Schema { safeParse(v: unknown): { success: boolean; data?: unknown } }
interface ActionDef { input: unknown; grant: readonly [string, string] | null }

const FIX = JSON.parse(readFileSync(join(root, 'packages/types/test/fixtures/mdt-inputs.fixtures.json'), 'utf8')) as Fixtures;
const REGISTRY: Record<string, ActionDef> = { ...MDT_ACTIONS, ...DISPATCH_ACTIONS, ...EVIDENCE_ACTIONS };
const EXTRA_SHAPES: Record<string, Schema> = { TabletIssueInput: TabletIssueInputSchema as Schema };

/** Schema for a fixture shape: the input schema of every action that uses it (they must all agree), or an extra. */
function schemasFor(shape: string): Schema[] {
  const fromActions = Object.entries(FIX.actions)
    .filter(([, def]) => def.shape === shape)
    .map(([name]) => REGISTRY[name]!.input as Schema);
  const extra = EXTRA_SHAPES[shape];
  return extra ? [...fromActions, extra] : fromActions;
}

describe('mdt-inputs fixtures vs zod', () => {
  it('cover exactly MDT_ACTIONS + DISPATCH_ACTIONS + EVIDENCE_ACTIONS with the same grant column', () => {
    expect(Object.keys(FIX.actions).sort()).toEqual(Object.keys(REGISTRY).sort());
    for (const [name, def] of Object.entries(FIX.actions)) {
      const grant = REGISTRY[name]!.grant;
      expect(def.grant, name).toEqual(grant ? [...grant] : null);
      expect(FIX.shapes[def.shape], `${name} -> ${def.shape}`).toBeDefined();
    }
  });

  it('use every shape somewhere', () => {
    for (const shape of Object.keys(FIX.shapes)) expect(schemasFor(shape).length, shape).toBeGreaterThan(0);
  });

  for (const [shape, samples] of Object.entries(FIX.shapes)) {
    it(`${shape}: valid samples parse to the recorded output`, () => {
      for (const schema of schemasFor(shape)) {
        for (const s of samples.valid) {
          const r = schema.safeParse(s.input);
          expect(r.success, JSON.stringify(s.input)).toBe(true);
          expect(r.data).toEqual(s.output);
        }
      }
    });
    it(`${shape}: invalid samples are refused`, () => {
      for (const schema of schemasFor(shape)) {
        for (const s of samples.invalid) expect(schema.safeParse(s.input).success, `${s.why}: ${JSON.stringify(s.input)}`).toBe(false);
      }
    });
  }
});

// ---------------------------------------------------------------------------------------------------------------
// Generated corpus through both validators

/** Deterministic PRNG (mulberry32). */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const E = '\u{1F600}';
const STRINGS = [
  '', ' ', 'a', 'ab', 'abc', '  ab  ', '　Öberg ', '​x', E, E + E, 'x' + E, 'ABC 12D', 'abc12d', 'ABC12345',
  'a_b-C9', 'ÅÄÖ', "x';--", 'Rån mot bank', 'Rad 1\nRad 2', '1', 'true', 'person', 'vehicle', 'auto', 'case', 'open', 'mine',
  'all', 'OPEN', 'SP-7KQ2-M9XD', ' x ', 'a'.repeat(15), 'a'.repeat(16), 'a'.repeat(17), 'a'.repeat(15) + E, 'a'.repeat(16) + E,
  'Q'.repeat(50), 'Q'.repeat(51), 'S'.repeat(32), 'S'.repeat(33), 'a'.repeat(63) + E, 'a'.repeat(64) + E, 'a'.repeat(65),
  'a'.repeat(499) + E, 'a'.repeat(501), ' \t\n',
];
const NUMBERS = [0, 1, 2, 3, -1, 1.5, 2.0000001, 5, 12, 42, 719, 720, 721, 10000, 10001, 2 ** 53 - 1, 2 ** 53, -(2 ** 53)];
const OTHERS: Json[] = [true, false, { deep: 1 }, [1, 2]];
const FIELDS: Record<string, string[]> = {
  Empty: [],
  SearchInput: ['query', 'type', 'page'],
  CitizenInput: ['citizenid'],
  PlateInput: ['plate'],
  BoloListInput: ['active', 'page'],
  BoloCreateInput: ['kind', 'citizenid', 'plate', 'reason', 'level', 'expiresInHours'],
  BoloResolveInput: ['id', 'note'],
  TabletListInput: ['page'],
  TabletRevokeInput: ['serial', 'revoked'],
  TabletIssueInput: ['targetServerId'],
  AlertListInput: ['filter', 'page'],
  AlertIdInput: ['id'],
  EvidenceListInput: ['caseId', 'unlinked', 'page'],
  EvidenceIdInput: ['id'],
  EvidenceLinkInput: ['id', 'caseId'],
};

function corpus(): { shape: string; input: Json }[] {
  const rand = rng(20260929);
  const pick = <T>(xs: readonly T[]): T => xs[Math.floor(rand() * xs.length)]!;
  const value = (): Json => {
    const r = rand();
    return r < 0.5 ? pick(STRINGS) : r < 0.9 ? pick(NUMBERS) : pick(OTHERS);
  };
  const out: { shape: string; input: Json }[] = [];
  for (const [shape, fields] of Object.entries(FIELDS)) {
    // Start from a valid sample so that most generated inputs differ from a valid one in one or two fields.
    const bases = FIX.shapes[shape]!.valid.map((s) => s.input as Record<string, Json>);
    for (let i = 0; i < 45; i++) {
      const input: Record<string, Json> = { ...pick(bases) };
      const changes = 1 + Math.floor(rand() * 2);
      for (let c = 0; c < changes; c++) {
        const r = rand();
        if (fields.length && r < 0.8) {
          const f = pick(fields);
          if (rand() < 0.15) delete input[f];
          else input[f] = value();
        } else if (r < 0.9) {
          input.extra = value();
        }
      }
      out.push({ shape, input });
    }
  }
  return out;
}

// A small encoder that keeps integers exact (rxi json.lua prints numbers with %.14g).
const LUA = `
package.path = './tests/lua/vendor/?.lua;' .. package.path
local json = require('json')
local V = dofile('./resources/[fredpd]/fredpd_mdt/shared/validate.lua')
local function enc(v)
  local t = type(v)
  if t == 'string' then return json.encode(v) end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then return math.type(v) == 'integer' and ('%d'):format(v) or ('%.17g'):format(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = json.encode(tostring(k)) .. ':' .. enc(x) end
  table.sort(parts)
  return '{' .. table.concat(parts, ',') .. '}'
end
local cases = json.decode(io.read('a'))
local out = {}
for i, c in ipairs(cases) do
  local res = V.check(c.shape, c.input)
  out[i] = res and ('{"ok":true,"output":' .. enc(res) .. '}') or '{"ok":false}'
end
io.write('[' .. table.concat(out, ',') .. ']')
`;

const lua = ['lua5.4', 'lua54'].find((bin) => spawnSync(bin, ['-v']).status === 0);

describe.skipIf(!lua)('zod and validate.lua agree on a generated corpus', () => {
  it('same decision and the same cleaned value for every input', () => {
    const cases = corpus();
    // JSON has no way to say "absent" inside an array element, and Lua reads [] as {}: filter those out here, as the
    // fixtures do (docs/modules/mdt.md "Validation").
    const usable = cases.filter((c) => !JSON.stringify(c.input).includes('[]'));
    const r = spawnSync(lua!, ['-e', LUA], { cwd: root, input: JSON.stringify(usable), encoding: 'utf8' });
    expect(r.status, r.stderr).toBe(0);
    const results = JSON.parse(r.stdout) as { ok: boolean; output?: Json }[];
    expect(results.length).toBe(usable.length);
    let accepted = 0;
    usable.forEach((c, i) => {
      const schema = c.shape === 'TabletIssueInput' ? EXTRA_SHAPES.TabletIssueInput! : schemasFor(c.shape)[0]!;
      const z = schema.safeParse(c.input);
      const l = results[i]!;
      const label = `${c.shape} ${JSON.stringify(c.input)}`;
      expect(l.ok, label).toBe(z.success);
      if (z.success) {
        accepted++;
        expect(l.output, label).toEqual(z.data);
      }
    });
    // The corpus must exercise both outcomes.
    expect(accepted).toBeGreaterThan(100);
    expect(usable.length - accepted).toBeGreaterThan(200);
  });
});
