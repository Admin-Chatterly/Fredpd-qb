// SPDX-License-Identifier: GPL-3.0-only
// Typed tablet actions (docs/contracts.md §C12, packages/types/src/mdt.ts): callMdt(action, input) posts through
// fetchNui, turns `{ error }` answers into MdtClientError, restores Lua's absent nulls (src/api/wire.ts) and, in
// dev builds only, validates the answer against the action's zod output schema so contract drift shows up at once.
//
// Query keys are ['mdt', action, input]. Server pushes (`fredpd:client:push` → NUI `{ action: 'push', topic }`)
// invalidate the actions whose data the topic can change (PUSH_INVALIDATES); mutations invalidate theirs.
import type { QueryClient } from '@tanstack/react-query';
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import type { MdtActionName, MdtInput, MdtOutput } from '@fredpd/types/mdt';
import { IS_DEV_BUILD } from '../utils/env';
import { fetchNui } from '../utils/fetchNui';
import { MdtClientError, readErrorResponse, toMdtClientError } from './errors';
import { normalizeWire } from './wire';

export const MDT_QUERY_ROOT = 'mdt';

export type MdtQueryKey = readonly [typeof MDT_QUERY_ROOT, MdtActionName, unknown?];

export function mdtQueryKey<A extends MdtActionName>(action: A, input?: MdtInput<A>): MdtQueryKey {
  return input === undefined ? [MDT_QUERY_ROOT, action] : [MDT_QUERY_ROOT, action, input];
}

/** Dev builds: a response that does not match mdt.ts is an error (logged with the zod issues). */
function devValidate(action: MdtActionName, value: unknown): void {
  const result = MDT_ACTIONS[action].output.safeParse(value);
  if (!result.success) {
    console.error(`[fredpd] ${action}: the answer does not match packages/types/src/mdt.ts`, result.error.issues, value);
    throw new MdtClientError(action, 'unknown', 'contract');
  }
}

export async function callMdt<A extends MdtActionName>(action: A, input: MdtInput<A>): Promise<MdtOutput<A>> {
  let raw: unknown;
  try {
    raw = await fetchNui<unknown>(action, input ?? {});
  } catch (err) {
    throw toMdtClientError(action, err);
  }
  const error = readErrorResponse(action, raw);
  if (error) throw error;
  const value = normalizeWire(MDT_ACTIONS[action].output, raw);
  if (IS_DEV_BUILD) devValidate(action, value);
  return value as MdtOutput<A>;
}

/** Actions that read data (everything else is a write or `close`). */
export const QUERY_ACTIONS = ['getHome', 'search', 'getPerson', 'getVehicle', 'listBolos', 'listTablets'] as const satisfies readonly MdtActionName[];

const BOLO_READERS = ['listBolos', 'getPerson', 'getVehicle', 'getHome', 'search'] as const satisfies readonly MdtActionName[];

/**
 * Push topic → actions to refetch. `bolo` changes the BOLO lists, the person/vehicle pages, Hem and the search
 * hits' BOLO flag; `case` everything that lists case refs; `grants` can change what any answer contains (tier,
 * units), so it refetches everything (the nav itself follows the new grants in TabletContext).
 */
export const PUSH_INVALIDATES: Readonly<Record<string, readonly MdtActionName[]>> = {
  bolo: BOLO_READERS,
  case: ['getPerson', 'getVehicle', 'getHome', 'search'],
  grants: QUERY_ACTIONS,
};

/** Mutation → actions whose cached answers it makes stale (the push that follows would do it too, later). */
export const MUTATION_INVALIDATES: Readonly<Partial<Record<MdtActionName, readonly MdtActionName[]>>> = {
  createBolo: BOLO_READERS,
  resolveBolo: BOLO_READERS,
  checkPlate: ['getVehicle'],
  setTabletRevoked: ['listTablets'],
};

export type RefetchType = 'active' | 'none' | 'all' | 'inactive';

export function invalidateActions(queryClient: QueryClient, actions: readonly MdtActionName[], refetchType: RefetchType = 'active'): Promise<void> {
  if (actions.length === 0) return Promise.resolve();
  return queryClient.invalidateQueries({
    predicate: (query) => query.queryKey[0] === MDT_QUERY_ROOT && (actions as readonly unknown[]).includes(query.queryKey[1]),
    refetchType,
  });
}

/** Called by TabletContext for every push (closed tablet: refetchType 'none', only marked stale). */
export function invalidateForPush(queryClient: QueryClient, topic: string, refetchType: RefetchType): Promise<void> {
  return invalidateActions(queryClient, PUSH_INVALIDATES[topic] ?? [], refetchType);
}
