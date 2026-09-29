// SPDX-License-Identifier: GPL-3.0-only
// Portal actions (docs/modules/portal-api.md): POST /api/mdt/:action runs a tablet action (same names, same zod
// input/output schemas as the NUI) through fredpd_mdt's dispatcher in portal mode. The registry is the tablet's
// (apps/nui/src/api/actions.ts merges the same five registries). Which actions the portal may run is decided on the
// FXServer (fredpd_mdt/server/portal.lua M.ALLOWED, authoritative); PORTAL_ACTIONS below is the same list so a
// world action is refused here without a round trip (test/portal.test.ts compares the two).
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import { DISPATCH_ACTIONS } from '@fredpd/types/dispatch';
import { EVIDENCE_ACTIONS } from '@fredpd/types/evidence';
import { RECORDS_ACTIONS } from '@fredpd/types/records';
import { INTEL_ACTIONS } from '@fredpd/types/intel';
import type { GrantType } from '@fredpd/types/grants';
import type { ZodType } from 'zod';

export const TABLET_ACTIONS = {
  ...MDT_ACTIONS,
  ...DISPATCH_ACTIONS,
  ...EVIDENCE_ACTIONS,
  ...RECORDS_ACTIONS,
  ...INTEL_ACTIONS,
} as const;
export type TabletActionName = keyof typeof TABLET_ACTIONS;

export interface ActionDef {
  input: ZodType;
  output: ZodType;
  grant: readonly [GrantType, string] | null;
}

/**
 * Every read (limit class read/lookup in fredpd_mdt's dispatcher) plus the fredpd_records / fredpd_intel /
 * fredpd_bolo writes, minus what needs a player in the world. Not here, so 403 { error: 'unauthorized',
 * reason: 'portal' }: close, checkPlate, takeAlert, leaveAlert, closeAlert, issueFine, setTabletRevoked, linkEvidence.
 */
export const PORTAL_ACTIONS = [
  'getHome', 'search', 'getPerson', 'getVehicle', 'listBolos', 'createBolo', 'resolveBolo', 'listTablets',
  'listAlerts', 'getUnits', 'listEvidence', 'getEvidence',
  'listCases', 'getCase', 'createCase', 'updateCase', 'assignCase', 'unassignCase', 'addCaseSubject', 'closeCase',
  'getReport', 'createReport', 'saveReport', 'saveReportDraft', 'listReportTemplates', 'listCharges', 'applyCharges',
  'listSources', 'getSource', 'createSource', 'updateSource', 'listIntelReports', 'getIntelReport',
  'createIntelReport', 'searchEntities', 'ensureEntity', 'getEntity', 'addLink', 'getGraph', 'listMissions',
  'getMission', 'createMission', 'addMissionMember', 'closeMission',
] as const satisfies readonly TabletActionName[];

const PORTAL_SET: ReadonlySet<string> = new Set(PORTAL_ACTIONS);
/** §C15: intel answers 404 (never 403) to anyone it refuses. */
const INTEL_SET: ReadonlySet<string> = new Set(Object.keys(INTEL_ACTIONS));

export function actionDef(name: string): ActionDef | null {
  if (!Object.prototype.hasOwnProperty.call(TABLET_ACTIONS, name)) return null;
  return TABLET_ACTIONS[name as TabletActionName] as unknown as ActionDef;
}

export function isPortalAction(name: string): boolean {
  return PORTAL_SET.has(name);
}

export function isIntelAction(name: string): boolean {
  return INTEL_SET.has(name);
}
