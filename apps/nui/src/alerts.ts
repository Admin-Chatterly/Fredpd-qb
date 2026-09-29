// SPDX-License-Identifier: GPL-3.0-only
// Larm (alerts) logic shared by the Larm page and the push handler (docs/contracts.md §C13). A push or a
// take/leave/close answer carries the alert's new state, so the cached listAlerts pages are edited in place
// (applyAlertChange) instead of refetched: a shooting that fires ten alerts in a second costs ten cache edits and
// zero listAlerts calls.
import { PAGE_SIZE } from '@fredpd/types/mdt';
import { ALERT_PRIORITY_LOCALE_KEYS, AlertPushSchema, UnitsPushSchema } from '@fredpd/types/dispatch';
import type { Alert, AlertPriority, AlertPush, UnitStatus } from '@fredpd/types/dispatch';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { normalizeWire } from './api/wire';

export type AlertFilter = 'open' | 'mine' | 'all';
export const ALERT_FILTERS: readonly AlertFilter[] = ['open', 'mine', 'all'];

export const ALERT_FILTER_KEYS: Readonly<Record<AlertFilter, LocaleKey>> = {
  open: 'alert.filter.open',
  mine: 'alert.filter.mine',
  all: 'alert.filter.all',
};

export const ALERT_STATUS_KEYS: Readonly<Record<Alert['status'], LocaleKey>> = {
  open: 'alert.status.open',
  assigned: 'alert.status.assigned',
  closed: 'alert.status.closed',
};

export const PRIORITY_KEYS: Readonly<Record<AlertPriority, LocaleKey>> = ALERT_PRIORITY_LOCALE_KEYS;
export const PRIORITY_TONES = { 1: 'danger', 2: 'warning', 3: 'neutral' } as const satisfies Record<AlertPriority, string>;

export interface AlertPage {
  items: Alert[];
  total: number;
  page: number;
}

export const isOnAlert = (alert: Alert, citizenid: string) => alert.units.some((u) => u.citizenid === citizenid);

/** Whether an alert belongs in a list filter (fredpd_dispatch alert_store.list: open = open + assigned). */
export function matchesFilter(alert: Alert, filter: AlertFilter, citizenid: string): boolean {
  switch (filter) {
    case 'open':
      return alert.status !== 'closed';
    case 'mine':
      return alert.status !== 'closed' && isOnAlert(alert, citizenid);
    case 'all':
      return true;
  }
}

/** A change to apply: the alert's new state, or "closed" with only its id (the push of a close carries no alert). */
export type AlertChange = { type: 'upsert'; alert: Alert } | { type: 'closed'; id: number };

export function changeFromPush(push: AlertPush): AlertChange {
  return push.type === 'closed' ? { type: 'closed', id: push.id } : { type: 'upsert', alert: push.alert };
}

/**
 * One cached page after a change. Newest first, as listAlerts answers: a new matching alert is put at the top of
 * page 1 (the list is capped at PAGE_SIZE; later pages only edit rows they hold); a row that stops matching is
 * removed; `total` follows. Returns the same object when nothing changed.
 */
export function applyAlertChange(page: AlertPage, change: AlertChange, filter: AlertFilter, citizenid: string): AlertPage {
  const id = change.type === 'upsert' ? change.alert.id : change.id;
  const index = page.items.findIndex((a) => a.id === id);
  if (change.type === 'closed') {
    if (index < 0) return page;
    if (filter === 'all') {
      const items = page.items.slice();
      items[index] = { ...items[index]!, status: 'closed' };
      return { ...page, items };
    }
    return { ...page, items: page.items.filter((a) => a.id !== id), total: Math.max(0, page.total - 1) };
  }
  const matches = matchesFilter(change.alert, filter, citizenid);
  if (index >= 0) {
    if (!matches) return { ...page, items: page.items.filter((a) => a.id !== id), total: Math.max(0, page.total - 1) };
    const items = page.items.slice();
    items[index] = change.alert;
    return { ...page, items };
  }
  if (!matches || page.page !== 1) return page;
  return { ...page, items: [change.alert, ...page.items].slice(0, PAGE_SIZE), total: page.total + 1 };
}

/**
 * Reads a push payload as Lua sends it (absent nulls restored first, docs/modules/dispatch.md). Null when it does not
 * match the contract.
 */
export function parseAlertPush(payload: unknown): AlertPush | null {
  const parsed = AlertPushSchema.safeParse(normalizeWire(AlertPushSchema, payload));
  return parsed.success ? parsed.data : null;
}

export function parseUnitsPush(payload: unknown): { units: UnitStatus[] } | null {
  const parsed = UnitsPushSchema.safeParse(normalizeWire(UnitsPushSchema, payload));
  return parsed.success ? parsed.data : null;
}

/** Units panel order: on-duty officers only, those on an alert first, then by callsign and name. */
export function sortUnits(units: readonly UnitStatus[]): UnitStatus[] {
  return units
    .filter((u) => u.onDuty)
    .slice()
    .sort((a, b) => Number(b.alertId !== null) - Number(a.alertId !== null) || (a.callsign ?? '~').localeCompare(b.callsign ?? '~', 'sv') || a.displayName.localeCompare(b.displayName, 'sv'));
}
