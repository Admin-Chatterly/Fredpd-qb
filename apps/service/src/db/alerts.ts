// SPDX-License-Identifier: GPL-3.0-only
// Read-only access to fredpd_alerts / fredpd_alert_units for the portal's alert list (GET /api/alerts,
// docs/contracts.md §C13). fredpd_dispatch owns every write to these tables; the service never writes them, so
// there is nothing to audit here. The mapping follows fredpd_dispatch's single loader (server/alert_store.lua):
//  - newest first (id DESC), PAGE_SIZE (50) per page; 'open' = open + assigned, 'all' = every alert;
//  - units in the order they took the alert (created_at, citizenid); an officer's current fredpd_officers callsign
//    wins over the snapshot taken with the alert; the name is the Discord display name (§4.9), else the callsign,
//    else the citizenid (never a character name);
//  - coords that are not three finite numbers are "no position"; a priority outside 1–3 reads as 2 (normal).
// Times (§C7): drizzle reads DATETIME text as UTC; they leave as ISO-8601 `YYYY-MM-DDTHH:mm:ssZ`.
import { asc, desc, inArray, sql } from 'drizzle-orm';
import type { SQL } from 'drizzle-orm';
import { alias } from 'drizzle-orm/mysql-core';
import { AlertSchema } from '@fredpd/types/dispatch';
import type { Alert, AlertPriority, AlertStatus } from '@fredpd/types/dispatch';
import { OfficerRefSchema, PAGE_SIZE } from '@fredpd/types/mdt';
import type { OfficerRef } from '@fredpd/types/mdt';
import type { DbOrTx } from './repo';
import { alertUnits, alerts, officers } from './schema';

export type AlertListFilter = 'open' | 'all';

export interface AlertList {
  items: Alert[];
  total: number;
  page: number;
}

