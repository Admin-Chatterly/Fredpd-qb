// SPDX-License-Identifier: GPL-3.0-only
// Ledning (/ledning/*, mdt_page:command). Phase 2 has one sub-page, Surfplattor (/ledning/surfplattor, task 2.1):
// listTablets (50 per page) and revoke/unrevoke (setTabletRevoked), both needing perm tablets.manage (checked by
// fredpd_mdt; here it only decides what is shown). Revoking asks first; reinstating does not.
import { useState } from 'react';
import { Link, Route, Routes } from 'react-router';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { MdtOutput } from '@fredpd/types/mdt';
import { Badge, Button, Card, Dialog, EmptyState, IconKey, IconShield, PageHeader, Pagination, Table, useI18n } from '@fredpd/ui';
import type { TableColumn } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { useErrorText } from '../api/errors';
import { Callout, QueryView } from '../components/Common';
import { fmtDateTime, officerLabel } from '../format';
import { PERMS, usePerm } from '../perms';
import { personPath } from '../search';
import { NotFoundPage } from './PlaceholderPage';

type Tablet = MdtOutput<'listTablets'>['items'][number];

export function TabletsPage() {
  const i18n = useI18n();
  const { t } = i18n;
  const errorText = useErrorText();
  const canManage = usePerm(PERMS.tabletsManage);
  const [page, setPage] = useState(1);
  const [confirm, setConfirm] = useState<Tablet | null>(null);
  const [message, setMessage] = useState<{ tone: 'success' | 'danger'; text: string } | null>(null);
  const list = useMdtQuery('listTablets', { page }, { enabled: canManage, keepPrevious: true });
  const toggle = useMdtMutation('setTabletRevoked', {
    onSuccess: (tablet) => {
      setConfirm(null);
      setMessage({ tone: 'success', text: t(tablet.revoked ? 'tablet.revokedNotice' : 'tablet.reinstatedNotice', { serial: tablet.serial }) });
    },
    onError: (err) => {
      setConfirm(null);
      setMessage({ tone: 'danger', text: errorText(err) });
    },
  });

  if (!canManage) {
    return (
      <>
        <PageHeader title={t('tablet.title')} />
        <Card padded={false}>
          <EmptyState icon={<IconShield size={28} />} title={t('errors.unauthorized')} />
        </Card>
      </>
    );
  }

  const columns: TableColumn<Tablet>[] = [
    { id: 'serial', header: t('tablet.field.serial'), cell: (tab) => <span className="font-mono">{tab.serial}</span>, className: 'whitespace-nowrap' },
    {
      id: 'owner',
      header: t('tablet.field.owner'),
      cell: (tab) =>
        tab.owner ? (
          <Link to={personPath(tab.owner.citizenid)} className="text-accent-text hover:underline">
            {tab.owner.name}
          </Link>
        ) : null,
    },
    {
      id: 'status',
      header: t('common.status'),
      cell: (tab) => <Badge tone={tab.revoked ? 'danger' : 'success'}>{t(tab.revoked ? 'tablet.status.revoked' : 'tablet.status.active')}</Badge>,
    },
    { id: 'issuedBy', header: t('tablet.field.issuedBy'), cell: (tab) => (tab.issuedBy ? officerLabel(tab.issuedBy) : null) },
    { id: 'issuedAt', header: t('tablet.field.issuedAt'), cell: (tab) => fmtDateTime(i18n, tab.issuedAt), className: 'whitespace-nowrap text-muted' },
    {
      id: 'actions',
      header: <span className="sr-only">{t('common.actions')}</span>,
      className: 'text-right',
      cell: (tab) =>
        tab.revoked ? (
          <Button size="sm" variant="secondary" disabled={toggle.isPending} onClick={() => toggle.mutate({ serial: tab.serial, revoked: false })}>
            {t('tablet.reinstate')}
          </Button>
        ) : (
          <Button size="sm" variant="danger" disabled={toggle.isPending} onClick={() => setConfirm(tab)}>
            {t('tablet.revoke')}
          </Button>
        ),
    },
  ];

  return (
    <>
      <PageHeader title={t('tablet.title')} />
      {message && (
        <Callout tone={message.tone} className="mb-4">
          {message.text}
        </Callout>
      )}
      <Card padded={false}>
        <QueryView query={list}>
          {(data) => (
            <>
              <Table columns={columns} rows={data.items} getRowKey={(tab) => tab.serial} empty={<EmptyState title={t('tablet.none')} />} />
              <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
            </>
          )}
        </QueryView>
      </Card>
      {confirm && (
        <Dialog
          open
          title={t('tablet.revoke')}
          onClose={() => setConfirm(null)}
          footer={
            <>
              <Button variant="ghost" onClick={() => setConfirm(null)}>
                {t('common.cancel')}
              </Button>
              <Button variant="danger" loading={toggle.isPending} onClick={() => toggle.mutate({ serial: confirm.serial, revoked: true })}>
                {t('tablet.revoke')}
              </Button>
            </>
          }
        >
          <p className="text-sm text-fg">{t('tablet.revokeConfirm', { serial: confirm.serial })}</p>
        </Dialog>
      )}
    </>
  );
}

function CommandHome() {
  const { t } = useI18n();
  const canManage = usePerm(PERMS.tabletsManage);
  return (
    <>
      <PageHeader title={t('nav.command')} />
      {canManage ? (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <Link to="surfplattor" className="flex items-center gap-3 rounded-lg border border-line bg-surface px-4 py-3 hover:border-line-strong">
            <IconKey className="text-accent-text" />
            <span className="font-medium">{t('nav.tablets')}</span>
          </Link>
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
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
  );
}
