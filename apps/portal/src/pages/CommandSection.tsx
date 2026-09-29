// SPDX-License-Identifier: GPL-3.0-only
// Ledning in the portal (/ledning/*, mdt_page:command): Surfplattor (the tablet's page; revoke/reinstate are tablet
// writes and hidden here), Utlämningskö (release requests: decide with masking, perm records.admin) and Granskning
// (audit view: no action exists yet, placeholder; docs/modules/portal.md integration requests).
import { useState } from 'react';
import { Link, Route, Routes } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import { Badge, Button, Card, EmptyState, IconBook, IconFolder, IconKey, IconShield, Label, PageHeader, Pagination, Tabs, Textarea, fieldClass, useI18n } from '@fredpd/ui';
import type { BadgeTone } from '@fredpd/ui';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { CasePicker } from '../mdt/shared-pages';
import type { PickedCase } from '../mdt/shared-pages';
import { ReleasedContentView } from '../components/ReleasedContentView';
import { readReleaseList, readReleaseRequest, useExtraMutation, useExtraQuery } from '../mdt/extra';
import type { ReleaseRequest, ReleaseStatus } from '../mdt/extra';
import { NotAvailableYet, isActionMissing } from '../components/NotAvailableYet';
import { Callout, PERMS, QueryView, fmtDateTime, officerLabel, useErrorText, usePerm } from '../mdt/shared';
import type { MdtClientError } from '../mdt/shared';
import { TabletsPage } from '../mdt/pages';
import { NotFoundPage } from './NotFoundPage';

export const RELEASE_STATUS_KEYS: Readonly<Record<ReleaseStatus, LocaleKey>> = {
  pending: 'release.status.pending',
  approved: 'release.status.approved',
  partial: 'release.status.partial',
  denied: 'release.status.denied',
};
const RELEASE_STATUS_TONES: Readonly<Record<ReleaseStatus, BadgeTone>> = { pending: 'warning', approved: 'success', partial: 'accent', denied: 'neutral' };

type Decision = 'approved' | 'partial' | 'denied';
const DECISION_KEYS: Readonly<Record<Decision, LocaleKey>> = {
  approved: 'release.decision.release',
  partial: 'release.decision.releaseMasked',
  denied: 'release.decision.deny',
};

/** Refusal reasons of decideReleaseRequest (records.md "Release requests") with their own text. */
const DECIDE_REASON_KEYS: Readonly<Record<string, string>> = {
  no_target: 'release.error.noTarget',
  nothing_releasable: 'release.error.nothingReleasable',
  already_decided: 'release.error.alreadyDecided',
};

function useDecideErrorText() {
  const { tx } = useI18n();
  const errorText = useErrorText();
  return (err: MdtClientError | null) => {
    if (!err) return null;
    const key = err.reason ? DECIDE_REASON_KEYS[err.reason] : undefined;
    return key ? tx(key) : errorText(err);
  };
}

function DecideForm({ request, onDone }: { request: ReleaseRequest; onDone: (r: ReleaseRequest) => void }) {
  const { t, tx } = useI18n();
  const decideError = useDecideErrorText();
  const [decision, setDecision] = useState<Decision>('partial');
  const [note, setNote] = useState('');
  const [picked, setPicked] = useState<PickedCase | null>(null);
  const known = request.target && (request.target.type === 'case' || request.target.type === 'report') && /^\d+$/.test(request.target.id) ? request.target : null;
  const decide = useExtraMutation<Record<string, unknown>, ReleaseRequest>('decideReleaseRequest', readReleaseRequest, {
    invalidates: ['listReleaseRequests'],
    onSuccess: onDone,
  });
  const needsTarget = decision !== 'denied' && !known && !picked;

  const submit = () => {
    const input: Record<string, unknown> = { id: request.id, decision };
    if (note.trim()) input.note = note.trim();
    if (decision !== 'denied') {
      if (known) {
        input.targetType = known.type;
        input.targetId = Number(known.id);
      } else if (picked) {
        input.targetType = 'case';
        input.targetId = picked.id;
      }
    }
    decide.mutate(input);
  };

  return (
    <div className="flex flex-col gap-3 border-t border-line pt-3" data-decide={request.id}>
      <Label className="w-64">
        {t('common.type')}
        <select className={fieldClass} value={decision} onChange={(e) => setDecision(e.target.value as Decision)} data-decision>
          {(Object.keys(DECISION_KEYS) as Decision[]).map((d) => (
            <option key={d} value={d}>
              {t(DECISION_KEYS[d])}
            </option>
          ))}
        </select>
      </Label>
      {decision !== 'denied' &&
        (known ? (
          <p className="text-sm text-fg">
            {tx('release.field.target')}: <span className="font-mono">{known.label ?? known.id}</span>
          </p>
        ) : picked ? (
          <p className="flex items-center gap-2 text-sm text-fg">
            {tx('release.field.target')}: <span className="font-mono">{picked.caseNumber}</span>
            <Button size="sm" variant="ghost" onClick={() => setPicked(null)}>
              {t('common.clear')}
            </Button>
          </p>
        ) : (
          <CasePicker onPick={setPicked} label={tx('release.field.target')} />
        ))}
      <Label>
        {t('release.field.grounds')}
        <Textarea value={note} maxLength={2000} rows={3} onChange={(e) => setNote(e.target.value)} />
      </Label>
      {decision === 'partial' && <p className="text-xs text-muted">{t('release.masked')}</p>}
      {decide.isError && <Callout tone="danger">{decideError(decide.error)}</Callout>}
      <div>
        <Button variant={decision === 'denied' ? 'danger' : 'primary'} loading={decide.isPending} disabled={needsTarget} onClick={submit}>
          {t(DECISION_KEYS[decision])}
        </Button>
      </div>
    </div>
  );
}

