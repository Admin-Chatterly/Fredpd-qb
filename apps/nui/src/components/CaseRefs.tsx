// SPDX-License-Identifier: GPL-3.0-only
// Case references as the server shaped them with canView (docs/contracts.md §C3, CaseRefSchema):
// - full: number, title, status, level, role;
// - masked: number and status plus a "Begränsad insyn" badge; the title only when the server sent one;
// - notice (kontaktnotis): ONLY the Notice component with the contact. A notice carries no id, number, title or
//   level, and nothing from it but the contact is passed on, so nothing else can reach the DOM.
// A field that is not present (null/absent) is never rendered.
import { Link } from 'react-router';
import type { CaseRef } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { Badge, EmptyState, Notice, useI18n } from '@fredpd/ui';
import { noticeOwner } from '../format';
import { caseRefPath } from '../search';

type CaseRole = NonNullable<Extract<CaseRef, { visibility: 'full' }>['role']>;

export const CASE_ROLE_KEYS: Readonly<Record<CaseRole, LocaleKey>> = {
  suspect: 'case.subject.role.suspect',
  victim: 'case.subject.role.victim',
  witness: 'case.subject.role.witness',
  vehicle: 'case.subject.vehicle',
  other: 'case.subject.role.other',
};

const STATUS_KEYS = { open: 'case.status.open', closed: 'case.status.closed' } as const satisfies Record<string, LocaleKey>;

type VisibleCaseRef = Exclude<CaseRef, { visibility: 'notice' }>;

/** Number, title (when present), role, status and badges of a full/masked ref, as plain content (no link). */
export function CaseRefSummary({ caseRef }: { caseRef: VisibleCaseRef }) {
  const { t } = useI18n();
  const hasTitle = caseRef.title !== null && caseRef.title !== undefined && caseRef.title !== '';
  return (
    <span data-case-visibility={caseRef.visibility} className="flex min-w-0 flex-1 items-center gap-3">
      <span className="shrink-0 font-mono text-sm text-fg">{caseRef.caseNumber}</span>
      <span className="min-w-0 flex-1 truncate text-sm text-fg">{hasTitle ? caseRef.title : null}</span>
      {caseRef.role !== null && caseRef.role !== undefined && <span className="shrink-0 text-xs text-muted">{t(CASE_ROLE_KEYS[caseRef.role])}</span>}
      <Badge tone={caseRef.status === 'open' ? 'accent' : 'neutral'}>{t(STATUS_KEYS[caseRef.status])}</Badge>
      {caseRef.visibility === 'masked' && <Badge tone="warning">{t('visibility.masked.badge')}</Badge>}
      {caseRef.level > 0 && <Badge level={caseRef.level} />}
    </span>
  );
}

/** Kontaktnotis for a notice ref: only its contact is passed on. */
export function CaseNotice({ contact, subject }: { contact: Extract<CaseRef, { visibility: 'notice' }>['contact'] | undefined; subject: string }) {
  const i18n = useI18n();
  return <Notice subject={subject} owner={noticeOwner(i18n, contact ?? {})} />;
}

/** A ref as a link to its case page, or the kontaktnotis. */
export function CaseRefRow({ caseRef, subject }: { caseRef: CaseRef; subject: string }) {
  if (caseRef.visibility === 'notice') return <CaseNotice contact={caseRef.contact} subject={subject} />;
  return (
    <Link to={caseRefPath(caseRef) ?? '/'} className="flex min-h-10 w-full items-center rounded-md px-2 py-1.5 text-left hover:bg-raised">
      <CaseRefSummary caseRef={caseRef} />
    </Link>
  );
}

export interface CaseRefListProps {
  refs: readonly CaseRef[];
  /** Who or what the cases concern, for the kontaktnotis text (person name, plate). */
  subject: string;
  empty?: string;
}

export function CaseRefList({ refs, subject, empty }: CaseRefListProps) {
  if (refs.length === 0) return <EmptyState title={empty} />;
  return (
    <ul className="flex flex-col gap-1 p-2">
      {refs.map((caseRef, i) => (
        <li key={caseRef.visibility === 'notice' ? `notice-${i}` : `case-${caseRef.id}`}>
          <CaseRefRow caseRef={caseRef} subject={subject} />
        </li>
      ))}
    </ul>
  );
}
