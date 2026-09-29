// SPDX-License-Identifier: GPL-3.0-only
// config/units.json: unit labels and the Hem page variant of each unit (IMPLEMENTATION.md §4.9, task 2.7).
import unitsConfig from '../../../config/units.json';

export const HOME_VARIANTS = ['igv', 'span', 'utredning', 'tekniker', 'ledning', 'default'] as const;
export type HomeVariant = (typeof HOME_VARIANTS)[number];

export interface UnitConfig {
  code: string;
  callsign: string;
  labelKey: string;
  home: string;
}

export const UNITS: readonly UnitConfig[] = unitsConfig.units;

const isHomeVariant = (v: string): v is HomeVariant => (HOME_VARIANTS as readonly string[]).includes(v);

export function findUnit(code: string | null | undefined): UnitConfig | undefined {
  return code ? UNITS.find((u) => u.code === code) : undefined;
}

/** Hem variant for the primary unit; `default` without a unit or for a variant this build does not know. */
export function homeVariantFor(unit: string | null | undefined): HomeVariant {
  const home = findUnit(unit)?.home;
  return home && isHomeVariant(home) ? home : 'default';
}
