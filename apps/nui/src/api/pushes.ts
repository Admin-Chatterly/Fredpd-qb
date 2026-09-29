// SPDX-License-Identifier: GPL-3.0-only
// Pushes whose payload IS the new state (docs/contracts.md §C13): topic `alerts` (AlertPush) and `units`
// (UnitsPush). TabletContext calls applyPushToCache for every push; the payload is written into the cached answers
// (every cached listAlerts page, getUnits), so no push ever triggers a listAlerts/getUnits call. A payload that does
// not match the contract is logged and only marks those queries stale (no fetch now; the next mount or tablet open
// refetches them), so even a stream of bad pushes cannot cause a fetch storm.
import type { QueryClient } from '@tanstack/react-query';
import { applyAlertChange, changeFromPush, parseAlertPush, parseUnitsPush } from '../alerts';
import type { AlertChange, AlertFilter, AlertPage } from '../alerts';
import { MDT_QUERY_ROOT, mdtQueryKey } from './client';

const listAlertsPrefix = [MDT_QUERY_ROOT, 'listAlerts'] as const;

/** Applies one alert change to every cached listAlerts page (each with its own filter). */
export function applyAlertChangeToCache(queryClient: QueryClient, change: AlertChange, citizenid: string): void {
  for (const query of queryClient.getQueryCache().findAll({ queryKey: listAlertsPrefix })) {
    const input = query.queryKey[2] as { filter?: AlertFilter } | undefined;
    const filter: AlertFilter = input?.filter ?? 'open';
    const data = query.state.data as AlertPage | undefined;
    if (!data) continue;
    const next = applyAlertChange(data, change, filter, citizenid);
    if (next !== data) queryClient.setQueryData(query.queryKey, next);
  }
}

function stale(queryClient: QueryClient, queryKey: readonly unknown[], topic: string, payload: unknown): void {
  console.warn(`[fredpd] push ${topic}: payload does not match packages/types/src/dispatch.ts`, payload);
  void queryClient.invalidateQueries({ queryKey, refetchType: 'none' });
}

/** True when the topic was handled here (alerts/units). */
export function applyPushToCache(queryClient: QueryClient, topic: string, payload: unknown, citizenid: string | null): boolean {
  if (topic === 'alerts') {
    const push = parseAlertPush(payload);
    if (push && citizenid) applyAlertChangeToCache(queryClient, changeFromPush(push), citizenid);
    else stale(queryClient, listAlertsPrefix, topic, payload);
    return true;
  }
  if (topic === 'units') {
    const units = parseUnitsPush(payload);
    if (units) queryClient.setQueryData(mdtQueryKey('getUnits', {}), units);
    else stale(queryClient, mdtQueryKey('getUnits', {}), topic, payload);
    return true;
  }
  return false;
}
