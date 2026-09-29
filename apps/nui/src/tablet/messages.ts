// SPDX-License-Identifier: GPL-3.0-only
// Lua -> NUI messages (SendNUIMessage in fredpd_mdt; docs/modules/ui.md "NUI messages"):
//   { action = 'open', grants = GrantSet, unit = 'igv' | nil, me = { citizenid, displayName, callsign } }
//   { action = 'close' }
//   { action = 'push', topic = 'alerts' | 'units' | 'bolo' | 'case' | 'grants', payload = ... }
// The open fields sit next to `action` (IMPLEMENTATION.md §5.2), validated with MdtOpenPayloadSchema.
import { GrantSetSchema } from '@fredpd/types/grants';
import type { GrantSet } from '@fredpd/types/grants';
import { MdtOpenPayloadSchema } from '@fredpd/types/actions';
import type { MdtOpenPayload } from '@fredpd/types/actions';

export type NuiOpenMessage = { action: 'open' } & MdtOpenPayload;
export type NuiCloseMessage = { action: 'close' };
export type NuiPushMessage = { action: 'push'; topic: string; payload?: unknown };
export type NuiMessage = NuiOpenMessage | NuiCloseMessage | NuiPushMessage;

/** Push topic that replaces the client copy of the grants (fredpd:client:grantsChanged while the tablet is open). */
export const GRANTS_TOPIC = 'grants';

export type ParsedMessage =
  | { action: 'open'; payload: MdtOpenPayload | null }
  | { action: 'close' }
  | { action: 'push'; topic: string; payload: unknown }
  | { action: 'grants'; grants: GrantSet };

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Lua encodes an empty table as `{}`: read an empty object as an empty list for the GrantSet list fields. */
function normaliseGrantSet(value: unknown): unknown {
  if (!isRecord(value)) return value;
  const out: Record<string, unknown> = { ...value };
  for (const field of ['grants', 'denied', 'units']) {
    const v = out[field];
    if (isRecord(v) && Object.keys(v).length === 0) out[field] = [];
  }
  return out;
}

/** Lua has no null: a missing `unit` or `me.callsign` means "none". */
function normaliseOpen(rest: Record<string, unknown>): unknown {
  const me = isRecord(rest.me) ? { callsign: null, ...rest.me } : rest.me;
  return { unit: null, ...rest, me, grants: normaliseGrantSet(rest.grants) };
}

/**
 * Reads a window message. Returns null for anything that is not a FredPD message (other scripts' NUI frames and
 * browser extensions post messages too). An `open` with an invalid payload keeps `payload: null` so the tablet can
 * still open, show an error and be closed.
 */
export function parseNuiMessage(data: unknown): ParsedMessage | null {
  if (typeof data !== 'object' || data === null || !('action' in data)) return null;
  const { action, ...rest } = data as { action: unknown } & Record<string, unknown>;
  switch (action) {
    case 'open': {
      const parsed = MdtOpenPayloadSchema.safeParse(normaliseOpen(rest));
      return { action: 'open', payload: parsed.success ? parsed.data : null };
    }
    case 'close':
      return { action: 'close' };
    case 'push': {
      if (typeof rest.topic !== 'string' || rest.topic === '') return null;
      if (rest.topic === GRANTS_TOPIC) {
        const grants = GrantSetSchema.safeParse(normaliseGrantSet(rest.payload));
        return grants.success ? { action: 'grants', grants: grants.data } : null;
      }
      return { action: 'push', topic: rest.topic, payload: rest.payload };
    }
    default:
      return null;
  }
}