/** ISO-8601 UTC without milliseconds (DATETIME has none), the format fredpd_core's Time.toIsoUtc produces. */
export function toIsoUtc(d: Date | null | undefined): string | null {
  if (!d || Number.isNaN(d.getTime())) return null;
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/**
 * At most `max` UTF-16 code units (zod's .max() counts those, a VARCHAR counts characters), without leaving half
 * of a surrogate pair at the end.
 */
export function cap(value: string, max: number): string {
  if (value.length <= max) return value;
  let out = value.slice(0, max);
  const last = out.charCodeAt(out.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) out = out.slice(0, -1);
  return out;
}

function coordsOf(v: unknown): Alert['coords'] {
  if (typeof v !== 'object' || v === null) return null;
  const { x, y, z } = v as Record<string, unknown>;
  const n = [x, y, z].map((c) => (typeof c === 'number' ? c : typeof c === 'string' && c.trim() !== '' ? Number(c) : NaN));
  if (!n.every((c) => Number.isFinite(c))) return null;
  return { x: n[0]!, y: n[1]!, z: n[2]! };
}

function priorityOf(v: unknown): AlertPriority {
  const n = Number(v);
  return n === 1 || n === 2 || n === 3 ? n : 2;
}

/** OfficerRef, or null when the citizenid is not one fredpd_core could have stored (it is then left out). */
export function officerRef(citizenid: string | null, displayName: string | null, callsign: string | null, unit: string | null): OfficerRef | null {
  if (!citizenid) return null;
  const ref = { citizenid, displayName: displayName || callsign || citizenid, callsign: callsign || null, unit: unit || null };
  const parsed = OfficerRefSchema.safeParse(ref);
  return parsed.success ? parsed.data : null;
}

/** One fredpd_alerts row (with the closing officer joined) as the service reads it. */
export interface AlertRow {
  id: number;
  code: string;
  title: string;
  description: string | null;
  coords: unknown;
  street: string | null;
  priority: number;
  source: string;
  status: AlertStatus;
  closedBy: string | null;
  closedAt: Date | null;
  createdAt: Date;
  closedByName: string | null;
  closedByCallsign: string | null;
  closedByUnit: string | null;
}

export interface AlertUnitRow {
  alertId: number;
  citizenid: string;
  snapCallsign: string | null;
  displayName: string | null;
  callsign: string | null;
  unit: string | null;
}

/** Alert (AlertSchema) from a row and its unit rows (already in take order). Null when it cannot be made valid. */
export function rowToAlert(row: AlertRow, units: readonly AlertUnitRow[]): Alert | null {
  const refs: OfficerRef[] = [];
  for (const u of units) {
    const ref = officerRef(u.citizenid, u.displayName, u.callsign ?? u.snapCallsign, u.unit);
    if (ref) refs.push(ref);
  }
  const alert = {
    id: row.id,
    code: cap(row.code, 16),
    title: cap(row.title, 160),
    description: row.description === null ? null : cap(row.description, 1000),
    coords: coordsOf(row.coords),
    street: row.street === null ? null : cap(row.street, 128),
    priority: priorityOf(row.priority),
    source: cap(row.source, 32),
    status: row.status,
    createdAt: toIsoUtc(row.createdAt),
    units: refs,
    closedBy: row.closedBy === null ? null : officerRef(row.closedBy, row.closedByName, row.closedByCallsign, row.closedByUnit),
    closedAt: toIsoUtc(row.closedAt),
  };
  const parsed = AlertSchema.safeParse(alert);
  return parsed.success ? parsed.data : null;
}

const closer = alias(officers, 'co');
const unitOfficer = alias(officers, 'o');

/**
 * One page of alerts, newest first. Rows that cannot be turned into a valid Alert (hand-edited data) are left out
 * of `items` and reported through `onInvalid`; `total` still counts them, like the tablet's list.
 */
export async function listAlerts(
  db: DbOrTx,
  filter: AlertListFilter,
  page: number,
  onInvalid?: (id: number) => void,
): Promise<AlertList> {
  const where: SQL | undefined = filter === 'open' ? inArray(alerts.status, ['open', 'assigned']) : undefined;
  const [countRow] = await db.select({ n: sql<number>`COUNT(*)` }).from(alerts).where(where);
  const total = Number(countRow?.n ?? 0);

  const rows: AlertRow[] = await db
    .select({
      id: alerts.id,
      code: alerts.code,
      title: alerts.title,
      description: alerts.description,
      coords: alerts.coords,
      street: alerts.street,
      priority: alerts.priority,
      source: alerts.source,
      status: alerts.status,
      closedBy: alerts.closedBy,
      closedAt: alerts.closedAt,
      createdAt: alerts.createdAt,
      closedByName: closer.displayName,
      closedByCallsign: closer.callsign,
      closedByUnit: closer.unit,
    })
    .from(alerts)
    .leftJoin(closer, sql`${closer.citizenid} = ${alerts.closedBy}`)
    .where(where)
    .orderBy(desc(alerts.id))
    .limit(PAGE_SIZE)
    .offset((page - 1) * PAGE_SIZE);
  if (rows.length === 0) return { items: [], total, page };

  const unitRows: AlertUnitRow[] = await db
    .select({
      alertId: alertUnits.alertId,
      citizenid: alertUnits.citizenid,
      snapCallsign: alertUnits.callsign,
      displayName: unitOfficer.displayName,
      callsign: unitOfficer.callsign,
      unit: unitOfficer.unit,
    })
    .from(alertUnits)
    .leftJoin(unitOfficer, sql`${unitOfficer.citizenid} = ${alertUnits.citizenid}`)
    .where(inArray(alertUnits.alertId, rows.map((r) => r.id)))
    .orderBy(asc(alertUnits.createdAt), asc(alertUnits.citizenid));

  const byAlert = new Map<number, AlertUnitRow[]>();
  for (const u of unitRows) {
    const list = byAlert.get(u.alertId) ?? [];
    list.push(u);
    byAlert.set(u.alertId, list);
  }
  const items: Alert[] = [];
  for (const row of rows) {
    const alert = rowToAlert(row, byAlert.get(row.id) ?? []);
    if (alert) items.push(alert);
    else onInvalid?.(row.id);
  }
  return { items, total, page };
}
