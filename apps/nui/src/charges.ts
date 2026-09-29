// SPDX-License-Identifier: GPL-3.0-only
// Brottskatalog / charge picker logic (docs/contracts.md §C14): labels, client-side filtering of the catalogue
// (listCharges answers the whole read-only catalogue, ~130 rows, once; type-ahead filters that cached answer instead
// of calling the server per keystroke) and the live fine/jail sums of the picked lines.
import type { LocaleKey } from '@fredpd/types/locale-keys';
import type { Charge } from '@fredpd/types/records';
import type { I18n } from '@fredpd/ui';

export type ChargeClass = Charge['class'];
export const CHARGE_CLASSES: readonly ChargeClass[] = ['ordningsbot', 'bot', 'fängelse'];
export const CHARGE_CLASS_KEYS: Readonly<Record<ChargeClass, LocaleKey>> = {
  ordningsbot: 'charge.class.ordningsbot',
  bot: 'charge.class.bot',
  fängelse: 'charge.class.fangelse',
};
export const CHARGE_CLASS_TONES = { ordningsbot: 'neutral', bot: 'warning', fängelse: 'danger' } as const satisfies Record<ChargeClass, string>;

export const APPLIED_STATUS_KEYS = {
  issued: 'charge.status.issued',
  paid: 'charge.status.paid',
  served: 'charge.status.served',
  revoked: 'charge.status.revoked',
} as const satisfies Record<string, LocaleKey>;

export const categoryLabel = (i18n: Pick<I18n, 'tx'>, category: string) => i18n.tx(`charge.category.${category}`, undefined, category);

/** Case- and accent-insensitive-enough match on code, title and law reference (all query words must match). */
export function filterCharges(charges: readonly Charge[], query: string, cls: ChargeClass | null = null): Charge[] {
  const words = query.toLocaleLowerCase('sv').split(/\s+/).filter(Boolean);
  return charges.filter((c) => {
    if (cls && c.class !== cls) return false;
    if (words.length === 0) return true;
    const hay = `${c.code} ${c.title} ${c.lawRef}`.toLocaleLowerCase('sv');
    return words.every((w) => hay.includes(w));
  });
}

export const QUANTITY_MIN = 1;
export const QUANTITY_MAX = 20;
export const MAX_LINES = 30;
export const MAX_FINE_LINES = 10;

export interface ChargeLine {
  code: string;
  quantity: number;
}

export const clampQuantity = (n: number) => Math.min(QUANTITY_MAX, Math.max(QUANTITY_MIN, Math.trunc(Number.isFinite(n) ? n : QUANTITY_MIN)));

/** Adds a charge (quantity 1) or bumps the quantity of a line that has it. */
export function addLine(lines: readonly ChargeLine[], code: string): ChargeLine[] {
  const at = lines.findIndex((l) => l.code === code);
  if (at < 0) return lines.length >= MAX_LINES ? [...lines] : [...lines, { code, quantity: 1 }];
  return lines.map((l, i) => (i === at ? { ...l, quantity: clampQuantity(l.quantity + 1) } : l));
}

export function setQuantity(lines: readonly ChargeLine[], code: string, quantity: number): ChargeLine[] {
  return lines.map((l) => (l.code === code ? { ...l, quantity: clampQuantity(quantity) } : l));
}

export const removeLine = (lines: readonly ChargeLine[], code: string) => lines.filter((l) => l.code !== code);

/** Totals of the picked lines (fine and jail time times quantity); unknown codes count 0. */
export function sumLines(lines: readonly ChargeLine[], catalogue: ReadonlyMap<string, Charge>): { fine: number; jailMinutes: number } {
  let fine = 0;
  let jailMinutes = 0;
  for (const line of lines) {
    const charge = catalogue.get(line.code);
    if (!charge) continue;
    fine += charge.fine * line.quantity;
    jailMinutes += charge.jailMinutes * line.quantity;
  }
  return { fine, jailMinutes };
}

/** "Utfärda ordningsbot" is possible only for 1–10 lines that are all class ordningsbot (issueFine refuses others). */
export function canIssueFine(lines: readonly ChargeLine[], catalogue: ReadonlyMap<string, Charge>): boolean {
  return lines.length > 0 && lines.length <= MAX_FINE_LINES && lines.every((l) => catalogue.get(l.code)?.class === 'ordningsbot');
}
