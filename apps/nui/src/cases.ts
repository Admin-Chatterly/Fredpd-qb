// SPDX-License-Identifier: GPL-3.0-only
// Ärenden / rapporter helpers (docs/contracts.md §C14): list filters, paths, labels. The fine-grained rules (owner,
// lead, records.admin, canView) are the server's; the UI only hides controls that cannot succeed.
import type { LocaleKey } from '@fredpd/types/locale-keys';
import type { CaseDetail } from '@fredpd/types/records';

export type CaseFilter = 'mine' | 'unit' | 'open' | 'closed' | 'all';
export const CASE_FILTERS: readonly CaseFilter[] = ['mine', 'unit', 'open', 'closed', 'all'];
/** Filter tab labels (pending keys, locales/pending/nui-pages.json, read with tx()). */
export const CASE_FILTER_KEYS: Readonly<Record<CaseFilter, string>> = {
  mine: 'case.filter.mine',
  unit: 'case.filter.unit',
  open: 'case.filter.open',
  closed: 'case.filter.closed',
  all: 'case.filter.all',
};

export const CASE_STATUS_KEYS = { open: 'case.status.open', closed: 'case.status.closed' } as const satisfies Record<string, LocaleKey>;

export const SUBJECT_ROLE_KEYS = {
  suspect: 'case.subject.role.suspect',
  victim: 'case.subject.role.victim',
  witness: 'case.subject.role.witness',
  other: 'case.subject.role.other',
} as const satisfies Record<string, LocaleKey>;
export type SubjectRole = keyof typeof SUBJECT_ROLE_KEYS;
export const SUBJECT_ROLES = Object.keys(SUBJECT_ROLE_KEYS) as SubjectRole[];

export const ASSIGNEE_ROLE_KEYS = { lead: 'case.assignee.role.lead', member: 'case.assignee.role.member' } as const satisfies Record<string, LocaleKey>;

export const casePath = (id: number) => `/arende/${id}`;
export const reportPath = (id: number) => `/rapport/${id}`;

/** Route param → positive integer id, or null (the page then shows "not found" without calling anything). */
export function parseId(param: string | undefined): number | null {
  if (!param || !/^\d{1,9}$/.test(param)) return null;
  const id = Number(param);
  return id > 0 ? id : null;
}

export type VisibleCase = Exclude<CaseDetail, { visibility: 'notice' }>;

/** Writes are offered on a full, open case only (masked and closed cases are read-only for everyone). */
export const caseEditable = (c: VisibleCase) => c.visibility === 'full' && c.status === 'open';

export const RESOLUTION_MIN = 3;
export const RESOLUTION_MAX = 2000;
export const CASE_TITLE_MIN = 3;
export const CASE_TITLE_MAX = 160;
