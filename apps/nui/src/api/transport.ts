// SPDX-License-Identifier: GPL-3.0-only
// The tablet's MdtTransport (packages/ui mdtHost.tsx): every action goes through fetchNui to fredpd_mdt's
// RegisterNUICallback (docs/contracts.md §C12). The portal supplies its own transport (apps/portal/src/mdt).
import type { MdtTransport } from '@fredpd/ui';
import { fetchNui } from '../utils/fetchNui';

export const nuiTransport: MdtTransport = {
  mode: 'tablet',
  call: (action, input) => fetchNui<unknown>(action, input ?? {}),
};
