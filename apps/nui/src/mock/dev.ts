// SPDX-License-Identifier: GPL-3.0-only
// Browser dev mode (`pnpm --filter @fredpd/nui dev`): fake Lua answers and a fake open message, so the tablet runs
// without FiveM. Only imported behind `import.meta.env.DEV && isEnvBrowser()`, so production builds drop it.
//
// Preview other units or grants through the URL, e.g. http://localhost:5174/?unit=tekniker&pages=search,cases
//   unit=<code>|none   primary unit (default igv)
//   pages=a,b,c        mdt_page grants (default *)
import type { MdtOpenPayload } from '@fredpd/types/actions';
import { UnitCodeSchema } from '@fredpd/types/actions';
import { debugData } from '../utils/debugData';
import { registerNuiMock } from '../utils/fetchNui';
import { findUnit } from '../units';

export function mockOpenPayload(search: string = window.location.search): MdtOpenPayload {
  const params = new URLSearchParams(search);
  const unitParam = params.get('unit') ?? 'igv';
  const unit = unitParam !== 'none' && UnitCodeSchema.safeParse(unitParam).success ? unitParam : null;
  const pages = (params.get('pages') ?? '*').split(',').filter((p) => /^[A-Za-z0-9_*-]+$/.test(p));
  const grants = [...pages.map((p) => `mdt_page:${p}`), ...(unit ? [`unit:${unit}`] : []), 'intel_tier:1'].sort();
  return {
    grants: { grants, denied: [], tier: 1, units: unit ? [unit] : [], rank: null, computedAt: new Date().toISOString() },
    unit,
    me: { citizenid: 'DEV00001', displayName: 'Anna Berg', callsign: `${findUnit(unit)?.callsign ?? 'IGV'}-07` },
  };
}

/** Answers for the NUI callbacks the shell calls. Later tasks register theirs next to these. */
export function registerDevMocks(): void {
  registerNuiMock('close', () => ({}));
}

export function openMockTablet(): void {
  debugData([{ action: 'open', ...mockOpenPayload() }]);
}
