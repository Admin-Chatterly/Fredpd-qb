// SPDX-License-Identifier: GPL-3.0-only
// Unit codes from config/units.json, in primary-unit order (IMPLEMENTATION.md §4.9). They are the `unitOrder` of
// grant resolution (docs/contracts.md §C2) and the unit keys of the admin catalog (§C10).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

/** Repository root config/units.json, resolved from this file so the working directory does not matter. */
export const DEFAULT_UNITS_PATH = fileURLToPath(new URL('../../../config/units.json', import.meta.url));

const UnitsFileSchema = z.object({
  units: z.array(z.object({ code: z.string().regex(/^[A-Za-z0-9_-]{1,32}$/) }).loose()),
});

export function loadUnitCodes(path: string = DEFAULT_UNITS_PATH): string[] {
  const parsed = UnitsFileSchema.parse(JSON.parse(readFileSync(path, 'utf8')));
  return parsed.units.map((u) => u.code);
}
