// SPDX-License-Identifier: GPL-3.0-only
// Masked case/report content (fredpd_records server/export.lua): what a release decision hands out and what a share
// link to a case or report shows. Only the listed fields are rendered (number, status, title, summary, dates, report
// title/body as text through MarkdownLite: no HTML); officers, subjects, charges and evidence are never part of it.
import { Badge, MarkdownLite, useI18n } from '@fredpd/ui';
import type { ReleasedContent } from '../mdt/extra';
import { fmtDate } from '../mdt/shared';

function ReportBlock({ number, title, body, createdAt }: { number: string; title: string; body: string; createdAt: string }) {
  return (
    <section data-released-report={number} className="flex flex-col gap-1 border-t border-line pt-3">
      <h3 className="text-sm font-semibold text-fg">
        <span className="font-mono text-muted">{number}</span> {title}
      </h3>
      <p className="text-xs text-muted">{fmtDate(createdAt)}</p>
      <MarkdownLite text={body} className="text-sm" />
    </section>
  );
}

export function ReleasedContentView({ content }: { content: ReleasedContent }) {
  const { t } = useI18n();
  if (content.type === 'report') {
    return (
      <article data-released="report" className="flex flex-col gap-2">
        <p className="font-mono text-sm text-muted">{content.caseNumber}</p>
        <ReportBlock number={content.reportNumber} title={content.title} body={content.body} createdAt={content.createdAt} />
      </article>
    );
  }
  return (
    <article data-released="case" className="flex flex-col gap-3">
      <header className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm text-muted">{content.caseNumber}</span>
        <h2 className="text-lg font-semibold text-fg">{content.title}</h2>
        <Badge>{t(content.status === 'open' ? 'case.status.open' : 'case.status.closed')}</Badge>
      </header>
      <p className="text-xs text-muted">
        {t('common.createdAt')} {fmtDate(content.createdAt)}
        {content.closedAt && ` · ${t('case.status.closed')} ${fmtDate(content.closedAt)}`}
      </p>
      {content.summary && <p className="text-sm whitespace-pre-line text-fg">{content.summary}</p>}
      {content.reports.map((r) => (
        <ReportBlock key={r.reportNumber} number={r.reportNumber} title={r.title} body={r.body} createdAt={r.createdAt} />
      ))}
    </article>
  );
}
