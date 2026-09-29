// SPDX-License-Identifier: GPL-3.0-only
// Placeholder for a portal action the server does not know yet. The service answers an action outside its
// registry with { error: 'validation', reason: 'action' } (apps/service/src/routes/portal.ts); until the records
// actions (getPoi, createShare, release requests) are in packages/types' registries (docs/modules/portal.md,
// integration request 1), those pages show this instead of a validation error.
import { EmptyState, useI18n } from '@fredpd/ui';
import { MdtClientError } from '../mdt/shared';

/** True when the server refused the call because it does not know the action at all. */
export function isActionMissing(err: unknown): boolean {
  return err instanceof MdtClientError && err.code === 'validation' && err.reason === 'action';
}

export function NotAvailableYet() {
  const { tx } = useI18n();
  return (
    <div data-not-available>
      <EmptyState title={tx('portal.notAvailableYet')} />
    </div>
  );
}
