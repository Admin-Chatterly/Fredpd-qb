// SPDX-License-Identifier: GPL-3.0-only
// Alerts (larm) contract, Phase 3 (docs/contracts.md §C13). Tablet actions extend MDT_ACTIONS via DISPATCH_ACTIONS;
// the same Alert shape travels over the tablet push topic 'alerts', the service's /internal/events and /ws.
import { z } from 'zod';
import { IsoUtcSchema, OfficerRefSchema, PageSchema } from './mdt';

export const AlertPrioritySchema = z.union([z.literal(1), z.literal(2), z.literal(3)]); // 1 = hög, 2 = normal, 3 = låg
export type AlertPriority = z.infer<typeof AlertPrioritySchema>;
export const ALERT_PRIORITY_LOCALE_KEYS = { 1: 'alert.priority.high', 2: 'alert.priority.normal', 3: 'alert.priority.low' } as const;

export const AlertStatusSchema = z.enum(['open', 'assigned', 'closed']);
export type AlertStatus = z.infer<typeof AlertStatusSchema>;

export const CoordsSchema = z.object({ x: z.number().finite(), y: z.number().finite(), z: z.number().finite() });

export const AlertSchema = z.object({
  id: z.number().int().positive(),
  code: z.string().max(16),
  title: z.string().max(160),
  description: z.string().max(1000).nullable(),
  coords: CoordsSchema.nullable(),
  street: z.string().max(128).nullable(),
  priority: AlertPrioritySchema,
  /** Generator: 'ps-dispatch', 'bolo', 'devtools', … */
  source: z.string().max(32),
  status: AlertStatusSchema,
  createdAt: IsoUtcSchema,
  units: z.array(OfficerRefSchema),
  closedBy: OfficerRefSchema.nullable(),
  closedAt: IsoUtcSchema.nullable(),
});
export type Alert = z.infer<typeof AlertSchema>;

/** Toast payload (lib.notify on every on-duty officer, tablet open or not) — deliberately small. */
export const AlertToastSchema = AlertSchema.pick({ id: true, code: true, title: true, street: true, priority: true });
export type AlertToast = z.infer<typeof AlertToastSchema>;

/** Input of the server export `createAlert(data)` and of the ps-dispatch bridge after normalisation. */
export const AlertCreateInputSchema = z.object({
  code: z.string().trim().min(1).max(16),
  title: z.string().trim().min(1).max(160),
  description: z.string().trim().max(1000).optional(),
  coords: CoordsSchema.optional(),
  street: z.string().trim().max(128).optional(),
  priority: AlertPrioritySchema.default(2),
  source: z.string().trim().min(1).max(32),
  meta: z.record(z.string(), z.unknown()).optional(),
});
export type AlertCreateInput = z.infer<typeof AlertCreateInputSchema>;

export const UnitStatusSchema = OfficerRefSchema.extend({
  onDuty: z.boolean(),
  /** Alert the officer is assigned to (newest), null when free. */
  alertId: z.number().int().positive().nullable(),
});
export type UnitStatus = z.infer<typeof UnitStatusSchema>;

export const AlertListInputSchema = z.object({ filter: z.enum(['open', 'mine', 'all']).default('open'), page: PageSchema });
export const AlertListOutputSchema = z.object({ items: z.array(AlertSchema), total: z.number().int().nonnegative(), page: z.number().int() });
export const AlertIdInputSchema = z.object({ id: z.number().int().positive() });

/** Tablet push topic payloads. */
export const AlertPushSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('created'), alert: AlertSchema }),
  z.object({ type: z.literal('updated'), alert: AlertSchema }),
  z.object({ type: z.literal('closed'), id: z.number().int().positive() }),
]);
export type AlertPush = z.infer<typeof AlertPushSchema>;
export const UnitsPushSchema = z.object({ units: z.array(UnitStatusSchema) });

/**
 * Tablet actions added in Phase 3; the fredpd_mdt dispatcher merges them into its action table and routes them to
 * fredpd_dispatch exports (same `{ ok, data | error }` convention as §C12). `closeAlert` is allowed for an assigned
 * officer or a holder of perm `alerts.manage` (checked inside fredpd_dispatch, not by the grant column below).
 */
export const DISPATCH_ACTIONS = {
  listAlerts: { input: AlertListInputSchema, output: AlertListOutputSchema, grant: ['mdt_page', 'alerts'] },
  takeAlert: { input: AlertIdInputSchema, output: AlertSchema, grant: ['mdt_page', 'alerts'] },
  leaveAlert: { input: AlertIdInputSchema, output: AlertSchema, grant: ['mdt_page', 'alerts'] },
  closeAlert: { input: AlertIdInputSchema, output: AlertSchema, grant: ['mdt_page', 'alerts'] },
  getUnits: { input: z.object({}).strict(), output: UnitsPushSchema, grant: ['mdt_page', 'alerts'] },
} as const;
export type DispatchActionName = keyof typeof DISPATCH_ACTIONS;

/** Service /internal/events payloads for the alert event types (actions.ts INTERNAL_EVENT_TYPES). */
export const DispatchInternalEventSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('alertCreated'), payload: AlertSchema }),
  z.object({ type: z.literal('alertAssigned'), payload: AlertSchema }),
  z.object({ type: z.literal('alertClosed'), payload: z.object({ id: z.number().int().positive() }) }),
  z.object({ type: z.literal('unitsChanged'), payload: UnitsPushSchema }),
]);
export type DispatchInternalEvent = z.infer<typeof DispatchInternalEventSchema>;
