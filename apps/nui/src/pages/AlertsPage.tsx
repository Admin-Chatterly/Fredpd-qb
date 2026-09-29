// SPDX-License-Identifier: GPL-3.0-only
// Larm (/larm, task 3.2; docs/contracts.md §C13): listAlerts (Öppna / Mina / Alla, newest first, 50 per page) and the
// units panel (getUnits). Live without polling: pushes on topics `alerts` and `units` carry the new state and are
// written into the cached answers by TabletContext (src/api/pushes.ts), so this page re-renders from the cache and
// never refetches on a push. Take / leave / close answer the alert's new state, written into the cache the same way.
// Close is offered to officers on the alert and to holders of perm alerts.manage (the server decides).
import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { Alert, UnitStatus } from '@fredpd/types/dispatch';
import { Badge, Button, Card, EmptyState, PageHeader, Pagination, Tabs, useI18n } from '@fredpd/ui';
import { useMdtMutation, useMdtQuery } from '../api/hooks';
import { applyAlertChangeToCache } from '../api/pushes';
import { ALERT_FILTERS, ALERT_FILTER_KEYS, ALERT_STATUS_KEYS, PRIORITY_KEYS, PRIORITY_TONES, isOnAlert, sortUnits } from '../alerts';
import type { AlertFilter } from '../alerts';
import { QueryView } from '../components/Common';
import { MutationError } from '../components/Fields';
import { fmtDateTime, fmtTime, officerLabel, unitLabel } from '../format';
import { PERMS, usePerm } from '../perms';
import { useSession } from '../tablet/TabletContext';

/** "Tilldelad: IGV-07 · Anna Berg" (alert.assigned), or the name alone without a callsign. */
function useAssignedText() {
  const i18n = useI18n();
  return (unit: Alert['units'][number]) =>
    unit.callsign ? i18n.t('alert.assigned', { callsign: unit.callsign, name: unit.displayName }) : i18n.tx('alert.assignedNoCallsign', { name: unit.displayName });
}

function AlertRow({ alert, citizenid, canManage }: { alert: Alert; citizenid: string; canManage: boolean }) {
  const i18n = useI18n();
  const { t } = i18n;
  const queryClient = useQueryClient();
  const assignedText = useAssignedText();
  const onSuccess = (next: Alert) => applyAlertChangeToCache(queryClient, { type: 'upsert', alert: next }, citizenid);
  const take = useMdtMutation('takeAlert', { onSuccess });
  const leave = useMdtMutation('leaveAlert', { onSuccess });
  const close = useMdtMutation('closeAlert', { onSuccess });
  const mine = isOnAlert(alert, citizenid);
  const closed = alert.status === 'closed';
  const busy = take.isPending || leave.isPending || close.isPending;
  const error = take.error ?? leave.error ?? close.error;

  return (
    <li data-alert-id={alert.id} data-status={alert.status} className="flex flex-col gap-1.5 px-4 py-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={PRIORITY_TONES[alert.priority]}>{t(PRIORITY_KEYS[alert.priority])}</Badge>
        <span className="font-mono text-sm text-muted">{alert.code}</span>
        <span className="min-w-0 flex-1 truncate font-medium text-fg">{alert.title}</span>
        <Badge tone={closed ? 'neutral' : alert.status === 'assigned' ? 'accent' : 'warning'}>{t(ALERT_STATUS_KEYS[alert.status])}</Badge>
        <time dateTime={alert.createdAt} title={fmtDateTime(i18n, alert.createdAt)} className="text-sm text-muted">
          {fmtTime(alert.createdAt)}
        </time>
      </div>
      {alert.street && <p className="text-sm text-fg">{alert.street}</p>}
      {alert.description && <p className="text-sm whitespace-pre-line text-muted">{alert.description}</p>}
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        {alert.units.length === 0 ? (
          <span className="text-muted">{t('alert.unassigned')}</span>
        ) : (
          alert.units.map((u) => (
            <span key={u.citizenid} data-assigned={u.citizenid} className="text-fg">
              {assignedText(u)}
            </span>
          ))
        )}
        {alert.closedBy && <span className="text-muted">{t('alert.closedBy', { name: officerLabel(alert.closedBy) })}</span>}
        <span className="flex-1" />
        {!closed && !mine && (
          <Button size="sm" variant="primary" loading={take.isPending} disabled={busy} onClick={() => take.mutate({ id: alert.id })}>
            {t('alert.action.take')}
          </Button>
        )}
        {!closed && mine && (
          <Button size="sm" loading={leave.isPending} disabled={busy} onClick={() => leave.mutate({ id: alert.id })}>
            {t('alert.action.leave')}
          </Button>
        )}
        {!closed && (mine || canManage) && (
          <Button size="sm" variant="danger" loading={close.isPending} disabled={busy} onClick={() => close.mutate({ id: alert.id })}>
            {t('alert.action.close')}
          </Button>
        )}
      </div>
      <MutationError error={error} />
    </li>
  );
}

function UnitsPanel({ units }: { units: readonly UnitStatus[] }) {
  const i18n = useI18n();
  const { t, tx } = i18n;
  const shown = sortUnits(units);
  if (shown.length === 0) return <EmptyState title={t('officer.none')} />;
  return (
    <ul className="flex flex-col divide-y divide-line" aria-label={t('home.unitsOnDuty')}>
      {shown.map((u) => (
        <li key={u.citizenid} data-unit={u.citizenid} className="flex items-center gap-2 px-4 py-2 text-sm">
          <span className="min-w-0 flex-1 truncate text-fg">{officerLabel(u)}</span>
          {u.unit && <span className="text-xs text-muted">{unitLabel(i18n, u.unit)}</span>}
          <Badge tone={u.alertId === null ? 'success' : 'accent'}>{u.alertId === null ? tx('alert.unit.free') : tx('alert.unit.busy')}</Badge>
        </li>
      ))}
    </ul>
  );
}

export function AlertsPage() {
  const { t } = useI18n();
  const { me } = useSession();
  const canManage = usePerm(PERMS.alertsManage);
  const [filter, setFilter] = useState<AlertFilter>('open');
  const [page, setPage] = useState(1);
  const list = useMdtQuery('listAlerts', { filter, page }, { keepPrevious: true });
  const units = useMdtQuery('getUnits', {});

  return (
    <>
      <PageHeader title={t('alert.title')} />
      <Tabs
        className="mb-3"
        label={t('common.filter')}
        value={filter}
        onChange={(f) => {
          setFilter(f);
          setPage(1);
        }}
        items={ALERT_FILTERS.map((f) => ({ id: f, label: t(ALERT_FILTER_KEYS[f]) }))}
      />
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <Card padded={false}>
          <QueryView query={list}>
            {(data) =>
              data.items.length === 0 ? (
                <EmptyState title={filter === 'open' ? t('alert.noOpen') : t('common.empty')} />
              ) : (
                <>
                  <ul className="flex flex-col divide-y divide-line">
                    {data.items.map((alert) => (
                      <AlertRow key={alert.id} alert={alert} citizenid={me.citizenid} canManage={canManage} />
                    ))}
                  </ul>
                  <Pagination page={data.page} total={data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
                </>
              )
            }
          </QueryView>
        </Card>
        <Card title={t('home.unitsOnDuty')} padded={false}>
          <QueryView query={units}>{(data) => <UnitsPanel units={data.units} />}</QueryView>
        </Card>
      </div>
    </>
  );
}
