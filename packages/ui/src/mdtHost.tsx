// SPDX-License-Identifier: GPL-3.0-only
// Where the shared MDT pages run (task 7.1): the tablet NUI (fetchNui → fredpd_mdt) or the web portal
// (POST /api/mdt/:action → fredpd_service → FXServer, portal mode). The pages only see this host:
// - `transport.call(action, input)` answers the dispatcher's raw JSON: the action output or `{ error, reason? }`
//   (docs/contracts.md §C12). A call that got no usable answer at all throws MdtTransportError.
// - `session` is the tablet's open payload (grants for menus, primary unit, the acting character); in the portal
//   it is built from GET /api/session and the picked character. The server checks every call again.
// - `mode` hides what only works with a player in the world (PORTAL_BLOCKED_ACTIONS; the service answers 403 anyway).
import { createContext, useContext, useMemo } from 'react';
import type { ReactNode } from 'react';
import type { MdtOpenPayload } from '@fredpd/types/actions';

export type MdtHostMode = 'tablet' | 'portal';

export interface MdtTransport {
  readonly mode: MdtHostMode;
  /** Raw dispatcher answer (output or `{ error, reason? }`). Throws MdtTransportError when nothing usable came back. */
  call(action: string, input: unknown): Promise<unknown>;
}

/** No usable answer: the request failed (status 0) or answered a status without a `{ error }` body. */
export class MdtTransportError extends Error {
  constructor(
    readonly action: string,
    readonly status: number,
  ) {
    super(`MDT transport "${action}" failed (${status === 0 ? 'network' : `HTTP ${status}`})`);
    this.name = 'MdtTransportError';
  }
}

/** Same shape as the tablet's open payload: grants (menus only), primary unit, the acting officer/character. */
export type MdtHostSession = MdtOpenPayload;

export interface MdtHost {
  transport: MdtTransport;
  session: MdtHostSession;
}

const MdtHostContext = createContext<MdtHost | null>(null);

export function MdtHostProvider({ transport, session, children }: MdtHost & { children: ReactNode }) {
  const value = useMemo<MdtHost>(() => ({ transport, session }), [transport, session]);
  return <MdtHostContext value={value}>{children}</MdtHostContext>;
}

/** The host, or null outside a provider (the tablet then falls back to its NUI transport). */
export function useMdtHost(): MdtHost | null {
  return useContext(MdtHostContext);
}

export function useMdtTransport(): MdtTransport | null {
  return useContext(MdtHostContext)?.transport ?? null;
}

export function useMdtMode(): MdtHostMode {
  return useContext(MdtHostContext)?.transport.mode ?? 'tablet';
}

/**
 * Actions the portal never offers (portal action contract, task 7.1): the tablet `close`, everything that needs a
 * player in the world (plate check at the car, alert take/leave/close with waypoints, a fine billed on the spot)
 * and the writes that are neither records, intel nor BOLO writes (tablet revocation, evidence linking). The service
 * refuses them with 403 `unauthorized` (reason `portal`); the pages hide their controls.
 */
export const PORTAL_BLOCKED_ACTIONS: readonly string[] = [
  'close',
  'checkPlate',
  'takeAlert',
  'leaveAlert',
  'closeAlert',
  'issueFine',
  'setTabletRevoked',
  'linkEvidence',
];

export function isActionAvailable(mode: MdtHostMode, action: string): boolean {
  return mode === 'tablet' || !PORTAL_BLOCKED_ACTIONS.includes(action);
}

/** Whether this host can offer `action` at all (grants are checked separately). */
export function useActionAvailable(action: string): boolean {
  return isActionAvailable(useMdtMode(), action);
}
