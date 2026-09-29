// SPDX-License-Identifier: GPL-3.0-only
// Typed tablet actions (docs/contracts.md §C12, packages/types/src/mdt.ts): callMdt(action, input) posts through
// fetchNui, turns `{ error }` answers into MdtClientError, restores Lua's absent nulls (src/api/wire.ts) and, in
// dev builds only, validates the answer against the action's zod output schema so contract drift shows up at once.
//
// Query keys are ['mdt', action, input]. Server pushes (`fredpd:client:push` → NUI `{ action: 'push', topic }`)
// invalidate the actions whose data the topic can change (PUSH_INVALIDATES); mutations invalidate theirs.
import type { QueryClient } from '@tanstack/react-query';
import { TABLET_ACTIONS } from './actions';
import type { TabletActionName as MdtActionName, TabletInput as MdtInput, TabletOutput as MdtOutput } from './actions';
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
  const result = TABLET_ACTIONS[action].output.safeParse(value);
  if (!result.success) {
    console.error(`[fredpd] ${action}: the answer does not match its packages/types output schema`, result.error.issues, value);
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
  const value = normalizeWire(TABLET_ACTIONS[action].output, raw);
  if (IS_DEV_BUILD) devValidate(action, value);
  return value as MdtOutput<A>;
}

/** Actions that read data (everything else is a write or `close`). */
export const QUERY_ACTIONS = [
  'getHome',
  'search',
  'getPerson',
  'getVehicle',
  'listBolos',
  'listTablets',
  'listAlerts',
  'getUnits',
  'listEvidence',
  'getEvidence',
  'listCases',
  'getCase',
  'getReport',
  'listReportTemplates',
  'listCharges',
  'listSources',
  'getSource',
  'listIntelReports',
  'getIntelReport',
  'searchEntities',
  'getEntity',
  'getGraph',
  'listMissions',
  'getMission',
] as const satisfies readonly MdtActionName[];

const BOLO_READERS = ['listBolos', 'getPerson', 'getVehicle', 'getHome', 'search'] as const satisfies readonly MdtActionName[];
const CASE_READERS = ['getPerson', 'getVehicle', 'getHome', 'search', 'listCases', 'getCase', 'getReport', 'listEvidence', 'getEvidence'] as const satisfies readonly MdtActionName[];

/**
 * Push topic → actions to refetch. `bolo` changes the BOLO lists, the person/vehicle pages, Hem and the search
 * hits' BOLO flag; `case` everything that lists case refs, the case/report pages and evidence (fredpd_forensics
 * pushes `{ type = 'evidenceLinked', caseId, evidenceId }` on it); `grants` can change what any answer contains
 * (tier, units), so it refetches everything (the nav itself follows the new grants in TabletContext).
 * `alerts` and `units` are NOT here: their payload carries the new state and is written into the cache
 * (src/api/pushes.ts), so a burst of alerts never turns into a burst of listAlerts calls.
 */
export const PUSH_INVALIDATES: Readonly<Record<string, readonly MdtActionName[]>> = {
  bolo: BOLO_READERS,
  case: CASE_READERS,
  grants: QUERY_ACTIONS,
};

const CASE_WRITE_READERS = ['listCases', 'getHome', 'getPerson', 'getVehicle', 'search'] as const satisfies readonly MdtActionName[];

/** Mutation → actions whose cached answers it makes stale (the push that follows would do it too, later). */
export const MUTATION_INVALIDATES: Readonly<Partial<Record<MdtActionName, readonly MdtActionName[]>>> = {
  createBolo: BOLO_READERS,
  resolveBolo: BOLO_READERS,
  checkPlate: ['getVehicle'],
  setTabletRevoked: ['listTablets'],
  createCase: CASE_WRITE_READERS,
  updateCase: CASE_WRITE_READERS,
  assignCase: CASE_WRITE_READERS,
  unassignCase: CASE_WRITE_READERS,
  addCaseSubject: CASE_WRITE_READERS,
  closeCase: CASE_WRITE_READERS,
  createReport: ['getCase'],
  saveReport: ['getCase'],
  applyCharges: ['getReport', 'getPerson'],
  issueFine: ['getReport', 'getPerson'],
  linkEvidence: ['listEvidence', 'getCase'],
  createSource: ['listSources'],
  updateSource: ['listSources'],
  createIntelReport: ['listIntelReports', 'getEntity', 'getMission', 'getSource'],
  addLink: ['getEntity', 'getGraph'],
  createMission: ['listMissions'],
  addMissionMember: ['listMissions'],
  closeMission: ['listMissions'],
};

/**
 * Mutation → the query its answer replaces (same shape): written into the cache instead of refetched. E.g.
 * `assignCase` answers the new CaseDetail, which is exactly `getCase { id }`.
 */
export const MUTATION_WRITES: Readonly<Partial<Record<MdtActionName, (data: unknown, input: unknown) => readonly [MdtActionName, unknown] | null>>> = {
  updateCase: (_d, input) => ['getCase', { id: (input as { id: number }).id }],
  assignCase: (_d, input) => ['getCase', { id: (input as { id: number }).id }],
  unassignCase: (_d, input) => ['getCase', { id: (input as { id: number }).id }],
  addCaseSubject: (_d, input) => ['getCase', { id: (input as { id: number }).id }],
  closeCase: (_d, input) => ['getCase', { id: (input as { id: number }).id }],
  createReport: (data) => ['getReport', { id: (data as { id: number }).id }],
  saveReport: (data) => ['getReport', { id: (data as { id: number }).id }],
  linkEvidence: (data) => ['getEvidence', { id: (data as { id: number }).id }],
  updateSource: (data) => ('id' in (data as object) ? ['getSource', { id: (data as { id: number }).id }] : null),
  addMissionMember: (data) => ('id' in (data as object) ? ['getMission', { id: (data as { id: number }).id }] : null),
  closeMission: (data) => ('id' in (data as object) ? ['getMission', { id: (data as { id: number }).id }] : null),
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
