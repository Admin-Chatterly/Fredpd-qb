// SPDX-License-Identifier: GPL-3.0-only
// Portal query defaults: fresh for 30 s, refetch on window focus, no polling (IMPLEMENTATION.md §4.7). A 401 from
// any call means the session ended: the cached session is replaced by "logged out, expired" and the login shows.
import { MutationCache, QueryCache, QueryClient } from '@tanstack/react-query';
import { ApiRequestError } from './api';
import { SESSION_QUERY_KEY } from './session';
import type { PortalSession } from './session';

export function createPortalQueryClient(): QueryClient {
  const onError = (error: unknown) => {
    if (error instanceof ApiRequestError && error.status === 401) {
      client.setQueryData<PortalSession>(SESSION_QUERY_KEY, { user: null, csrfToken: null, expired: true });
    }
  };
  const client: QueryClient = new QueryClient({
    queryCache: new QueryCache({ onError }),
    mutationCache: new MutationCache({ onError }),
    defaultOptions: {
      queries: { staleTime: 30_000, refetchOnWindowFocus: true, refetchInterval: false, retry: 1 },
      mutations: { retry: false },
    },
  });
  return client;
}
