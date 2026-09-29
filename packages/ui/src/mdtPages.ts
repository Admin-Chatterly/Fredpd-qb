// SPDX-License-Identifier: GPL-3.0-only
// The `mdt_page` grant keys live in @fredpd/types (docs/contracts.md §C12: the service catalog and fredpd_mdt use them
// too). Re-exported here so the NUI and the portal keep importing them from @fredpd/ui.
export { MDT_PAGE_KEYS, MDT_PAGE_LABEL_KEYS, isMdtPageKey } from '@fredpd/types/mdtPages';
export type { MdtPageKey } from '@fredpd/types/mdtPages';
