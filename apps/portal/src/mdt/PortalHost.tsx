// SPDX-License-Identifier: GPL-3.0-only
// Hosts the shared MDT pages in the portal (packages/ui mdtHost.tsx): the portal transport (POST /api/mdt/:action
// with the session's CSRF token) and a session shaped like the tablet's open payload, built from GET /api/session
// (grants: menus only; the service/FXServer check every call) and the picked character (the actor citizenid is the
// one stored in the server-side session, never taken from this object).
import { useMemo } from 'react';
import type { ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { UNIT_CODE_RE } from '@fredpd/types/actions';
import type { GrantSet } from '@fredpd/types/grants';
import { MdtHostProvider } from '@fredpd/ui';
import type { MdtHostSession } from '@fredpd/ui';
import { SESSION_QUERY_KEY, useSession } from '../session';
import type { PortalSession } from '../session';
import { createPortalTransport } from './transport';

/** The first held unit (§C2 orders `units` by config/units.json), as the tablet's open payload has it. */
export function primaryUnit(grants: GrantSet): string | null {
  const first = grants.units[0];
  return first !== undefined && UNIT_CODE_RE.test(first) ? first : null;
}

export function PortalMdtHost({ children }: { children: ReactNode }) {
  const { user, csrfToken } = useSession();
  const queryClient = useQueryClient();

  const transport = useMemo(
    () =>
      createPortalTransport({
        csrfToken: () => csrfToken,
        onUnauthorized: () => queryClient.setQueryData<PortalSession>(SESSION_QUERY_KEY, { user: null, csrfToken: null, expired: true }),
        onCsrfRejected: () => void queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY }),
      }),
    [csrfToken, queryClient],
  );

  const session = useMemo<MdtHostSession | null>(
    () =>
      user?.citizenid
        ? { grants: user.grants, unit: primaryUnit(user.grants), me: { citizenid: user.citizenid, displayName: user.displayName, callsign: null } }
        : null,
    [user],
  );

  if (!session) return null;
  return (
    <MdtHostProvider transport={transport} session={session}>
      {children}
    </MdtHostProvider>
  );
}
