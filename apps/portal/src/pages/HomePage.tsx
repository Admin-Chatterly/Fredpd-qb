// SPDX-License-Identifier: GPL-3.0-only
// Portal start page. Task 7.1 adds the character picker and the Ledning pages.
import { Card, EmptyState, PageHeader, useT } from '@fredpd/ui';
import { useSession } from '../session';

export function HomePage() {
  const t = useT();
  const { user } = useSession();
  if (!user) return null;
  const hasAnyGrant = user.grants.grants.length > 0;
  return (
    <>
      <PageHeader title={t('home.greeting', { name: user.displayName })} subtitle={t('portal.title')} />
      <Card padded={false}>
        <EmptyState title={hasAnyGrant ? t('home.empty') : t('portal.login.noAccess')} />
      </Card>
    </>
  );
}
