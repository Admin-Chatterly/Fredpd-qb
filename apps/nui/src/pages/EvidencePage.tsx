// SPDX-License-Identifier: GPL-3.0-only
// Bevis (/bevis, Phase 4 UI; docs/contracts.md §C16, docs/modules/forensics.md request 2): tabs "Att koppla"
// (listEvidence { unlinked: true }, the Tekniker work queue) and "Alla", an optional case filter, and a detail drawer
// (getEvidence) with the analysis result (the person match only when the server sent it), the chain of custody and
// "Koppla till ärende" (linkEvidence, perm evidence.link; a hint only, fredpd_forensics checks it). URL: ?queue=1
// opens the queue, ?id=<n> the drawer, ?case=<id> the filter.
import { useState } from 'react';
import { useSearchParams } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { EvidenceItem } from '@fredpd/types/evidence';
import { Badge, Button, Card, Drawer, EmptyState, PageHeader, Pagination, Table, Tabs, useActionAvailable, useI18n } from '@fredpd/ui';
import type { TableColumn } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { MdtClientError, useErrorText } from '../api/errors';
import { parseId } from '../cases';
import { CasePicker } from '../components/CasePicker';
import type { PickedCase } from '../components/CasePicker';
import { Callout, Facts, QueryView } from '../components/Common';
import { custodyText, evidenceTypeLabel, resultFields, resultMatch } from '../evidence';
import { fmtDateTime, officerLabel } from '../format';
import { PERMS, usePerm } from '../perms';

type EvidenceTab = 'queue' | 'all';

/** Refusals of linkEvidence (forensics.md "Exports": reasons already_linked, case_closed, case/evidence). */
function useLinkErrorText() {
  const { t } = useI18n();
  const errorText = useErrorText();
  return (err: unknown) => {
    if (err instanceof MdtClientError) {
      if (err.reason === 'already_linked') return t('evidence.link.alreadyLinked');
      if (err.reason === 'case_closed') return t('evidence.link.caseClosed');
      if (err.code === 'not_found') return err.reason === 'evidence' ? t('evidence.link.evidenceNotFound') : t('evidence.link.caseNotFound');
      if (err.code === 'unauthorized' && err.reason === undefined) return t('evidence.link.caseNoAccess');
    }
    return errorText(err);
  };
}

function LinkToCase({ item }: { item: EvidenceItem }) {
  const { t } = useI18n();
  const linkErrorText = useLinkErrorText();
  const [picked, setPicked] = useState<PickedCase | null>(null);
  const link = useMdtMutation('linkEvidence');
  if (link.isSuccess && link.data.tag) {
    return <Callout tone="success">{t('evidence.link.success', { tag: link.data.tag, number: link.data.caseNumber ?? '' })}</Callout>;
  }
  return (
    <div className="flex flex-col gap-2" data-link-evidence>
      <p className="text-sm font-semibold">{t('evidence.link.action')}</p>
      {picked ? (
        <div className="flex items-center gap-2 text-sm">
          <span className="font-mono">{picked.caseNumber}</span>
          <span className="flex-1" />
          <Button size="sm" onClick={() => setPicked(null)}>
            {t('common.clear')}
          </Button>
          <Button size="sm" variant="primary" loading={link.isPending} onClick={() => link.mutate({ id: item.id, caseId: picked.id })}>
            {t('evidence.link.action')}
          </Button>
        </div>
      ) : (
        <CasePicker onlyOpen onPick={setPicked} />
      )}
      {link.error && (
        <p role="alert" className="text-sm text-danger">
          {linkErrorText(link.error)}
        </p>
      )}
    </div>
  );
}

function EvidenceDetail({ item }: { item: EvidenceItem }) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  // Linking is not a portal action (portal contract: reads + records/intel/BOLO writes only).
  const linkAvailable = useActionAvailable('linkEvidence');
  const canLink = usePerm(PERMS.evidenceLink) && linkAvailable;
  const match = resultMatch(item.result);
  const fields = resultFields(item.result);
  return (
    <div className="flex flex-col gap-4" data-evidence-detail={item.id}>
      <Facts
        className="md:grid-cols-2"
        facts={[
          { label: t('evidence.field.tag'), value: item.tag },
          { label: t('evidence.field.type'), value: evidenceTypeLabel(i18n, item.type) },
          { label: t('evidence.field.case'), value: item.caseNumber },
          { label: t('evidence.field.collectedBy'), value: item.collectedBy ? officerLabel(item.collectedBy) : null },
          { label: t('evidence.field.collectedAt'), value: item.collectedAt ? fmtDateTime(i18n, item.collectedAt) : null },
          { label: t('level.label'), value: item.level > 0 ? <Badge level={item.level} /> : null },
        ]}
      />
      <section>
        <h3 className="mb-1 text-sm font-semibold">{t('evidence.field.result')}</h3>
        {item.result === null ? (
          <p className="text-sm text-muted">{tx('evidence.notAnalysed')}</p>
        ) : (
          <>
            {match ? <p className="text-sm font-medium text-danger">{t('evidence.match', { name: match.name })}</p> : null}
            {fields.length > 0 && (
              <dl className="mt-1 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
                {fields.map(([key, value]) => (
                  <div key={key} className="min-w-0">
                    <dt className="text-xs text-muted">{tx(`evidence.result.${key}`, undefined, key)}</dt>
                    <dd className="truncate">{value}</dd>
                  </div>
                ))}
              </dl>
            )}
          </>
        )}
      </section>
      <section>
        <h3 className="mb-1 text-sm font-semibold">{t('evidence.field.chain')}</h3>
        {item.chain.length === 0 ? (
          <p className="text-sm text-muted">{t('common.empty')}</p>
        ) : (
          <ol className="flex flex-col gap-2 border-l border-line pl-3" data-chain>
            {item.chain.map((entry, i) => (
              <li key={`${entry.at}-${i}`} className="text-sm">
                <p className="text-fg">{custodyText(i18n, entry, item)}</p>
                <p className="text-xs text-muted">
                  {fmtDateTime(i18n, entry.at)}
                  {entry.location && ` · ${entry.location}`}
                </p>
                {entry.note && <p className="text-xs text-muted">{entry.note}</p>}
              </li>
            ))}
          </ol>
        )}
      </section>
      {canLink && item.caseId === null && <LinkToCase item={item} />}
    </div>
  );
}

