// SPDX-License-Identifier: GPL-3.0-only
// Route guard for a tablet section. The client copy of the grants only shapes the UI; the server checks every
// callback again (IMPLEMENTATION.md §4.1).
import type { ReactNode } from 'react';
import { EmptyState, IconShield, useT } from '@fredpd/ui';
import type { MdtPageKey } from '@fredpd/ui';
import { canSeePage } from '../nav';
import { useSession } from '../tablet/TabletContext';

export function RequirePage({ page, children }: { page: MdtPageKey; children: ReactNode }) {
  const t = useT();
  const { grants } = useSession();
  if (!canSeePage(grants, page)) {
    return <EmptyState icon={<IconShield size={28} />} title={t('errors.unauthorized')} className="h-full" />;
  }
  return <>{children}</>;
}
