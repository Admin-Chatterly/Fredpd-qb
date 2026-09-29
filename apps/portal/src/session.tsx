// SPDX-License-Identifier: GPL-3.0-only
// GET /api/session (docs/modules/service.md): the logged-in user with a client copy of their grants, and the CSRF
// token for writes. Logged out = `{ user: null, csrfToken: null }`.
import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { SessionResponseSchema } from '@fredpd/types/actions';
import type { SessionResponse, SessionUser } from '@fredpd/types/actions';
import { hasGrant } from '@fredpd/types/grants';
import { apiFetch } from './api';

export const SESSION_QUERY_KEY = ['session'] as const;

/** `expired`: set locally when a call answered 401 (the login page then says the session ran out). */
export type PortalSession = SessionResponse & { expired?: boolean };

export interface SessionState {
  status: 'loading' | 'error' | 'ready';
  user: SessionUser | null;
  csrfToken: string | null;
  expired: boolean;
  error: unknown;
  refetch: () => void;
}

export const SessionContext = createContext<SessionState | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const query = useQuery({
    queryKey: SESSION_QUERY_KEY,
    queryFn: (): Promise<PortalSession> => apiFetch('/api/session', { schema: SessionResponseSchema }),
  });
  const data = query.data;
  const value: SessionState = {
    status: data ? 'ready' : query.isError ? 'error' : 'loading',
    user: data?.user ?? null,
    csrfToken: data?.csrfToken ?? null,
    expired: data?.expired ?? false,
    error: query.error,
    refetch: () => void query.refetch(),
  };
  return <SessionContext value={value}>{children}</SessionContext>;
}

export function useSession(): SessionState {
  const ctx = useContext(SessionContext);
  if (!ctx) throw new Error('useSession() outside <SessionProvider>');
  return ctx;
}

/** Portal perms are `perm:<key>` grants (e.g. `admin.permissions`). */
export function hasPerm(user: SessionUser | null, key: string): boolean {
  return !!user && hasGrant(user.grants, 'perm', key);
}

export const ADMIN_PERMISSIONS_PERM = 'admin.permissions';
