// SPDX-License-Identifier: GPL-3.0-only
// Every tablet action the NUI can call: the Phase 2 MDT_ACTIONS plus the registries fredpd_mdt's dispatcher merges
// (docs/contracts.md §C12–§C16, docs/modules/mdt.md "Actions"): DISPATCH_ACTIONS (larm), EVIDENCE_ACTIONS (bevis),
// RECORDS_ACTIONS (ärenden, rapporter, brottskatalog) and INTEL_ACTIONS (underrättelser). One name space: the
// resources' validate.test.ts checks that no name is in two registries.
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import { DISPATCH_ACTIONS } from '@fredpd/types/dispatch';
import { EVIDENCE_ACTIONS } from '@fredpd/types/evidence';
import { RECORDS_ACTIONS } from '@fredpd/types/records';
import { INTEL_ACTIONS } from '@fredpd/types/intel';

export const TABLET_ACTIONS = {
  ...MDT_ACTIONS,
  ...DISPATCH_ACTIONS,
  ...EVIDENCE_ACTIONS,
  ...RECORDS_ACTIONS,
  ...INTEL_ACTIONS,
} as const;

export type TabletActions = typeof TABLET_ACTIONS;
export type TabletActionName = keyof TabletActions;
// zod 4's z.input / z.output read `_zod.input` / `_zod.output`; zod itself is not a direct dependency of this app.
export type TabletInput<A extends TabletActionName> = TabletActions[A]['input']['_zod']['input'];
export type TabletOutput<A extends TabletActionName> = TabletActions[A]['output']['_zod']['output'];

export const TABLET_ACTION_NAMES = Object.keys(TABLET_ACTIONS) as TabletActionName[];
