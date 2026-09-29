// SPDX-License-Identifier: GPL-3.0-only
// Lua tables on the wire (docs/modules/portal-api.md "Output shape"): Lua has no null (a nullable field that is nil is
// absent) and one table type for both [] and {} (an empty list may arrive as {} and an empty object as []). Before the
// output schema parses a portal answer, fromLua() puts both back where the zod schema says what belongs there. It never
// invents data: absent → null only where the schema accepts null; {} ↔ [] only for EMPTY containers.
import type { ZodType } from 'zod';

interface SchemaDef {
  type: string;
  shape?: Record<string, ZodType>;
  element?: ZodType;
  innerType?: ZodType;
  options?: ZodType[];
  in?: ZodType;
  valueType?: ZodType;
}
const defOf = (s: ZodType): SchemaDef => (s as unknown as { def: SchemaDef }).def;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function unwrap(schema: ZodType): ZodType {
  let s = schema;
  for (let i = 0; i < 16; i += 1) {
    const d = defOf(s);
    if (['nullable', 'optional', 'default', 'readonly', 'catch', 'prefault', 'nonoptional'].includes(d.type) && d.innerType) s = d.innerType;
    else if (d.type === 'pipe' && d.in) s = d.in;
    else break;
  }
  return s;
}

export function fromLua(schema: ZodType, value: unknown, depth = 0): unknown {
  if (depth > 64) return value;
  const s = unwrap(schema);
  const def = defOf(s);
  let v = value;
  if (def.type === 'array' && isRecord(v) && Object.keys(v).length === 0) v = [];
  if ((def.type === 'object' || def.type === 'record') && Array.isArray(v) && v.length === 0) v = {};

  if (Array.isArray(v) && def.type === 'array' && def.element) {
    const element = def.element;
    return v.map((item) => fromLua(element, item, depth + 1));
  }
  if (isRecord(v) && def.type === 'union' && def.options) {
    for (const option of def.options) {
      const candidate = fromLua(option, v, depth + 1);
      if (option.safeParse(candidate).success) return candidate;
    }
    return v;
  }
  if (isRecord(v) && def.type === 'object' && def.shape) {
    const out: Record<string, unknown> = { ...v };
    for (const [key, field] of Object.entries(def.shape)) {
      if (v[key] === undefined) {
        // Only where the field is required but nullable; an optional field stays absent.
        if (field.safeParse(null).success && !field.safeParse(undefined).success) out[key] = null;
      } else {
        out[key] = fromLua(field, v[key], depth + 1);
      }
    }
    return out;
  }
  if (isRecord(v) && def.type === 'record' && def.valueType) {
    const valueType = def.valueType;
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fromLua(valueType, x, depth + 1)]));
  }
  return v;
}