function EvidenceDrawer({ id, onClose }: { id: number; onClose: () => void }) {
  const { t } = useI18n();
  const query = useMdtQuery('getEvidence', { id });
  return (
    <Drawer open title={query.data?.tag ?? t('evidence.title')} onClose={onClose}>
      <QueryView query={query} notFound={t('evidence.link.evidenceNotFound')}>
        {(item) => <EvidenceDetail item={item} />}
      </QueryView>
    </Drawer>
  );
}

export function EvidencePage() {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const [params, setParams] = useSearchParams();
  const openId = parseId(params.get('id') ?? undefined);
  const caseFilter = parseId(params.get('case') ?? undefined);
  const [tab, setTab] = useState<EvidenceTab>(params.get('queue') === '1' ? 'queue' : 'all');
  const [page, setPage] = useState(1);
  const [filtering, setFiltering] = useState(false);
  const input = caseFilter !== null ? { caseId: caseFilter, page } : { unlinked: tab === 'queue', page };
  const list = useMdtQuery('listEvidence', input, { keepPrevious: true });

  const setParam = (key: string, value: string | null) => {
    const next = new URLSearchParams(params);
    if (value === null) next.delete(key);
    else next.set(key, value);
    setParams(next);
  };

  const columns: TableColumn<EvidenceItem>[] = [
    { id: 'tag', header: t('evidence.field.tag'), cell: (e) => (e.tag ? <span className="font-mono">{e.tag}</span> : null), className: 'whitespace-nowrap' },
    { id: 'type', header: t('evidence.field.type'), cell: (e) => evidenceTypeLabel(i18n, e.type) },
    { id: 'case', header: t('evidence.field.case'), cell: (e) => e.caseNumber, className: 'whitespace-nowrap' },
    { id: 'collectedBy', header: t('evidence.field.collectedBy'), cell: (e) => (e.collectedBy ? officerLabel(e.collectedBy) : null) },
    { id: 'collectedAt', header: t('evidence.field.collectedAt'), cell: (e) => (e.collectedAt ? fmtDateTime(i18n, e.collectedAt) : null), className: 'whitespace-nowrap text-muted' },
    { id: 'match', header: <span className="sr-only">{t('evidence.field.result')}</span>, cell: (e) => (resultMatch(e.result) ? <Badge tone="danger">{t('vehicle.checkHit')}</Badge> : null) },
  ];

  return (
    <>
      <PageHeader title={t('evidence.title')} />
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <Tabs
          label={t('common.filter')}
          value={tab}
          onChange={(next) => {
            setTab(next);
            setPage(1);
            setParam('case', null);
          }}
          items={[
            { id: 'queue', label: tx('evidence.tab.queue'), disabled: caseFilter !== null },
            { id: 'all', label: t('common.all'), disabled: caseFilter !== null },
          ]}
        />
        <span className="flex-1" />
        {caseFilter !== null ? (
          <Button size="sm" onClick={() => setParam('case', null)}>
            {t('common.clear')}
          </Button>
        ) : (
          <Button size="sm" onClick={() => setFiltering((v) => !v)} aria-expanded={filtering}>
            {t('evidence.field.case')}
          </Button>
        )}
      </div>
      {filtering && caseFilter === null && (
        <Card className="mb-3">
          <CasePicker
            onPick={(c) => {
              setFiltering(false);
              setPage(1);
              setParam('case', String(c.id));
            }}
          />
        </Card>
      )}
      <Card padded={false}>
        <QueryView query={list}>
          {(data) => (
            <>
              <Table
                columns={columns}
                rows={data.items}
                getRowKey={(e) => e.id}
                onRowClick={(e) => setParam('id', String(e.id))}
                empty={<EmptyState title={t('evidence.none')} />}
              />
              <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
            </>
          )}
        </QueryView>
      </Card>
      {openId !== null && <EvidenceDrawer id={openId} onClose={() => setParam('id', null)} />}
    </>
  );
}
