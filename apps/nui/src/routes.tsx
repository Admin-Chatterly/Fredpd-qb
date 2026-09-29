// SPDX-License-Identifier: GPL-3.0-only
// Tablet routes (IMPLEMENTATION.md §5.2). Section routes are wrapped in RequirePage with their mdt_page key.
import type { ReactNode } from 'react';
import { Route, Routes } from 'react-router';
import { useT } from '@fredpd/ui';
import type { MdtPageKey } from '@fredpd/ui';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { RequirePage } from './components/RequirePage';
import { TabletLayout } from './components/TabletLayout';
import { HomePage } from './pages/HomePage';
import { CasePage, NotFoundPage, PersonPage, PlaceholderPage, ReportPage, SearchPage, VehiclePage } from './pages/PlaceholderPage';

function Section({ title }: { title: LocaleKey }) {
  const t = useT();
  return <PlaceholderPage title={t(title)} />;
}

const guard = (page: MdtPageKey, element: ReactNode) => <RequirePage page={page}>{element}</RequirePage>;

export function TabletRoutes() {
  return (
    <Routes>
      <Route element={<TabletLayout />}>
        <Route index element={<HomePage />} />
        <Route path="sok" element={guard('search', <SearchPage />)} />
        <Route path="person/:cid" element={guard('search', <PersonPage />)} />
        <Route path="fordon/:plate" element={guard('search', <VehiclePage />)} />
        <Route path="efterlysning" element={guard('bolos', <Section title="bolo.title" />)} />
        <Route path="larm" element={guard('alerts', <Section title="alert.title" />)} />
        <Route path="arenden" element={guard('cases', <Section title="case.title" />)} />
        <Route path="arende/:id" element={guard('cases', <CasePage />)} />
        <Route path="rapport/:id" element={guard('cases', <ReportPage />)} />
        <Route path="bevis" element={guard('evidence', <Section title="evidence.title" />)} />
        <Route path="intel/*" element={guard('intel', <Section title="intel.title" />)} />
        <Route path="brottskatalog" element={guard('charges', <Section title="charge.title" />)} />
        <Route path="register" element={guard('roster', <Section title="officer.roster" />)} />
        <Route path="ledning/*" element={guard('command', <Section title="nav.command" />)} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
