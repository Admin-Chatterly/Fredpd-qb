// SPDX-License-Identifier: GPL-3.0-only
// Ärende (/arende/:id, task 5.2): getCase, shaped by canView (docs/contracts.md §C3, §C14):
// - notice (kontaktnotis): ONLY the Notice component with the contact; nothing else of the answer is read;
// - masked: Standard parts; title/summary and report titles may be null and are then simply not rendered;
//   read-only;
// - full: header, assignees (add/remove), subjects (add through the search picker), reports (new report with a
//   template), evidence, timeline; close with a resolution.
// Edit rules (owner, lead, records.admin) are the server's: controls are offered on a full, open case and a refusal
// is shown as its error text.
import { useState } from 'react';
import type { ReactNode } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import type { Level } from '@fredpd/types/mdt';
import type { CaseDetail } from '@fredpd/types/records';
import { Badge, Button, Card, Dialog, EmptyState, IconPlus, Input, Label, PageHeader, Textarea, fieldClass, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import type { BoloKind } from '../bolo';
import {
  ASSIGNEE_ROLE_KEYS,
  CASE_STATUS_KEYS,
  RESOLUTION_MAX,
  RESOLUTION_MIN,
  SUBJECT_ROLES,
  SUBJECT_ROLE_KEYS,
  caseEditable,
  parseId,
  reportPath,
} from '../cases';
import type { SubjectRole, VisibleCase } from '../cases';
import { SubjectPicker } from '../components/Bolos';
import { CaseNotice } from '../components/CaseRefs';
import { Facts, QueryView } from '../components/Common';
import { LevelSelect, MutationError, OfficerPicker } from '../components/Fields';
import { evidenceTypeLabel } from '../evidence';
import { fmtDateTime, officerLabel, unitLabel } from '../format';
import { personPath, vehiclePath } from '../search';
import { useSession } from '../session';

type Section = { title: string; actions?: ReactNode; children: ReactNode };
function SectionCard({ title, actions, children }: Section) {
  return (
    <Card title={title} actions={actions} padded={false}>
      {children}
    </Card>
  );
}

function Assignees({ detail }: { detail: VisibleCase }) {
  const { t } = useI18n();
  const editable = caseEditable(detail);
  const [role, setRole] = useState<'lead' | 'member'>('member');
  const assign = useMdtMutation('assignCase');
  const unassign = useMdtMutation('unassignCase');
  return (
    <SectionCard title={t('case.field.assignees')}>
      {detail.assignees.length === 0 ? (
        <EmptyState title={t('common.empty')} />
      ) : (
        <ul className="flex flex-col divide-y divide-line">
          {detail.assignees.map((a) => (
            <li key={a.citizenid} data-assignee={a.citizenid} className="flex items-center gap-2 px-4 py-2 text-sm">
              <span className="min-w-0 flex-1 truncate">{officerLabel(a)}</span>
              <Badge tone={a.role === 'lead' ? 'accent' : 'neutral'}>{t(ASSIGNEE_ROLE_KEYS[a.role])}</Badge>
              {editable && (
                <Button size="sm" variant="ghost" disabled={unassign.isPending} onClick={() => unassign.mutate({ id: detail.id, citizenid: a.citizenid })}>
                  {t('case.action.removeAssignee')}
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}
      {editable && (
        <div className="flex flex-col gap-2 border-t border-line px-4 py-3">
          <div className="flex items-end gap-2">
            <Label className="w-48">
              {t('common.type')}
              <select className={fieldClass} value={role} onChange={(e) => setRole(e.target.value as 'lead' | 'member')}>
                <option value="member">{t('case.assignee.role.member')}</option>
                <option value="lead">{t('case.assignee.role.lead')}</option>
              </select>
            </Label>
          </div>
          <OfficerPicker
            actionLabel={t('case.action.addAssignee')}
            busy={assign.isPending}
            exclude={detail.assignees.map((a) => a.citizenid)}
            onPick={(o) => assign.mutate({ id: detail.id, citizenid: o.citizenid, role })}
          />
          <MutationError error={assign.error ?? unassign.error} />
        </div>
      )}
    </SectionCard>
  );
}

function Subjects({ detail }: { detail: VisibleCase }) {
  const { t, tx } = useI18n();
  const editable = caseEditable(detail);
  const [adding, setAdding] = useState(false);
  const [kind, setKind] = useState<BoloKind>('person');
  const [role, setRole] = useState<SubjectRole>('suspect');
  const add = useMdtMutation('addCaseSubject', { onSuccess: () => setAdding(false) });
  return (
    <SectionCard
      title={t('case.field.subjects')}
      actions={
        editable && (
          <Button size="sm" icon={<IconPlus size={14} />} onClick={() => setAdding((v) => !v)} aria-expanded={adding}>
            {t('case.action.addSubject')}
          </Button>
        )
      }
    >
      {detail.subjects.length === 0 ? (
        <EmptyState title={t('common.empty')} />
      ) : (
        <ul className="flex flex-col divide-y divide-line">
          {detail.subjects.map((s) => (
            <li key={s.type === 'person' ? `p-${s.citizenid}` : `v-${s.plate}`} className="flex items-center gap-2 px-4 py-2 text-sm">
              <span className="text-xs text-muted">{t(s.type === 'person' ? 'case.subject.person' : 'case.subject.vehicle')}</span>
              <Link to={s.type === 'person' ? personPath(s.citizenid) : vehiclePath(s.plate)} className="min-w-0 flex-1 truncate text-accent-text hover:underline">
                {s.label}
              </Link>
              <span className="text-xs text-muted">{t(SUBJECT_ROLE_KEYS[s.role])}</span>
            </li>
          ))}
        </ul>
      )}
      {editable && adding && (
        <div className="flex flex-col gap-2 border-t border-line px-4 py-3" data-subject-form>
          <div className="flex gap-2">
            <Label className="w-40">
              {t('common.type')}
              <select className={fieldClass} value={kind} onChange={(e) => setKind(e.target.value as BoloKind)}>
                <option value="person">{t('case.subject.person')}</option>
                <option value="vehicle">{t('case.subject.vehicle')}</option>
              </select>
            </Label>
            <Label className="w-40">
              {tx('case.subject.roleLabel')}
              <select className={fieldClass} value={role} onChange={(e) => setRole(e.target.value as SubjectRole)}>
                {SUBJECT_ROLES.map((r) => (
                  <option key={r} value={r}>
                    {t(SUBJECT_ROLE_KEYS[r])}
                  </option>
                ))}
              </select>
            </Label>
          </div>
          <SubjectPicker
            key={kind}
            kind={kind}
            onPick={(subject) =>
              add.mutate(
                subject.kind === 'person'
                  ? { id: detail.id, type: 'person', citizenid: subject.citizenid, role }
                  : { id: detail.id, type: 'vehicle', plate: subject.plate, role },
              )
            }
          />
          <MutationError error={add.error} />
        </div>
      )}
    </SectionCard>
  );
}

function NewReportDialog({ caseId, onClose }: { caseId: number; onClose: () => void }) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const { grants } = useSession();
  const templates = useMdtQuery('listReportTemplates', {});
  const [title, setTitle] = useState('');
  const [templateId, setTemplateId] = useState<number | null>(null);
  const [level, setLevel] = useState<Level>(0);
  const create = useMdtMutation('createReport', {
    onSuccess: (data) => {
      onClose();
      void navigate(reportPath(data.id));
    },
  });
  const valid = title.trim().length >= 3;
  return (
    <Dialog
      open
      title={t('report.new')}
      onClose={onClose}
      dismissOnBackdrop={false}
      footer={
        <>
          <Button onClick={onClose}>{t('common.cancel')}</Button>
          <Button
            variant="primary"
            loading={create.isPending}
            disabled={!valid}
            onClick={() => create.mutate({ caseId, title: title.trim(), level, ...(templateId !== null ? { templateId } : {}) })}
          >
            {t('common.create')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <Label>
          {t('report.field.title')}
          <Input value={title} maxLength={160} onChange={(e) => setTitle(e.target.value)} />
        </Label>
        <Label>
          {t('report.field.template')}
          <select className={fieldClass} value={templateId ?? ''} onChange={(e) => setTemplateId(e.target.value === '' ? null : Number(e.target.value))}>
            <option value="">{t('report.template.none')}</option>
            {(templates.data?.items ?? []).map((tpl) => (
              <option key={tpl.id} value={tpl.id}>
                {tpl.name}
              </option>
            ))}
          </select>
        </Label>
        <LevelSelect value={level} onChange={setLevel} tier={grants.tier} />
        <MutationError error={create.error} />
      </div>
    </Dialog>
  );
}

function CloseCaseDialog({ detail, onClose }: { detail: VisibleCase; onClose: () => void }) {
  const { t, tx } = useI18n();
  const [resolution, setResolution] = useState('');
  const close = useMdtMutation('closeCase', { onSuccess: onClose });
  const valid = resolution.trim().length >= RESOLUTION_MIN;
  return (
    <Dialog
      open
      title={t('case.action.close')}
      onClose={onClose}
      dismissOnBackdrop={false}
      footer={
        <>
          <Button onClick={onClose}>{t('common.cancel')}</Button>
          <Button variant="danger" loading={close.isPending} disabled={!valid} onClick={() => close.mutate({ id: detail.id, resolution: resolution.trim() })}>
            {t('case.action.close')}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <p className="text-sm text-muted">{t('case.close.confirm', { number: detail.caseNumber })}</p>
        <Label>
          {tx('case.field.resolution')}
          <Textarea value={resolution} rows={4} maxLength={RESOLUTION_MAX} onChange={(e) => setResolution(e.target.value)} />
        </Label>
        <MutationError error={close.error} />
      </div>
    </Dialog>
  );
}

function CaseView({ detail }: { detail: VisibleCase }) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const navigate = useNavigate();
  const editable = caseEditable(detail);
  const [newReport, setNewReport] = useState(false);
  const [closing, setClosing] = useState(false);
  const hasTitle = detail.title !== null && detail.title !== '';

  return (
    <>
      <PageHeader
        title={
          <span className="flex items-center gap-2">
            <span className="font-mono">{detail.caseNumber}</span>
            {hasTitle && <span className="truncate">{detail.title}</span>}
          </span>
        }
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            <Badge tone={detail.status === 'open' ? 'accent' : 'neutral'}>{t(CASE_STATUS_KEYS[detail.status])}</Badge>
            <Badge level={detail.level} />
            {detail.visibility === 'masked' && <Badge tone="warning">{t('visibility.masked.badge')}</Badge>}
          </span>
        }
        actions={
          editable && (
            <>
              <Button icon={<IconPlus size={16} />} onClick={() => setNewReport(true)}>
                {t('case.action.newReport')}
              </Button>
              <Button variant="danger" onClick={() => setClosing(true)}>
                {t('case.action.close')}
              </Button>
            </>
          )
        }
      />
      {detail.visibility === 'masked' && (
        <p role="note" className="mb-4 rounded-md border border-warning/40 bg-warning/10 px-3 py-1.5 text-sm text-warning">
          {t('visibility.masked.text')}
        </p>
      )}
      <Card className="mb-4">
        <Facts
          facts={[
            { label: t('case.field.unit'), value: detail.unit ? unitLabel(i18n, detail.unit) : null },
            { label: t('case.field.createdBy'), value: detail.owner ? officerLabel(detail.owner) : null },
            { label: t('common.createdAt'), value: fmtDateTime(i18n, detail.createdAt) },
            { label: t('case.status.closed'), value: detail.closedAt ? fmtDateTime(i18n, detail.closedAt) : null },
          ]}
        />
        {detail.summary !== null && detail.summary !== '' && (
          <div className="mt-4">
            <p className="text-xs text-muted">{t('case.field.summary')}</p>
            <p className="text-sm whitespace-pre-line text-fg">{detail.summary}</p>
          </div>
        )}
      </Card>
      <div className="grid gap-4 xl:grid-cols-2">
        <Assignees detail={detail} />
        <Subjects detail={detail} />
        <SectionCard title={t('case.section.reports')}>
          {detail.reports.length === 0 ? (
            <EmptyState title={t('report.none')} />
          ) : (
            <ul className="flex flex-col divide-y divide-line">
              {detail.reports.map((r) => (
                <li key={r.id} data-report-id={r.id}>
                  <Link to={reportPath(r.id)} className="flex items-center gap-2 px-4 py-2 text-sm hover:bg-raised">
                    <span className="font-mono text-fg">{r.reportNumber}</span>
                    <span className="min-w-0 flex-1 truncate">{r.title !== null && r.title !== '' ? r.title : null}</span>
                    {r.level > 0 && <Badge level={r.level} />}
                    {r.author && <span className="text-xs text-muted">{officerLabel(r.author)}</span>}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </SectionCard>
        <SectionCard
          title={t('case.section.evidence')}
          actions={
            editable && (
              <Button size="sm" onClick={() => void navigate('/bevis?queue=1')}>
                {t('case.action.linkEvidence')}
              </Button>
            )
          }
        >
          {detail.evidence.length === 0 ? (
            <EmptyState title={t('evidence.none')} />
          ) : (
            <ul className="flex flex-col divide-y divide-line">
              {detail.evidence.map((e) => (
                <li key={e.id} data-evidence-id={e.id}>
                  <Link to={`/bevis?id=${e.id}`} className="flex items-center gap-2 px-4 py-2 text-sm hover:bg-raised">
                    <span className="font-mono text-fg">{e.tag}</span>
                    <span className="flex-1 text-muted">{evidenceTypeLabel(i18n, e.type)}</span>
                    {e.collectedAt && <span className="text-xs text-muted">{fmtDateTime(i18n, e.collectedAt)}</span>}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </SectionCard>
      </div>
      <Card title={t('case.section.timeline')} padded={false} className="mt-4">
        {detail.timeline.length === 0 ? (
          <EmptyState title={t('common.empty')} />
        ) : (
          <ol className="flex flex-col divide-y divide-line">
            {detail.timeline.map((entry, i) => (
              <li key={`${entry.at}-${i}`} className="flex flex-wrap items-center gap-x-3 px-4 py-2 text-sm">
                <time dateTime={entry.at} className="text-xs text-muted">
                  {fmtDateTime(i18n, entry.at)}
                </time>
                <span className="text-fg">{tx(`audit.action.${entry.action}`, undefined, entry.action)}</span>
                {entry.detail && <span className="text-muted">{entry.detail}</span>}
                {entry.actor && <span className="ml-auto text-xs text-muted">{officerLabel(entry.actor)}</span>}
              </li>
            ))}
          </ol>
        )}
      </Card>
      {newReport && <NewReportDialog caseId={detail.id} onClose={() => setNewReport(false)} />}
      {closing && <CloseCaseDialog detail={detail} onClose={() => setClosing(false)} />}
    </>
  );
}

/** The case as canView shaped it; a notice renders nothing but the Notice. */
export function CaseDetailView({ detail }: { detail: CaseDetail }) {
  const { t } = useI18n();
  if (detail.visibility === 'notice') {
    return (
      <div data-case-visibility="notice" className="max-w-xl">
        <CaseNotice contact={detail.contact} subject={t('case.notice.subject')} />
      </div>
    );
  }
  return (
    <div data-case-visibility={detail.visibility}>
      <CaseView detail={detail} />
    </div>
  );
}

export function CasePage() {
  const { t } = useI18n();
  const id = parseId(useParams().id);
  const query = useMdtQuery('getCase', { id: id ?? 0 }, { enabled: id !== null });
  if (id === null) return <EmptyState title={t('case.notFound')} />;
  return <QueryView query={query} notFound={t('case.notFound')}>{(detail) => <CaseDetailView detail={detail} />}</QueryView>;
}
