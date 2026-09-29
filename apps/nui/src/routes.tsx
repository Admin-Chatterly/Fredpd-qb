// SPDX-License-Identifier: GPL-3.0-only
// Tablet routes (IMPLEMENTATION.md §5.2). Section routes are wrapped in RequirePage with their mdt_page key.
// Hem and the placeholders are eager (Hem is the first paint after open); every data page is React.lazy, its own
// chunk, loaded the first time it is visited (TabletLayout's Suspense shows a spinner meanwhile). The Nätverk graph
// (Cytoscape) is a further lazy chunk below the entity page.
import { lazy } from 'react';
import type { ReactNode } from 'react';
import { Route, Routes } from 'react-router';
import { useT } from '@fredpd/ui';
import type { MdtPageKey } from '@fredpd/ui';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { RequirePage } from './components/RequirePage';
import { TabletLayout } from './components/TabletLayout';
import { HomePage } from './pages/HomePage';
import { NotFoundPage, PlaceholderPage } from './pages/PlaceholderPage';

const SearchPage = lazy(() => import('./pages/SearchPage').then((m) => ({ default: m.SearchPage })));
const PersonPage = lazy(() => import('./pages/PersonPage').then((m) => ({ default: m.PersonPage })));
const VehiclePage = lazy(() => import('./pages/VehiclePage').then((m) => ({ default: m.VehiclePage })));
const BolosPage = lazy(() => import('./pages/BolosPage').then((m) => ({ default: m.BolosPage })));
const CommandSection = lazy(() => import('./pages/CommandPages').then((m) => ({ default: m.CommandSection })));
const AlertsPage = lazy(() => import('./pages/AlertsPage').then((m) => ({ default: m.AlertsPage })));
const CasesPage = lazy(() => import('./pages/CasesPage').then((m) => ({ default: m.CasesPage })));
const CasePage = lazy(() => import('./pages/CasePage').then((m) => ({ default: m.CasePage })));
const ReportPage = lazy(() => import('./pages/ReportPage').then((m) => ({ default: m.ReportPage })));
const EvidencePage = lazy(() => import('./pages/EvidencePage').then((m) => ({ default: m.EvidencePage })));
const ChargesPage = lazy(() => import('./pages/ChargesPage').then((m) => ({ default: m.ChargesPage })));
const IntelSection = lazy(() => import('./pages/intel/IntelSection').then((m) => ({ default: m.IntelSection })));

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
        <Route path="efterlysning" element={guard('bolos', <BolosPage />)} />
        <Route path="larm" element={guard('alerts', <AlertsPage />)} />
        <Route path="arenden" element={guard('cases', <CasesPage />)} />
        <Route path="arende/:id" element={guard('cases', <CasePage />)} />
        <Route path="rapport/:id" element={guard('cases', <ReportPage />)} />
        <Route path="bevis" element={guard('evidence', <EvidencePage />)} />
        <Route path="intel/*" element={guard('intel', <IntelSection />)} />
        <Route path="brottskatalog" element={guard('charges', <ChargesPage />)} />
        <Route path="register" element={guard('roster', <Section title="officer.roster" />)} />
        <Route path="ledning/*" element={guard('command', <CommandSection />)} />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}
