// SPDX-License-Identifier: GPL-3.0-only
// TanStack Query defaults for the tablet (IMPLEMENTATION.md §4.7): data is fresh for 30 s, stale queries refetch
// when the tablet opens (TabletProvider drives focusManager from open/close), never on a timer.
import { QueryClient } from '@tanstack/react-query';

export const QUERY_STALE_TIME_MS = 30_000;

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: QUERY_STALE_TIME_MS,
        refetchOnWindowFocus: true,
        refetchOnReconnect: false,
        refetchInterval: false,
        retry: 1,
      },
      mutations: { retry: false },
    },
  });
}
