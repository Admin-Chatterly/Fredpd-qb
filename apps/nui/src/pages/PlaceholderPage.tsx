// SPDX-License-Identifier: GPL-3.0-only
// Shell pages for the §5.2 routes that later tasks fill (3.2 alerts, 5.2 cases, 5.3 reports, 4.2 evidence,
// 5b.2 intel, 5.4 charges, 7.1 roster). Search, person, vehicle, BOLOs, Hem and Ledning → Surfplattor are built.
import type { ReactNode } from 'react';
import { useParams } from 'react-router';
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

export function CasePage() {
  const t = useT();
  const { id = '' } = useParams();
  return <PlaceholderPage title={t('case.field.number')} subtitle={id} />;
}

export function ReportPage() {
  const t = useT();
  const { id = '' } = useParams();
  return <PlaceholderPage title={t('report.title')} subtitle={id} />;
}

export function NotFoundPage() {
  const t = useT();
  return <EmptyState title={t('errors.notFound')} className="h-full" />;
}
