// SPDX-License-Identifier: GPL-3.0-only
// The tablet's page components, reused as they are (task 7.1): each is React.lazy, so the portal splits them the
// way the NUI does (Cytoscape stays in the graph chunk below the intel pages). They talk to the server only
// through the host's transport (./PortalHost.tsx), and hide world-only controls in portal mode.
import { lazy } from 'react';

const nui = {
  home: () => import('../../../nui/src/pages/HomePage'),
  search: () => import('../../../nui/src/pages/SearchPage'),
  person: () => import('../../../nui/src/pages/PersonPage'),
  vehicle: () => import('../../../nui/src/pages/VehiclePage'),
  bolos: () => import('../../../nui/src/pages/BolosPage'),
  cases: () => import('../../../nui/src/pages/CasesPage'),
  case: () => import('../../../nui/src/pages/CasePage'),
  report: () => import('../../../nui/src/pages/ReportPage'),
  charges: () => import('../../../nui/src/pages/ChargesPage'),
  evidence: () => import('../../../nui/src/pages/EvidencePage'),
  intel: () => import('../../../nui/src/pages/intel/IntelSection'),
  command: () => import('../../../nui/src/pages/CommandPages'),
};

export const HomePage = lazy(() => nui.home().then((m) => ({ default: m.HomePage })));
export const SearchPage = lazy(() => nui.search().then((m) => ({ default: m.SearchPage })));
export const PersonPage = lazy(() => nui.person().then((m) => ({ default: m.PersonPage })));
export const VehiclePage = lazy(() => nui.vehicle().then((m) => ({ default: m.VehiclePage })));
export const BolosPage = lazy(() => nui.bolos().then((m) => ({ default: m.BolosPage })));
export const CasesPage = lazy(() => nui.cases().then((m) => ({ default: m.CasesPage })));
export const CasePage = lazy(() => nui.case().then((m) => ({ default: m.CasePage })));
export const ReportPage = lazy(() => nui.report().then((m) => ({ default: m.ReportPage })));
export const ChargesPage = lazy(() => nui.charges().then((m) => ({ default: m.ChargesPage })));
export const EvidencePage = lazy(() => nui.evidence().then((m) => ({ default: m.EvidencePage })));
export const IntelSection = lazy(() => nui.intel().then((m) => ({ default: m.IntelSection })));
export const TabletsPage = lazy(() => nui.command().then((m) => ({ default: m.TabletsPage })));

// Portal-only pages (lazy as well).
export const AlertsLivePage = lazy(() => import('../pages/AlertsLivePage').then((m) => ({ default: m.AlertsLivePage })));
export const RosterPage = lazy(() => import('../pages/RosterPage').then((m) => ({ default: m.RosterPage })));
export const CommandSection = lazy(() => import('../pages/CommandSection').then((m) => ({ default: m.CommandSection })));
export const PoiPage = lazy(() => import('../pages/PoiPage').then((m) => ({ default: m.PoiPage })));
export const ReleaseRequestPage = lazy(() => import('../pages/ReleaseRequestPage').then((m) => ({ default: m.ReleaseRequestPage })));
