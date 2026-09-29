// SPDX-License-Identifier: GPL-3.0-only
// Shell page for the §5.2 routes that later tasks fill (7.1 roster) and the not-found page. Every other section is
// built (src/routes.tsx).
import type { ReactNode } from 'react';
import { Card, EmptyState, PageHeader, useT } from '@fredpd/ui';

export function PlaceholderPage({ title, subtitle, empty }: { title: string; subtitle?: ReactNode; empty?: ReactNode }) {
  return (
    <>
      <PageHeader title={title} subtitle={subtitle} />
      <Card padded={false}>
        <EmptyState title={empty} />
      </Card>
    </>
  );
}

export function NotFoundPage() {
  const t = useT();
  return <EmptyState title={t('errors.notFound')} className="h-full" />;
}
