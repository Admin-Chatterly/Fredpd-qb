// SPDX-License-Identifier: GPL-3.0-only
// Shell pages for the §5.2 routes. Each is replaced by its own task (2.3 search, 2.4 person, 2.5 vehicle, 2.6 BOLO,
// 3.2 alerts, 5.2 cases, 5.3 reports, 4.2 evidence, 5b.2 intel, 5.4 charges, 7.1 roster/command).
import type { ReactNode } from 'react';
import { useParams, useSearchParams } from 'react-router';
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

export function SearchPage() {
  const t = useT();
  const [params] = useSearchParams();
  const q = params.get('q')?.trim() ?? '';
  return <PlaceholderPage title={t('nav.search')} subtitle={q || t('mdt.search.hint')} empty={t('mdt.search.logged')} />;
}

export function PersonPage() {
  const t = useT();
  const { cid = '' } = useParams();
  return <PlaceholderPage title={t('person.title')} subtitle={cid} />;
}

export function VehiclePage() {
  const t = useT();
  const { plate = '' } = useParams();
  return <PlaceholderPage title={t('vehicle.title')} subtitle={plate} />;
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
