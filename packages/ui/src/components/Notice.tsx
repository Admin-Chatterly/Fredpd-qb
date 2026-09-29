// SPDX-License-Identifier: GPL-3.0-only
// Kontaktnotis (docs/contracts.md §C3: canView result `notice`): the viewer learns only that a record about
// `subject` exists and whom to contact. The component takes no record, so no record field can leak into it.
import type { ReactNode } from 'react';
import type { VisibilityResult } from '@fredpd/types/canView';
import { cn } from '../cn';
import { useT } from '../i18n';
import { IconShield } from '../icons';

export interface NoticeProps {
  /** Who or what the record concerns (a person's name, a plate). */
  subject: string;
  /** Owner to contact (officer display name or unit label). Null/omitted: "contact command". */
  owner?: string | null;
  className?: string;
}

export function Notice({ subject, owner, className }: NoticeProps) {
  const t = useT();
  return (
    <div role="note" className={cn('flex gap-3 rounded-md border border-line-strong bg-raised px-3 py-2.5', className)}>
      <IconShield size={18} className="mt-0.5 shrink-0 text-muted" />
      <div className="min-w-0">
        <p className="text-sm font-semibold text-fg">{t('visibility.notice.title')}</p>
        <p className="text-sm text-muted">
          {owner ? t('visibility.notice.text', { subject, owner }) : t('visibility.notice.textCommand', { subject })}
        </p>
      </div>
    </div>
  );
}

export interface VisibilityGateProps {
  /** canView() result for this viewer and record. */
  result: VisibilityResult;
  subject: string;
  owner?: string | null;
  /** The record content, rendered only for `full` and `masked`. */
  children: ReactNode;
}

/**
 * Renders a record according to its canView result: `none` renders nothing, `notice` only the kontaktnotis,
 * `masked` the content under a masking banner (the server has already stripped the masked parts), `full` the content.
 */
export function VisibilityGate({ result, subject, owner, children }: VisibilityGateProps) {
  const t = useT();
  switch (result) {
    case 'none':
      return null;
    case 'notice':
      return <Notice subject={subject} owner={owner} />;
    case 'masked':
      return (
        <>
          <p role="note" className="mb-2 rounded-md border border-warning/40 bg-warning/10 px-3 py-1.5 text-sm text-warning">
            {t('visibility.masked.text')}
          </p>
          {children}
        </>
      );
    case 'full':
      return <>{children}</>;
  }
}
