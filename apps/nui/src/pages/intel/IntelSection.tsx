// SPDX-License-Identifier: GPL-3.0-only
// Underrättelser (/intel/*, tasks 5b.2–5b.3): sub-navigation Objekt | Källor | Rapporter | Insatser and the nested
// routes. The section needs mdt_page:intel (routes.tsx); Källor and Rapporter need perm intel.read (INTEL_ACTIONS),
// so without it their tabs are hidden and their routes show "not authorised" without calling anything.
import type { ReactNode } from 'react';
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router';
import { EmptyState, IconShield, PageHeader, Tabs, useI18n } from '@fredpd/ui';
import { PERMS, usePerm } from '../../perms';
import { EntitiesPage, EntityPage } from './EntityPages';
import { IntelReportPage, IntelReportsPage, MissionPage, MissionsPage, SourcePage, SourcesPage } from './IntelPages';

type IntelTab = 'objekt' | 'kallor' | 'rapporter' | 'insatser';

function NeedsRead({ children }: { children: ReactNode }) {
  const { t } = useI18n();
  const canRead = usePerm(PERMS.intelRead);
  return canRead ? <>{children}</> : <EmptyState icon={<IconShield size={28} />} title={t('errors.unauthorized')} />;
}

export function IntelSection() {
  const { t } = useI18n();
  const canRead = usePerm(PERMS.intelRead);
  const location = useLocation();
  const navigate = useNavigate();
  const current = (location.pathname.split('/')[2] ?? 'objekt') as IntelTab;
  const tabs: { id: IntelTab; label: string }[] = [
    { id: 'objekt', label: t('intel.section.entities') },
    ...(canRead ? [{ id: 'kallor' as const, label: t('intel.section.sources') }, { id: 'rapporter' as const, label: t('intel.section.reports') }] : []),
    { id: 'insatser', label: t('intel.section.missions') },
  ];
  return (
    <>
      <PageHeader title={t('intel.title')} />
      <Tabs className="mb-4" label={t('intel.title')} value={current} onChange={(id) => void navigate(`/intel/${id}`)} items={tabs} />
      <Routes>
        <Route index element={<Navigate to="objekt" replace />} />
        <Route path="objekt" element={<EntitiesPage />} />
        <Route path="objekt/:id" element={<EntityPage />} />
        <Route path="kallor" element={<NeedsRead><SourcesPage /></NeedsRead>} />
        <Route path="kallor/:id" element={<NeedsRead><SourcePage /></NeedsRead>} />
        <Route path="rapporter" element={<NeedsRead><IntelReportsPage /></NeedsRead>} />
        <Route path="rapporter/:id" element={<NeedsRead><IntelReportPage /></NeedsRead>} />
        <Route path="insatser" element={<MissionsPage />} />
        <Route path="insatser/:id" element={<MissionPage />} />
        <Route path="*" element={<EmptyState title={t('errors.notFound')} />} />
      </Routes>
    </>
  );
}
