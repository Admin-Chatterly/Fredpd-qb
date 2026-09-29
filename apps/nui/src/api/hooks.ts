// SPDX-License-Identifier: GPL-3.0-only
// TanStack Query hooks over callMdt, through the host's transport (tablet or portal, packages/ui mdtHost.tsx). Queries use the client defaults (staleTime 30 s, refetch when the tablet
// opens, never on a timer; src/queryClient.ts) and retry once only for errors a retry can fix.
import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { UseMutationResult, UseQueryResult } from '@tanstack/react-query';
import type { TabletActionName as MdtActionName, TabletInput as MdtInput, TabletOutput as MdtOutput } from './actions';
import { useMdtTransport } from '@fredpd/ui';
import type { MdtTransport } from '@fredpd/ui';
import { MUTATION_INVALIDATES, MUTATION_WRITES, callMdt, invalidateActions, mdtQueryKey } from './client';
import { nuiTransport } from './transport';
import { isRetryable } from './errors';
import type { MdtClientError } from './errors';

export interface MdtQueryOptions {
  enabled?: boolean;
  /** Keep showing the previous answer while another input (the next page) loads. */
  keepPrevious?: boolean;
}

/**
 * Key, fetcher and retry policy of an action query, shared by useMdtQuery and imperative fetches
 * (queryClient.fetchQuery in the header search), so both hit the same cache entry the same way.
 */
export function mdtQueryOptions<A extends MdtActionName>(action: A, input: MdtInput<A>, transport: MdtTransport = nuiTransport) {
  return {
    queryKey: mdtQueryKey(action, input),
    queryFn: () => callMdt(action, input, transport),
    retry: (failureCount: number, error: unknown) => failureCount < 1 && isRetryable(error),
    retryDelay: 600,
  };
}

/** The host's transport (packages/ui MdtHostProvider); the tablet's NUI transport outside a provider. */
export function useTransport(): MdtTransport {
  return useMdtTransport() ?? nuiTransport;
}

export function useMdtQuery<A extends MdtActionName>(action: A, input: MdtInput<A>, options: MdtQueryOptions = {}): UseQueryResult<MdtOutput<A>, MdtClientError> {
  const transport = useTransport();
  return useQuery<MdtOutput<A>, MdtClientError>({
    ...mdtQueryOptions(action, input, transport),
    enabled: options.enabled ?? true,
    placeholderData: options.keepPrevious ? keepPreviousData : undefined,
  });
}

export interface MdtMutationOptions<A extends MdtActionName> {
  onSuccess?: (data: MdtOutput<A>, input: MdtInput<A>) => void;
  onError?: (error: MdtClientError, input: MdtInput<A>) => void;
}

export function useMdtMutation<A extends MdtActionName>(
  action: A,
  options: MdtMutationOptions<A> = {},
): UseMutationResult<MdtOutput<A>, MdtClientError, MdtInput<A>> {
  const queryClient = useQueryClient();
  const transport = useTransport();
  return useMutation<MdtOutput<A>, MdtClientError, MdtInput<A>>({
    mutationFn: (input) => callMdt(action, input, transport),
    onSuccess: (data, input) => {
      const write = MUTATION_WRITES[action]?.(data, input);
      if (write) queryClient.setQueryData(mdtQueryKey(write[0], write[1] as never), data);
      void invalidateActions(queryClient, MUTATION_INVALIDATES[action] ?? []);
      options.onSuccess?.(data, input);
    },
    onError: (error, input) => options.onError?.(error, input),
  });
}
