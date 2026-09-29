// SPDX-License-Identifier: GPL-3.0-only
// Person page (/person/:cid, task 2.4) from getPerson (PersonSummary, canView applied by fredpd_records):
// header facts, actions (Efterlys opens the BOLO dialog prefilled with this person; Lägg i ärende / Ny rapport /
// POI-blad come in phase 5), vehicles, BOLOs, cases (full / masked / kontaktnotis) and the belastningsregister
// with fine sums. A field the server did not send is never rendered.
import { useState } from 'react';
import { Link, useParams } from 'react-router';
import type { Bolo, PersonSummary } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { Badge, Button, Card, EmptyState, IconFlag, PageHeader, Table, useI18n } from '@fredpd/ui';
import type { TableColumn } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { BoloCreateDialog, BoloList, BoloResolveDialog } from '../components/Bolos';
import { CaseRefList } from '../components/CaseRefs';
import { Callout, ComingSoonButton, Facts, QueryView } from '../components/Common';
import { fmtCurrency, fmtDate } from '../format';
import { PERMS, usePerm } from '../perms';
import { vehiclePath } from '../search';
import { useSession } from '../tablet/TabletContext';

type RecordRow = PersonSummary['records'][number];

const GENDER_KEYS: Readonly<Record<PersonSummary['person']['gender'], LocaleKey>> = {
  male: 'person.gender.male',
  female: 'person.gender.female',
  unknown: 'person.gender.unknown',
};

export function recordTotals(records: readonly RecordRow[]): { fine: number; jailMinutes: number } {
  return records.reduce((sum, r) => ({ fine: sum.fine + r.fine, jailMinutes: sum.jailMinutes + r.jailMinutes }), { fine: 0, jailMinutes: 0 });
}

function Records({ records }: { records: readonly RecordRow[] }) {
  const { t } = useI18n();
  const columns: TableColumn<RecordRow>[] = [
    { id: 'date', header: t('common.date'), cell: (r) => fmtDate(r.createdAt), className: 'whitespace-nowrap' },
    { id: 'code', header: t('charge.field.code'), cell: (r) => <span className="font-mono">{r.chargeCode}</span> },
    { id: 'title', header: t('charge.field.title'), cell: (r) => r.title },
    { id: 'fine', header: t('charge.field.fine'), cell: (r) => (r.fine > 0 ? fmtCurrency(r.fine) : null), className: 'whitespace-nowrap text-right', headerClassName: 'text-right' },
    { id: 'jail', header: t('charge.field.jail'), cell: (r) => (r.jailMinutes > 0 ? t('time.duration.minutes', { count: r.jailMinutes }) : null), className: 'whitespace-nowrap' },
    { id: 'case', header: t('case.field.number'), cell: (r) => (r.caseNumber ? <span className="font-mono">{r.caseNumber}</span> : null) },
  ];
  const totals = recordTotals(records);
  return (
    <>
      <Table columns={columns} rows={records} getRowKey={(r) => r.id} empty={<EmptyState title={t('person.noRecords')} />} />
      {records.length > 0 && (
        <p data-record-total className="flex justify-end gap-4 border-t border-line px-3 py-2 text-sm text-fg">
          <span>{t('charge.totalFine', { amount: fmtCurrency(totals.fine) })}</span>
        </p>
      )}
    </>
  );
}

export function PersonView({ data }: { data: PersonSummary }) {
  const { t, tx } = useI18n();
  const { grants } = useSession();
  const canCreate = usePerm(PERMS.boloCreate);
  const canResolve = usePerm(PERMS.boloResolve);
  const [creating, setCreating] = useState(false);
  const [resolving, setResolving] = useState<Bolo | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  const { person } = data;
  const name = `${person.firstname} ${person.lastname}`.trim();
  const wanted = data.bolos.some((b) => b.active);

  return (
    <div data-person={person.citizenid}>
      <PageHeader
        title={
          <span className="flex items-center gap-2">
            {name}
            {wanted && <Badge tone="danger">{t('person.wanted')}</Badge>}
          </span>
        }
        subtitle={person.personnummer ?? undefined}
        actions={
          <>
            {canCreate && (
              <span title={wanted ? t('bolo.create.duplicate', { subject: name }) : undefined} className="inline-flex">
                <Button variant="danger" icon={<IconFlag size={16} />} disabled={wanted} onClick={() => setCreating(true)}>
                  {t('person.action.bolo')}
                </Button>
              </span>
            )}
            <ComingSoonButton>{t('person.action.addToCase')}</ComingSoonButton>
            <ComingSoonButton>{t('person.action.newReport')}</ComingSoonButton>
            <ComingSoonButton>{t('person.action.poiSheet')}</ComingSoonButton>
          </>
        }
      />
      {message && (
        <Callout tone="success" className="mb-4">
          {message}
        </Callout>
      )}
      <Card className="mb-4">
        <Facts
          facts={[
            { label: t('person.field.personId'), value: person.personnummer },
            { label: t('person.field.birthdate'), value: person.birthdate },
            { label: t('person.field.gender'), value: t(GENDER_KEYS[person.gender]) },
            { label: t('person.field.phone'), value: person.phone },
            { label: tx('person.field.address'), value: data.address },
          ]}
        />
      </Card>
      <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Card title={t('person.section.bolos')} padded={false}>
          <BoloList bolos={data.bolos} onResolve={canResolve ? setResolving : undefined} />
        </Card>
        <Card title={t('person.section.vehicles')} padded={false}>
          {data.vehicles.length === 0 ? (
            <EmptyState title={t('person.noVehicles')} />
          ) : (
            <ul className="flex flex-col gap-1 p-2">
              {data.vehicles.map((v) => (
                <li key={v.plate}>
                  <Link to={vehiclePath(v.plate)} className="flex min-h-10 items-center gap-3 rounded-md px-2 py-1.5 hover:bg-raised">
                    <span className="font-mono font-semibold text-fg">{v.plate}</span>
                    <span className="min-w-0 flex-1 truncate text-sm text-muted">{v.model}</span>
                    {v.bolo && <Badge tone="danger">{t('vehicle.wanted')}</Badge>}
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title={t('person.section.cases')} padded={false} className="xl:col-span-2">
          <CaseRefList refs={data.cases} subject={name} empty={t('person.noCases')} />
        </Card>
        <Card title={t('person.section.records')} padded={false} className="xl:col-span-2">
          <Records records={data.records} />
        </Card>
      </div>
      {creating && (
        <BoloCreateDialog
          kind="person"
          subject={{ kind: 'person', citizenid: person.citizenid, label: name }}
          tier={grants.tier}
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            setMessage(t('bolo.create.success'));
          }}
        />
      )}
      {resolving && (
        <BoloResolveDialog
          bolo={resolving}
          onClose={() => setResolving(null)}
          onResolved={() => {
            setResolving(null);
            setMessage(t('bolo.resolve.success'));
          }}
        />
      )}
    </div>
  );
}

export function PersonPage() {
  const { t } = useI18n();
  const { cid = '' } = useParams();
  const person = useMdtQuery('getPerson', { citizenid: cid });
  return (
    <QueryView query={person} notFound={t('person.notFound')}>
      {(data) => <PersonView key={data.person.citizenid} data={data} />}
    </QueryView>
  );
}
