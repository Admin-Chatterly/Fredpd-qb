// SPDX-License-Identifier: GPL-3.0-only
// Unknown routes and pages the user may not see look the same (no hint that an admin page exists).
import { EmptyState, useT } from '@fredpd/ui';

export function NotFoundPage() {
  const t = useT();
  return <EmptyState title={t('errors.notFound')} className="py-16" />;
}
