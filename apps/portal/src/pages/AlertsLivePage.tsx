// SPDX-License-Identifier: GPL-3.0-only
// Larm in the portal: read-only and live (IMPLEMENTATION.md §5.5 "Portal"; docs/modules/service.md "Portal alerts").
// GET /api/alerts?filter=open|all&page=n (50 per page, page count from `total`, pages may be short) and GET /api/units
// once, then /ws: alertCreated / alertAssigned are written into the cached pages (the tablet's applyAlertChange),
// alertClosed removes, unitsChanged replaces the roster. No polling: the socket is event driven and is reopened
// only after it closes (backoff with one setTimeout per close), never after 4401 (session ended: the login page says
// so), 4429 (another tab took over) or a socket that never opened (a refused upgrade, e.g. no live grant: the user
// can retry by hand). After a reconnect the lists are refetched once to catch up.
// Take / leave / close are tablet actions (waypoint, unit status) and are not shown here.
import { useCallback, useEffect, useRef, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { QueryClient } from '@tanstack/react-query';
import { AlertListOutputSchema, DispatchInternalEventSchema, UnitsPushSchema } from '@fredpd/types/dispatch';
import type { UnitStatus } from '@fredpd/types/dispatch';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import { Badge, Button, Card, EmptyState, PageHeader, Pagination, Spinner, Tabs, useI18n } from '@fredpd/ui';
import { ALERT_FILTER_KEYS, AlertRow, UnitsPanel, applyAlertChange } from '../mdt/shared-pages';
import type { AlertChange, AlertPage } from '../mdt/shared-pages';
import { ApiRequestError, apiFetch, errorLocaleKey } from '../api';
import { fmtTime, useMdtSession } from '../mdt/shared';
import { SESSION_QUERY_KEY } from '../session';
import type { PortalSession } from '../session';
import { NotFoundPage } from './NotFoundPage';

export type PortalAlertFilter = 'open' | 'all';
const FILTERS: readonly PortalAlertFilter[] = ['open', 'all'];

export const PORTAL_ALERTS_KEY = 'portalAlerts';
export const PORTAL_UNITS_KEY = ['portalUnits'] as const;

interface UnitsSnapshot {
  units: UnitStatus[];
  /** When FXServer posted this roster (x-fredpd-units-received-at, or the /ws event time); null = none yet. */
  receivedAt: string | null;
}

async function fetchUnits(): Promise<UnitsSnapshot> {
  let response: Response;
  try {
    response = await fetch('/api/units', { headers: { accept: 'application/json' }, credentials: 'same-origin' });
  } catch {
    throw new ApiRequestError(0, 'network');
  }
  const text = await response.text();
  if (!response.ok) {
    let code = 'internal';
    try {
      const body = JSON.parse(text) as { error?: unknown };
      if (typeof body.error === 'string') code = body.error;
    } catch {
      // not JSON
    }
    throw new ApiRequestError(response.status, code);
  }
  return { units: UnitsPushSchema.parse(JSON.parse(text)).units, receivedAt: response.headers.get('x-fredpd-units-received-at') };
}

/** Applies one /ws message to the cache. Returns false for a message that is not an alert/unit event. */
export function applyLiveEvent(queryClient: QueryClient, message: unknown, citizenid: string, now: () => string = () => new Date().toISOString()): boolean {
  const parsed = DispatchInternalEventSchema.safeParse(message);
  if (!parsed.success) return false;
  const event = parsed.data;
  if (event.type === 'unitsChanged') {
    queryClient.setQueryData<UnitsSnapshot>(PORTAL_UNITS_KEY, { units: event.payload.units, receivedAt: now() });
    return true;
  }
  const change: AlertChange = event.type === 'alertClosed' ? { type: 'closed', id: event.payload.id } : { type: 'upsert', alert: event.payload };
  for (const [key, page] of queryClient.getQueriesData<AlertPage>({ queryKey: [PORTAL_ALERTS_KEY] })) {
    if (!page) continue;
    const filter = key[1] as PortalAlertFilter;
    const next = applyAlertChange(page, change, filter, citizenid);
    if (next !== page) queryClient.setQueryData(key, next);
  }
  return true;
}

export type LiveState = 'connecting' | 'live' | 'reconnecting' | 'offline' | 'otherTab';

const MAX_BACKOFF_MS = 30_000;

/** The /ws subscription for the page's lifetime. */
function useLiveAlerts(citizenid: string): { state: LiveState; retry: () => void } {
  const queryClient = useQueryClient();
  const [state, setState] = useState<LiveState>('connecting');
  const [attempt, setAttempt] = useState(0);
  const failures = useRef(0);

  const retry = useCallback(() => {
    failures.current = 0;
    setState('connecting');
    setAttempt((a) => a + 1);
  }, []);

  useEffect(() => {
    let socket: WebSocket | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let disposed = false;
    const url = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`;

    const open = (isReconnect: boolean) => {
      let opened = false;
      socket = new WebSocket(url);
      socket.onopen = () => {
        opened = true;
        failures.current = 0;
        setState('live');
        // Events missed while the socket was down: one refetch of the lists (never on a timer).
        if (isReconnect) {
          void queryClient.invalidateQueries({ queryKey: [PORTAL_ALERTS_KEY] });
          void queryClient.invalidateQueries({ queryKey: PORTAL_UNITS_KEY });
        }
      };
      socket.onmessage = (event: MessageEvent) => {
        try {
          applyLiveEvent(queryClient, JSON.parse(String(event.data)), citizenid);
        } catch {
          // Not JSON: ignored.
        }
      };
      socket.onclose = (event: CloseEvent) => {
        if (disposed) return;
        if (event.code === 4401) {
          queryClient.setQueryData<PortalSession>(SESSION_QUERY_KEY, { user: null, csrfToken: null, expired: true });
          return;
        }
        if (event.code === 4429) {
          setState('otherTab');
          return;
        }
        if (!opened) {
          // Refused upgrade (403/401) or no route: do not hammer it; the user can retry.
          setState('offline');
          return;
        }
        setState('reconnecting');
        const delay = Math.min(MAX_BACKOFF_MS, 1000 * 2 ** failures.current);
        failures.current += 1;
        timer = setTimeout(() => open(true), delay);
      };
    };

    open(attempt > 0);
    return () => {
      disposed = true;
      if (timer) clearTimeout(timer);
      socket?.close(1000);
    };
  }, [attempt, citizenid, queryClient]);

  return { state, retry };
}

const LIVE_TONES = { connecting: 'neutral', live: 'success', reconnecting: 'warning', offline: 'neutral', otherTab: 'neutral' } as const;

function LiveBadge({ state, onRetry }: { state: LiveState; onRetry: () => void }) {
  const { t, tx } = useI18n();
  const text =
    state === 'live'
      ? t('portal.live.connected')
      : state === 'reconnecting'
        ? t('portal.live.reconnecting')
        : state === 'otherTab'
          ? tx('portal.live.otherTab')
          : state === 'offline'
            ? tx('portal.live.offline')
            : t('common.loading');
  return (
    <span className="flex items-center gap-2" data-live={state}>
      <Badge tone={LIVE_TONES[state]}>{text}</Badge>
      {(state === 'offline' || state === 'otherTab') && (
        <Button size="sm" variant="ghost" onClick={onRetry}>
          {t('common.retry')}
        </Button>
      )}
    </span>
  );
}

export function AlertsLivePage() {
  const { t, tx } = useI18n();
  const { me } = useMdtSession();
  const [filter, setFilter] = useState<PortalAlertFilter>('open');
  const [page, setPage] = useState(1);
  const list = useQuery({
    queryKey: [PORTAL_ALERTS_KEY, filter, page],
    queryFn: () => apiFetch(`/api/alerts?filter=${filter}&page=${page}`, { schema: AlertListOutputSchema }),
    placeholderData: (prev) => prev,
  });
  const units = useQuery({ queryKey: PORTAL_UNITS_KEY, queryFn: fetchUnits, staleTime: Infinity });
  const live = useLiveAlerts(me.citizenid);

  if (list.error instanceof ApiRequestError && list.error.status === 403) return <NotFoundPage />;

  return (
    <>
      <PageHeader title={t('alert.title')} actions={<LiveBadge state={live.state} onRetry={live.retry} />} />
      <Tabs
        className="mb-3"
        label={t('common.filter')}
        value={filter}
        onChange={(f) => {
          setFilter(f);
          setPage(1);
        }}
        items={FILTERS.map((f) => ({ id: f, label: t(ALERT_FILTER_KEYS[f]) }))}
      />
      <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <Card padded={false}>
          {list.isPending ? (
            <div className="flex justify-center py-10">
              <Spinner size="lg" />
            </div>
          ) : list.isError ? (
            <EmptyState title={t(errorLocaleKey(list.error))} />
          ) : list.data.items.length === 0 ? (
            <EmptyState title={filter === 'open' ? t('alert.noOpen') : t('common.empty')} />
          ) : (
            <>
              <ul className="flex flex-col divide-y divide-line" data-portal-alerts>
                {list.data.items.map((alert) => (
                  <AlertRow key={alert.id} alert={alert} citizenid={me.citizenid} canManage={false} />
                ))}
              </ul>
              <Pagination page={list.data.page} total={list.data.total} pageSize={PAGE_SIZE} disabled={list.isFetching} onPageChange={setPage} />
            </>
          )}
        </Card>
        <Card title={t('home.unitsOnDuty')} padded={false}>
          {units.isSuccess ? (
            <>
              <UnitsPanel units={units.data.units} />
              {units.data.receivedAt && (
                <p className="border-t border-line px-4 py-2 text-xs text-muted" data-units-age>
                  {tx('portal.live.unitsAge', { time: fmtTime(units.data.receivedAt) })}
                </p>
              )}
            </>
          ) : units.isError ? (
            <EmptyState title={t(errorLocaleKey(units.error))} />
          ) : (
            <div className="flex justify-center py-6">
              <Spinner />
            </div>
          )}
        </Card>
      </div>
    </>
  );
}
