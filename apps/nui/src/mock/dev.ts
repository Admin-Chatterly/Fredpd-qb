// SPDX-License-Identifier: GPL-3.0-only
// Browser dev mode (`pnpm --filter @fredpd/nui dev`): fake Lua answers and a fake open message, so the tablet runs
// without FiveM. Only imported behind `import.meta.env.DEV && isEnvBrowser()`, so production builds drop it.
//
// Every tablet action (src/api/actions.ts TABLET_ACTIONS) answers from an in-memory Swedish register
// (src/mock/data.ts, handlers.ts for Phase 2, sections.ts for Larm, Ärenden, Bevis, Underrättelser).
// Answers go through toLuaWire (nulls removed, as Lua sends them) and a short delay, so the page code runs the same
// path as in game (normalizeWire, loading states). Things to try: search "Andersson", "19870412-5531", "ABC 12D",
// "K-1042-26" (full), "K-988-26" (masked), "K-1077-26" (kontaktnotis); Efterlysningar; Ledning → Surfplattor.
//
// Preview other units or grants through the URL, e.g. http://localhost:5174/?unit=tekniker&pages=search,cases
//   unit=<code>|none   primary unit (default igv)
//   pages=a,b,c        mdt_page grants (default *)
//   perms=a,b|none     perm grants (default: every perm the pages use except alerts.manage/records.admin)
//   tier=0|1|2         intel tier (default 1)
import type { MdtOpenPayload } from '@fredpd/types/actions';
import { UnitCodeSchema } from '@fredpd/types/actions';
import { toLuaWire } from '../api/wire';
import { debugData } from '../utils/debugData';
import { registerNuiMock } from '../utils/fetchNui';
import { findUnit } from '../units';
import { createMockDb } from './data';
import { createMockHandlers } from './handlers';
import { createSectionMocks } from './sections';

const DEFAULT_PERMS = 'bolo.create,bolo.resolve,tablets.manage,cases.create,charges.apply,charges.fine,evidence.link,intel.read,intel.handler,intel.command';
const MOCK_LATENCY_MS = 150;

const list = (value: string | null, fallback: string) =>
  (value ?? fallback)
    .split(',')
    .filter((p) => p !== 'none' && /^[A-Za-z0-9_.:*-]+$/.test(p));

export function mockOpenPayload(search: string = window.location.search): MdtOpenPayload {
  const params = new URLSearchParams(search);
  const unitParam = params.get('unit') ?? 'igv';
  const unit = unitParam !== 'none' && UnitCodeSchema.safeParse(unitParam).success ? unitParam : null;
  const pages = list(params.get('pages'), '*');
  const perms = list(params.get('perms'), DEFAULT_PERMS);
  const tierParam = Number(params.get('tier') ?? '1');
  const tier = tierParam === 0 || tierParam === 2 ? tierParam : 1;
  const grants = [...pages.map((p) => `mdt_page:${p}`), ...perms.map((p) => `perm:${p}`), ...(unit ? [`unit:${unit}`] : []), `intel_tier:${tier}`].sort();
  return {
    grants: { grants, denied: [], tier, units: unit ? [unit] : [], rank: null, computedAt: new Date().toISOString() },
    unit,
    me: { citizenid: 'DEV00001', displayName: 'Anna Berg', callsign: `${findUnit(unit)?.callsign ?? 'IGV'}-07` },
  };
}

/** Answers for every NUI callback the tablet makes, from one shared mock register. */
export function registerDevMocks(search: string = window.location.search): void {
  const session = mockOpenPayload(search);
  const db = createMockDb({ me: { ...session.me, unit: session.unit }, tier: session.grants.tier, unit: session.unit });
  const handlers = { ...createMockHandlers(db), ...createSectionMocks(db) };
  for (const action of Object.keys(handlers) as (keyof typeof handlers)[]) {
    const handler = handlers[action] as (input: unknown) => unknown;
    registerNuiMock(action, async (data) => {
      await new Promise((resolve) => setTimeout(resolve, MOCK_LATENCY_MS));
      return toLuaWire(handler(data));
    });
  }
}

export function openMockTablet(): void {
  debugData([{ action: 'open', ...mockOpenPayload() }]);
}