function ReleaseRow({ request }: { request: ReleaseRequest }) {
  const i18n = useI18n();
  const { t } = i18n;
  const [open, setOpen] = useState(false);
  const [done, setDone] = useState<ReleaseRequest | null>(null);
  const shown = done ?? request;
  return (
    <li data-release={shown.id} data-status={shown.status} className="flex flex-col gap-2 px-4 py-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm text-muted">#{shown.id}</span>
        <span className="min-w-0 flex-1 truncate font-medium text-fg">{shown.requesterName ?? t('common.unknown')}</span>
        <Badge tone={RELEASE_STATUS_TONES[shown.status]}>{t(RELEASE_STATUS_KEYS[shown.status])}</Badge>
        <span className="text-sm text-muted">{fmtDateTime(i18n, shown.createdAt)}</span>
      </div>
      <p className="text-sm whitespace-pre-line text-fg">{shown.description}</p>
      {shown.target?.label && <p className="font-mono text-xs text-muted">{shown.target.label}</p>}
      {shown.decidedBy && (
        <p className="text-xs text-muted">
          {t('release.field.decidedBy')}: {officerLabel(shown.decidedBy)}
          {shown.decidedAt && ` · ${fmtDateTime(i18n, shown.decidedAt)}`}
        </p>
      )}
      {shown.decisionNote && <p className="text-sm text-muted">{shown.decisionNote}</p>}
      {done && <Callout tone="success">{t('release.decided')}</Callout>}
      {shown.released && (
        <div className="rounded-md border border-line bg-canvas p-3">
          <p className="mb-2 text-xs text-muted">{t('release.masked')}</p>
          <ReleasedContentView content={shown.released} />
        </div>
      )}
      {shown.status === 'pending' &&
        (open ? (
          <DecideForm request={shown} onDone={setDone} />
        ) : (
          <div>
            <Button size="sm" onClick={() => setOpen(true)}>
              {t('common.open')}
            </Button>
          </div>
        ))}
    </li>
  );
}

type QueueTab = 'pending' | 'all';

export function ReleaseQueuePage() {
  const { t } = useI18n();
  const isAdmin = usePerm(PERMS.recordsAdmin);
  const [tab, setTab] = useState<QueueTab>('pending');
  const [page, setPage] = useState(1);
  const input = tab === 'pending' ? { status: 'pending', page } : { page };
  const list = useExtraQuery('listReleaseRequests', input, readReleaseList, isAdmin);
  if (!isAdmin) return <NotFoundPage />;
  return (
    <>
      <PageHeader title={t('release.queue')} />
      <Tabs
        className="mb-3"
        label={t('common.filter')}
        value={tab}
        onChange={(v) => {
          setTab(v);
          setPage(1);
        }}
        items={[
          { id: 'pending', label: t('release.status.pending') },
          { id: 'all', label: t('common.all') },
        ]}
      />
      <Card padded={false}>
        {list.isError && isActionMissing(list.error) ? (
          <NotAvailableYet />
        ) : (
          <QueryView query={list}>
            {(data) =>
              data.items.length === 0 ? (
                <EmptyState title={t('release.none')} />
              ) : (
                <>
                  <ul className="flex flex-col divide-y divide-line">
                    {data.items.map((r) => (
                      <ReleaseRow key={r.id} request={r} />
                    ))}
                  </ul>
                  <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
                </>
              )
            }
          </QueryView>
        )}
      </Card>
    </>
  );
}

/** Granskning: no audit-read action exists yet (integration request in docs/modules/portal.md). */
export function AuditPage() {
  const { t, tx } = useI18n();
  const isAdmin = usePerm(PERMS.recordsAdmin);
  if (!isAdmin) return <NotFoundPage />;
  return (
    <>
      <PageHeader title={t('nav.audit')} />
      <Card padded={false}>
        <EmptyState icon={<IconBook size={28} />} title={tx('portal.audit.pending')} />
      </Card>
    </>
  );
}

function CommandHome() {
  const { t } = useI18n();
  const canTablets = usePerm(PERMS.tabletsManage);
  const isAdmin = usePerm(PERMS.recordsAdmin);
  const links = [
    canTablets && { to: 'surfplattor', label: t('nav.tablets'), icon: <IconKey className="text-accent-text" /> },
    isAdmin && { to: 'utlamning', label: t('nav.releases'), icon: <IconFolder className="text-accent-text" /> },
    isAdmin && { to: 'granskning', label: t('nav.audit'), icon: <IconShield className="text-accent-text" /> },
  ].filter((l): l is { to: string; label: string; icon: React.JSX.Element } => !!l);
  return (
    <>
      <PageHeader title={t('nav.command')} />
      {links.length > 0 ? (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          {links.map((l) => (
            <Link key={l.to} to={l.to} data-command-link={l.to} className="flex items-center gap-3 rounded-lg border border-line bg-surface px-4 py-3 hover:border-line-strong">
              {l.icon}
              <span className="font-medium">{l.label}</span>
            </Link>
          ))}
        </div>
      ) : (
        <Card padded={false}>
          <EmptyState title={t('home.empty')} />
        </Card>
      )}
    </>
  );
}

export function CommandSection() {
  return (
    <Routes>
      <Route index element={<CommandHome />} />
      <Route path="surfplattor" element={<TabletsPage />} />
      <Route path="utlamning" element={<ReleaseQueuePage />} />
      <Route path="granskning" element={<AuditPage />} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  );
}

