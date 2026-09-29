// SPDX-License-Identifier: GPL-3.0-only
// Perm grants the tablet uses to show or hide actions (docs/contracts.md §C12). A UI hint only: fredpd_mdt checks
// the action's grant on every call.
import { hasGrant } from '@fredpd/types/grants';
import type { GrantLists } from '@fredpd/types/grants';
import { useSession } from './tablet/TabletContext';

export const PERMS = {
  boloCreate: 'bolo.create',
  boloResolve: 'bolo.resolve',
  tabletsManage: 'tablets.manage',
} as const;

export type NuiPerm = (typeof PERMS)[keyof typeof PERMS];

export function hasPerm(grants: GrantLists | null | undefined, perm: NuiPerm): boolean {
  return hasGrant(grants, 'perm', perm);
}

export function usePerm(perm: NuiPerm): boolean {
  return hasPerm(useSession().grants, perm);
}
