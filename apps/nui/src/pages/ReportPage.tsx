// SPDX-License-Identifier: GPL-3.0-only
// Rapport (/rapport/:id, task 5.3; docs/contracts.md §C14): getReport. Editable reports (the server's `editable`:
// author / case owner or lead / records.admin on an open case) get the editor: title, sekretessnivå, a small toolbar
// (fetstil, rubrik, punktlista) over a plain textarea, a live preview rendered as TEXT by MarkdownLite (no HTML, no
// dangerouslySetInnerHTML), "Spara" (saveReport) and the draft autosave: saveReportDraft ≥ 10 s after the last
// keystroke, only while the editor is focused and has unsaved input (src/autosave.ts; a debounce, no interval).
// getReport carries the viewer's own draft (`draft`, §C14): when it is newer than the report the editor offers
// "Återställ utkast" (loads the draft's title/body into the editor; Spara then stores it) or "Släng utkastet" (hides
// the offer; the stale draft row is deleted by the next Spara).
// Below it the charge picker (person, charges, sums, Registrera brott / Utfärda ordningsbot) and the applied charges.
// Read-only reports show the rendered text and the charges.
import { useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router';
import type { Level } from '@fredpd/types/mdt';
import type { ReportDetail } from '@fredpd/types/records';
import { Badge, Button, Card, EmptyState, Input, Label, MarkdownLite, PageHeader, Textarea, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { useDraftAutosave } from '../autosave';
import { casePath, parseId } from '../cases';
import { APPLIED_STATUS_KEYS, CHARGE_CLASS_KEYS } from '../charges';
import { ChargePicker } from '../components/ChargePicker';
import { QueryView } from '../components/Common';
import { LevelSelect, MutationError } from '../components/Fields';
import { fmtCurrency, fmtDateTime, fmtTime, officerLabel } from '../format';
import { applyBold, applyHeading, applyList } from '../markdown';
import type { TextEdit } from '../markdown';
import { useSession } from '../session';

export const REPORT_BODY_MAX = 100_000;

/** The viewer's draft when it was saved after the report itself (else null: nothing worth offering). */
export function newerDraft(report: Pick<ReportDetail, 'draft' | 'updatedAt'>): NonNullable<ReportDetail['draft']> | null {
  const draft = report.draft;
  if (!draft) return null;
  const draftAt = Date.parse(draft.savedAt);
  const reportAt = Date.parse(report.updatedAt);
  return Number.isFinite(draftAt) && Number.isFinite(reportAt) && draftAt > reportAt ? draft : null;
}

function AppliedCharges({ report }: { report: ReportDetail }) {
  const { t } = useI18n();
  if (report.charges.length === 0) return <EmptyState title={t('charge.none')} />;
  return (
    <ul className="flex flex-col divide-y divide-line" data-applied-charges>
      {report.charges.map((c) => (
        <li key={c.id} className="flex flex-wrap items-center gap-2 px-4 py-2 text-sm">
          <span className="font-mono text-xs text-muted">{c.code}</span>
          <span className="min-w-0 flex-1 truncate">
            {c.title}
            {c.quantity > 1 && ` × ${c.quantity}`}
          </span>
          <span className="text-muted">{c.personName}</span>
          <Badge>{t(CHARGE_CLASS_KEYS[c.class])}</Badge>
          {c.fine > 0 && <span>{fmtCurrency(c.fine)}</span>}
          {c.jailMinutes > 0 && <span>{t('time.duration.minutes', { count: c.jailMinutes })}</span>}
          <Badge tone={c.status === 'revoked' ? 'neutral' : 'accent'}>{t(APPLIED_STATUS_KEYS[c.status])}</Badge>
        </li>
      ))}
    </ul>
  );
}

function ReportHeader({ report }: { report: ReportDetail }) {
  const i18n = useI18n();
  const { t } = i18n;
  return (
    <PageHeader
      title={
        <span className="flex items-center gap-2">
          <span className="font-mono">{report.reportNumber}</span>
          <span className="truncate">{report.title}</span>
        </span>
      }
      subtitle={
        <span className="flex flex-wrap items-center gap-2">
          <Link to={casePath(report.caseId)} className="font-mono text-accent-text hover:underline">
            {report.caseNumber}
          </Link>
          {report.level > 0 && <Badge level={report.level} />}
          {report.author && <span>{officerLabel(report.author)}</span>}
          <span>{fmtDateTime(i18n, report.updatedAt)}</span>
          {!report.editable && <Badge>{t('case.status.closed')}</Badge>}
        </span>
      }
    />
  );
}

function ReportEditor({ report }: { report: ReportDetail }) {
  const i18n = useI18n();
  const { t } = i18n;
  const { grants } = useSession();
  const [title, setTitle] = useState(report.title);
  const [body, setBody] = useState(report.body);
  const [level, setLevel] = useState<Level>(report.level);
  const [draftAt, setDraftAt] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  // "Återställ utkast" offer: shown once per mount while a newer draft exists and the officer has not chosen.
  const [offer, setOffer] = useState(() => newerDraft(report));
  const [restored, setRestored] = useState(false);
  const textarea = useRef<HTMLTextAreaElement>(null);
  // The latest values for the autosave callback (it runs from a timeout, after renders).
  const latest = useRef({ title, body });
  useEffect(() => {
    latest.current = { title, body };
  });

  const draft = useMdtMutation('saveReportDraft', { onSuccess: (data) => setDraftAt(data.savedAt) });
  const save = useMdtMutation('saveReport', { onSuccess: (data) => setSavedAt(data.updatedAt) });
  const autosave = useDraftAutosave(() => draft.mutateAsync({ reportId: report.id, title: latest.current.title.slice(0, 160), body: latest.current.body }));

  const edit = (fn: (e: TextEdit) => TextEdit) => {
    const el = textarea.current;
    const next = fn({ text: body, start: el?.selectionStart ?? body.length, end: el?.selectionEnd ?? body.length });
    if (next.text.length > REPORT_BODY_MAX) return;
    setBody(next.text);
    autosave.onInput();
    // Put the selection back after React has written the new value.
    requestAnimationFrame(() => {
      el?.focus();
      el?.setSelectionRange(next.start, next.end);
    });
  };

  const restore = () => {
    if (!offer) return;
    if (offer.title !== null && offer.title.trim() !== '') setTitle(offer.title);
    setBody(offer.body.slice(0, REPORT_BODY_MAX));
    setDraftAt(offer.savedAt);
    setOffer(null);
    setRestored(true);
  };

  const valid = title.trim().length >= 3;
  return (
    <div className="flex flex-col gap-4">
      {offer && (
        <Card>
          <div className="flex flex-wrap items-center gap-2" role="status" data-draft-offer>
            <span className="flex-1 text-sm">{t('report.draft.available', { time: fmtDateTime(i18n, offer.savedAt) })}</span>
            <Button size="sm" variant="primary" onClick={restore}>
              {t('report.draft.restore')}
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setOffer(null)}>
              {t('report.draft.discard')}
            </Button>
          </div>
        </Card>
      )}
      {restored && (
        <p className="text-sm text-muted" role="status" data-draft-restored>
          {t('report.draft.restored')}
        </p>
      )}
      <Card>
        <div className="flex flex-col gap-3" data-report-editor onFocus={autosave.onFocus} onBlur={autosave.onBlur}>
          <div className="grid gap-3 md:grid-cols-[minmax(0,1fr)_14rem]">
            <Label>
              {t('report.field.title')}
              <Input
                value={title}
                maxLength={160}
                onChange={(e) => {
                  setTitle(e.target.value);
                  autosave.onInput();
                }}
              />
            </Label>
            <LevelSelect value={level} onChange={setLevel} tier={grants.tier} />
          </div>
          <div className="flex items-center gap-1" role="toolbar" aria-label={t('report.field.body')}>
            <Button size="sm" variant="ghost" onMouseDown={(e) => e.preventDefault()} onClick={() => edit(applyBold)}>
              <strong>{t('report.toolbar.bold')}</strong>
            </Button>
            <Button size="sm" variant="ghost" onMouseDown={(e) => e.preventDefault()} onClick={() => edit(applyHeading)}>
              {t('report.toolbar.heading')}
            </Button>
            <Button size="sm" variant="ghost" onMouseDown={(e) => e.preventDefault()} onClick={() => edit(applyList)}>
              {t('report.toolbar.list')}
            </Button>
            <span className="flex-1" />
            <span className="text-xs text-muted" role="status" data-draft-status>
              {draft.isPending ? t('report.draft.saving') : draftAt ? t('report.draft.saved', { time: fmtTime(draftAt) }) : null}
            </span>
          </div>
          <div className="grid gap-3 lg:grid-cols-2">
            <Textarea
              ref={textarea}
              aria-label={t('report.field.body')}
              value={body}
              rows={16}
              maxLength={REPORT_BODY_MAX}
              className="font-mono text-sm"
              onChange={(e) => {
                setBody(e.target.value);
                autosave.onInput();
              }}
            />
            <div className="min-h-40 overflow-y-auto rounded-md border border-line p-3" aria-label={i18n.tx('report.preview')} data-report-preview>
              <MarkdownLite text={body} empty={t('report.empty')} />
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="primary"
              disabled={!valid}
              loading={save.isPending}
              onClick={() => {
                autosave.markClean();
                save.mutate({ id: report.id, title: title.trim(), body, level });
              }}
            >
              {t('common.save')}
            </Button>
            {savedAt && !save.isPending && <span className="text-sm text-muted">{t('common.saved')}</span>}
            <MutationError error={save.error ?? draft.error} />
          </div>
        </div>
      </Card>
    </div>
  );
}

function ReportView({ report }: { report: ReportDetail }) {
  const { t } = useI18n();
  const caseQuery = useMdtQuery('getCase', { id: report.caseId }, { enabled: report.editable });
  const subjects = caseQuery.data && caseQuery.data.visibility !== 'notice' ? caseQuery.data.subjects : [];
  return (
    <>
      <ReportHeader report={report} />
      {report.editable ? (
        <ReportEditor key={report.id} report={report} />
      ) : (
        <Card>
          <MarkdownLite text={report.body} empty={t('report.empty')} />
        </Card>
      )}
      <div className="mt-4 grid gap-4 xl:grid-cols-2">
        {report.editable && (
          <Card title={t('charge.add')}>
            <ChargePicker reportId={report.id} caseId={report.caseId} subjects={subjects} />
          </Card>
        )}
        <Card title={t('person.section.records')} padded={false}>
          <AppliedCharges report={report} />
        </Card>
      </div>
    </>
  );
}

export function ReportPage() {
  const { t } = useI18n();
  const id = parseId(useParams().id);
  const query = useMdtQuery('getReport', { id: id ?? 0 }, { enabled: id !== null });
  if (id === null) return <EmptyState title={t('report.notFound')} />;
  return (
    <QueryView query={query} notFound={t('report.notFound')}>
      {(report) => <ReportView report={report} />}
    </QueryView>
  );
}
