// SPDX-License-Identifier: GPL-3.0-only
// Efterlysningar (/efterlysning, task 2.6 UI): listBolos (active, or all incl. resolved/expired), 50 per page,
// "Ny efterlysning" (perm bolo.create) and resolve with a note (perm bolo.resolve). The perms only shape the UI;
// fredpd_mdt checks them on every call. A push on topic `bolo` refetches the list.
import { useState } from 'react';
import { Link } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { Bolo } from '@fredpd/types/mdt';
import { Badge, Button, Card, EmptyState, IconPlus, PageHeader, Pagination, Table, cn, useI18n } from '@fredpd/ui';
import type { TableColumn } from '@fredpd/ui';
import { useMdtQuery } from '../api/hooks';
import { BOLO_STATUS_KEYS, boloStatus, boloSubjectPath } from '../bolo';
import { BoloCreateDialog, BoloResolveDialog } from '../components/Bolos';
import { Callout, QueryView } from '../components/Common';
import { fmtDateTime, officerLabel } from '../format';
import { PERMS, usePerm } from '../perms';
import { useSession } from '../tablet/TabletContext';

export function BolosPage() {
  const i18n = useI18n();
  const { t } = i18n;
  const { grants } = useSession();
  const canCreate = usePerm(PERMS.boloCreate);
  const canResolve = usePerm(PERMS.boloResolve);
  const [active, setActive] = useState(true);
  const [page, setPage] = useState(1);
  const [creating, setCreating] = useState(false);
  const [resolving, setResolving] = useState<Bolo | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const list = useMdtQuery('listBolos', { active, page }, { keepPrevious: true });

  const columns: TableColumn<Bolo>[] = [
    { id: 'kind', header: t('bolo.field.kind'), cell: (b) => t(b.kind === 'person' ? 'bolo.kind.person' : 'bolo.kind.vehicle'), className: 'whitespace-nowrap text-muted' },
    {
      id: 'subject',
      header: i18n.tx('bolo.field.subject'),
      cell: (b) => {
        const path = boloSubjectPath(b);
        return path ? (
          <Link to={path} className="font-medium text-accent-text hover:underline">
            {b.subject}
          </Link>
        ) : (
          <span className="font-medium">{b.subject}</span>
        );
      },
    },
    { id: 'reason', header: t('bolo.field.reason'), cell: (b) => <span className="line-clamp-2">{b.reason}</span> },
    { id: 'level', header: t('bolo.field.level'), cell: (b) => <Badge level={b.level} /> },
    { id: 'issuedBy', header: t('bolo.field.issuedBy'), cell: (b) => (b.issuedBy ? officerLabel(b.issuedBy) : null), className: 'whitespace-nowrap' },
    { id: 'createdAt', header: t('common.createdAt'), cell: (b) => fmtDateTime(i18n, b.createdAt), className: 'whitespace-nowrap text-muted' },
    { id: 'expiresAt', header: t('bolo.field.expiresAt'), cell: (b) => (b.expiresAt ? fmtDateTime(i18n, b.expiresAt) : null), className: 'whitespace-nowrap text-muted' },
    {
      id: 'status',
      header: t('common.status'),
      cell: (b) => {
        const status = boloStatus(b);
        return <Badge tone={status === 'active' ? 'danger' : 'neutral'}>{t(BOLO_STATUS_KEYS[status])}</Badge>;
      },
    },
    {
      id: 'actions',
      header: <span className="sr-only">{t('common.actions')}</span>,
      cell: (b) =>
        canResolve && b.active ? (
          <Button size="sm" variant="ghost" onClick={() => setResolving(b)}>
            {t('bolo.resolve.button')}
          </Button>
        ) : null,
      className: 'text-right',
    },
  ];

  const filter = (value: boolean, label: string) => (
    <button
      type="button"
      role="tab"
      aria-selected={active === value}
      onClick={() => {
        setActive(value);
        setPage(1);
      }}
      className={cn('h-8 rounded-md px-3 text-sm', active === value ? 'bg-accent-soft text-accent-text' : 'text-muted hover:bg-raised hover:text-fg')}
    >
      {label}
    </button>
  );

  return (
    <>
      <PageHeader
        title={t('bolo.title')}
        actions={
          canCreate && (
            <Button variant="primary" icon={<IconPlus size={16} />} onClick={() => setCreating(true)}>
              {t('bolo.create.title')}
            </Button>
          )
        }
      />
      {message && (
        <Callout tone="success" className="mb-4">
          {message}
        </Callout>
      )}
      <div role="tablist" aria-label={t('common.filter')} className="mb-3 flex gap-1">
        {filter(true, t('bolo.filter.active'))}
        {filter(false, t('bolo.filter.all'))}
      </div>
      <Card padded={false}>
        <QueryView query={list}>
          {(data) => (
            <>
              <Table columns={columns} rows={data.items} getRowKey={(b) => b.id} empty={<EmptyState title={t('bolo.none')} />} />
              <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
            </>
          )}
        </QueryView>
      </Card>
      {creating && (
        <BoloCreateDialog
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
    </>
  );
}
