// SPDX-License-Identifier: GPL-3.0-only
// Display helpers for tablet pages: dates/times/money per config/formats.json (docs/contracts.md §C4, bundled
// through @fredpd/types/format), officer labels (§4.9: callsign + Discord display name), unit labels and the
// kontaktnotis owner line. A malformed value never throws out of a render: it falls back to the raw text.
import { formatCurrency, formatDate, formatTime } from '@fredpd/types/format';
import type { OfficerRef } from '@fredpd/types/mdt';
import type { I18n } from '@fredpd/ui';

export function fmtDate(iso: string): string {
  try {
    return formatDate(iso);
  } catch {
    return iso;
  }
}

export function fmtTime(iso: string): string {
  try {
    return formatTime(iso);
  } catch {
    return iso;
  }
}

/** "2026-09-29 kl. 14:05" (time.at). */
export function fmtDateTime(i18n: Pick<I18n, 't'>, iso: string): string {
  try {
    return i18n.t('time.at', { date: formatDate(iso), time: formatTime(iso) });
  } catch {
    return iso;
  }
}

/** "1 500 kr" per formats.json currency. */
export function fmtCurrency(amount: number): string {
  try {
    return formatCurrency(amount);
  } catch {
    return String(amount);
  }
}

/** "IGV-07 · Anna Berg", or just the display name without a callsign. */
export function officerLabel(officer: Pick<OfficerRef, 'displayName' | 'callsign'>): string {
  return officer.callsign ? `${officer.callsign} · ${officer.displayName}` : officer.displayName;
}

/** Label of a unit code (`unit.<code>`), the raw code when unknown. */
export function unitLabel(i18n: Pick<I18n, 'tx'>, code: string): string {
  return i18n.tx(`unit.${code}`, undefined, code);
}

/**
 * Owner line of a kontaktnotis from its contact (CaseRef notice): "Bo Carlsson (Spaning)", the name or the unit
 * alone, or null (the Notice then says "Kontakta ledningen").
 */
export function noticeOwner(i18n: Pick<I18n, 'tx'>, contact: { displayName?: string | null; unit?: string | null }): string | null {
  const name = contact.displayName || null;
  const unit = contact.unit ? unitLabel(i18n, contact.unit) : null;
  if (name && unit) return i18n.tx('visibility.notice.owner', { name, unit }, `${name} (${unit})`);
  return name ?? unit;
}

/** Hours → "4 tim" / "3 dygn". */
export function fmtHours(i18n: Pick<I18n, 't'>, hours: number): string {
  return hours % 24 === 0 ? i18n.t('time.duration.days', { count: hours / 24 }) : i18n.t('time.duration.hours', { count: hours });
}
