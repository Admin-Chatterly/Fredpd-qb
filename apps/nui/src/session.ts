// SPDX-License-Identifier: GPL-3.0-only
// The acting session of the shared MDT pages: the tablet's open payload, or in the portal the payload built from
// GET /api/session and the picked character. Both reach the pages through packages/ui's MdtHostProvider
// (TabletRoutes wraps the tablet's routes in one), so the pages never import the tablet or the portal directly.
import { useMdtHost } from '@fredpd/ui';
import type { MdtHostSession } from '@fredpd/ui';

export function useSession(): MdtHostSession {
  const host = useMdtHost();
  if (!host) throw new Error('useSession() outside <MdtHostProvider>');
  return host.session;
}
