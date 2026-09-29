// SPDX-License-Identifier: GPL-3.0-only
// Lua -> NUI wire normalisation. Lua cannot put null in a table, so a nullable field that is nil is ABSENT in what
// fredpd_mdt answers (docs/modules/records.md and bolo.md, "Lua has no null"); an empty Lua table is one JSON
// shape for both `[]` and `{}`. normalizeWire walks the zod schema of the expected output alongside the value and
// puts back what the schema says: absent nullable keys become null, `{}` where a list is expected becomes `[]`, `[]`
// where an object is expected becomes `{}`. It never validates or drops anything (dev builds validate afterwards,
// src/api/client.ts), and it only reads the schemas' public `def`, so it is cheap enough for every response.

/** The part of a zod 4 schema this walker reads. */
interface Def {
  type: string;
  shape?: Record<string, unknown>;
  element?: unknown;
  innerType?: unknown;
  options?: unknown[];
  discriminator?: string;
  values?: unknown[];
}

const WRAPPERS = new Set(['nullable', 'optional', 'default', 'readonly', 'catch', 'prefault', 'nonoptional']);

function defOf(schema: unknown): Def | null {
  if (typeof schema !== 'object' || schema === null) return null;
  const def = (schema as { def?: unknown }).def;
  return typeof def === 'object' && def !== null && typeof (def as { type?: unknown }).type === 'string' ? (def as Def) : null;
}

export function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** The schema under nullable/optional/default wrappers. */
function unwrap(schema: unknown): Def | null {
  let def = defOf(schema);
  for (let i = 0; i < 10 && def && WRAPPERS.has(def.type) && def.innerType; i += 1) def = defOf(def.innerType);
  return def;
}

/** Whether null is a valid value for the schema (a nullable wrapper anywhere in the chain, or z.null()). */
export function acceptsNull(schema: unknown): boolean {
  let def = defOf(schema);
  for (let i = 0; i < 10 && def; i += 1) {
    if (def.type === 'nullable' || def.type === 'null') return true;
    if (def.type === 'union') return (def.options ?? []).some(acceptsNull);
    if (!WRAPPERS.has(def.type) || !def.innerType) return false;
    def = defOf(def.innerType);
  }
  return false;
}

/** For a discriminated union: the option whose discriminator literal matches the value. */
function pickOption(def: Def, value: Record<string, unknown>): unknown {
  const options = def.options ?? [];
  const key = def.discriminator;
  if (key !== undefined) {
    return options.find((option) => {
      const field = unwrap(option)?.shape?.[key];
      const values = unwrap(field)?.values;
      return Array.isArray(values) && values.includes(value[key]);
    });
  }
  // Plain union: only an unambiguous object option is followed.
  const objects = options.filter((option) => unwrap(option)?.type === 'object');
  return objects.length === 1 ? objects[0] : undefined;
}

export function normalizeWire(schema: unknown, value: unknown): unknown {
  const def = unwrap(schema);
  if (!def) return value;
  switch (def.type) {
    case 'array': {
      const list = isRecord(value) && Object.keys(value).length === 0 ? [] : value;
      return Array.isArray(list) ? list.map((item) => normalizeWire(def.element, item)) : list;
    }
    case 'object': {
      const obj = Array.isArray(value) && value.length === 0 ? {} : value;
      if (!isRecord(obj) || !def.shape) return obj;
      const out: Record<string, unknown> = { ...obj };
      for (const [key, field] of Object.entries(def.shape)) {
        if (obj[key] === undefined) {
          if (acceptsNull(field)) out[key] = null;
        } else {
          out[key] = normalizeWire(field, obj[key]);
        }
      }
      return out;
    }
    case 'union': {
      if (!isRecord(value)) return value;
      const option = pickOption(def, value);
      return option === undefined ? value : normalizeWire(option, value);
    }
    default:
      return value;
  }
}

/** Mock/test helper: what Lua would send for a value (every null-valued key removed, recursively). */
export function toLuaWire(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(toLuaWire);
  if (!isRecord(value)) return value;
  const out: Record<string, unknown> = {};
  for (const [key, v] of Object.entries(value)) if (v !== null && v !== undefined) out[key] = toLuaWire(v);
  return out;
}
