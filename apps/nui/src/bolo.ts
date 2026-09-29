// SPDX-License-Identifier: GPL-3.0-only
// BOLO (efterlysning) form logic, kept pure so the input the dialog sends can be tested against
// BoloCreateInputSchema (packages/types/src/mdt.ts). The server validates again (fredpd_bolo shared/input.lua).
import { BoloCreateInputSchema } from '@fredpd/types/mdt';
import type { Bolo, Level, MdtInput } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { personPath, vehiclePath } from './search';

export type BoloKind = Bolo['kind'];

export type BoloSubject = { kind: 'person'; citizenid: string; label: string } | { kind: 'vehicle'; plate: string; label: string };

export interface BoloForm {
  kind: BoloKind;
  subject: BoloSubject | null;
  reason: string;
  level: Level;
  /** null = no expiry. */
  expiresInHours: number | null;
}

/** Expiry choices in hours (BoloCreateInputSchema: 1–720). */
export const BOLO_EXPIRY_HOURS = [1, 4, 12, 24, 72, 168, 720] as const;
export const BOLO_REASON_MIN = 3;
export const BOLO_REASON_MAX = 500;
export const BOLO_NOTE_MAX = 500;

export function initialBoloForm(kind: BoloKind, subject: BoloSubject | null = null): BoloForm {
  return { kind, subject: subject && subject.kind === kind ? subject : null, reason: '', level: 0, expiresInHours: null };
}

/**
 * The createBolo input for a form: person → citizenid only, vehicle → plate only (the schema's refine), reason
 * trimmed, expiry only when chosen.
 */
export function buildBoloCreateInput(form: BoloForm): MdtInput<'createBolo'> {
  const subject = form.subject && form.subject.kind === form.kind ? form.subject : null;
  const input: MdtInput<'createBolo'> = { kind: form.kind, reason: form.reason.trim(), level: form.level };
  if (subject?.kind === 'person') input.citizenid = subject.citizenid;
  if (subject?.kind === 'vehicle') input.plate = subject.plate;
  if (form.expiresInHours !== null) input.expiresInHours = form.expiresInHours;
  return input;
}

export type BoloFormIssue = 'subject' | 'reason' | 'level' | 'expiresInHours';

export type BoloFormCheck = { ok: true; input: MdtInput<'createBolo'> } | { ok: false; issues: BoloFormIssue[] };

/** Client-side check before sending: the zod schema plus "level ≤ my tier" (bolo.md: level above tier is refused). */
export function checkBoloForm(form: BoloForm, tier: Level): BoloFormCheck {
  const input = buildBoloCreateInput(form);
  const issues = new Set<BoloFormIssue>();
  const parsed = BoloCreateInputSchema.safeParse(input);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const field = issue.path[0];
      if (field === 'reason' || field === 'level' || field === 'expiresInHours') issues.add(field);
      else issues.add('subject'); // citizenid, plate, kind or the refine (no path)
    }
  }
  if (form.level > tier) issues.add('level');
  return issues.size === 0 ? { ok: true, input } : { ok: false, issues: [...issues] };
}

export type BoloStatus = 'active' | 'resolved' | 'expired';

export const BOLO_STATUS_KEYS: Readonly<Record<BoloStatus, LocaleKey>> = {
  active: 'bolo.status.active',
  resolved: 'bolo.status.resolved',
  expired: 'bolo.status.expired',
};

export function boloStatus(bolo: Pick<Bolo, 'active' | 'resolvedAt'>): BoloStatus {
  if (bolo.active) return 'active';
  return bolo.resolvedAt ? 'resolved' : 'expired';
}

/** The person or vehicle page of a BOLO's subject, when the server sent its id. */
export function boloSubjectPath(bolo: Pick<Bolo, 'kind' | 'citizenid' | 'plate'>): string | null {
  if (bolo.kind === 'person') return bolo.citizenid ? personPath(bolo.citizenid) : null;
  return bolo.plate ? vehiclePath(bolo.plate) : null;
}

export const LEVELS: readonly Level[] = [0, 1, 2];
