// SPDX-License-Identifier: GPL-3.0-only
// Portal routes (task 7.1). /share/:token is public (no login). Everything else needs a session; the MDT sections
// also need a picked character (they act as it) and their `mdt_page` grant, exactly like the tablet's routes, and
// reuse the tablet's page components through the portal MDT host (components/PortalLayout.tsx). World-only actions
// are hidden by the pages in portal mode. Intel routes answer "not found" without their grant (§C15), as do
// Behörigheter without perm admin.permissions and unknown routes.
import type { ReactNode } from 'react';
import { Navigate, Route, Routes, useNavigate } from 'react-router';
import { Button, EmptyState, Spinner, useT } from '@fredpd/ui';
import type { MdtPageKey } from '@fredpd/ui';
import { errorLocaleKey } from './api';
import { CharacterPicker } from './character';
import { CHARACTER_PATH, PERMISSIONS_PATH, PortalLayout, RELEASE_REQUEST_PATH } from './components/PortalLayout';
import {
  AlertsLivePage,
  BolosPage,
  CasePage,
  CasesPage,
  ChargesPage,
  CommandSection,
  EvidencePage,
  HomePage,
  IntelSection,
  PersonPage,
  PoiPage,
  ReleaseRequestPage,
  ReportPage,
  RosterPage,
  SearchPage,
  VehiclePage,
} from './mdt/pages';
import { RequirePage, canSeePage } from './mdt/shared';
import { LoginPage } from './pages/LoginPage';
import { NotFoundPage } from './pages/NotFoundPage';
import { PermissionsPage } from './pages/PermissionsPage';
import { SharePage } from './pages/SharePage';
import { ADMIN_PERMISSIONS_PERM, hasPerm, useSession } from './session';

/** Renders the page only with the perm; otherwise the same "not found" as an unknown route. */
function RequirePerm({ perm, children }: { perm: string; children: ReactNode }) {
  const { user } = useSession();
  return hasPerm(user, perm) ? <>{children}</> : <NotFoundPage />;
}

/** MDT pages act as the picked character: without one the picker shows instead. */
function NeedsCharacter({ children }: { children: ReactNode }) {
  const { user } = useSession();
  return user?.citizenid ? <>{children}</> : <CharacterPicker />;
}

/** Character + `mdt_page` grant (the tablet's RequirePage; `notFound` pages answer 404 instead of 403). */
function Mdt({ page, notFound = false, children }: { page?: MdtPageKey; notFound?: boolean; children: ReactNode }) {
  const { user } = useSession();
  if (!user?.citizenid) return <CharacterPicker />;
  if (!page) return <>{children}</>;
  if (notFound && !canSeePage(user.grants, page)) return <NotFoundPage />;
  return <RequirePage page={page}>{children}</RequirePage>;
}

function SwitchCharacter() {
  const navigate = useNavigate();
  return <CharacterPicker onDone={() => void navigate('/')} />;
}

function AuthedApp() {
  const t = useT();
  const session = useSession();

  if (session.status === 'loading') {
    return (
      <div className="flex h-dvh items-center justify-center">
        <Spinner size="lg" />
      </div>
    );
  }
  if (session.status === 'error') {
    return (
      <EmptyState
        className="h-dvh"
        title={t(errorLocaleKey(session.error))}
        action={<Button onClick={session.refetch}>{t('common.retry')}</Button>}
      />
    );
  }
  if (!session.user) return <LoginPage />;

  return (
    <Routes>
      <Route element={<PortalLayout />}>
        <Route index element={<NeedsCharacter><HomePage /></NeedsCharacter>} />
        <Route path={CHARACTER_PATH.slice(1)} element={<SwitchCharacter />} />
        <Route path="sok" element={<Mdt page="search"><SearchPage /></Mdt>} />
        <Route path="person/:cid" element={<Mdt page="search"><PersonPage /></Mdt>} />
        <Route path="person/:cid/poi" element={<Mdt page="search"><PoiPage /></Mdt>} />
        <Route path="fordon/:plate" element={<Mdt page="search"><VehiclePage /></Mdt>} />
        <Route path="efterlysning" element={<Mdt page="bolos"><BolosPage /></Mdt>} />
        <Route path="larm" element={<Mdt page="alerts"><AlertsLivePage /></Mdt>} />
        <Route path="arenden" element={<Mdt page="cases"><CasesPage /></Mdt>} />
        <Route path="arende/:id" element={<Mdt page="cases"><CasePage /></Mdt>} />
        <Route path="rapport/:id" element={<Mdt page="cases"><ReportPage /></Mdt>} />
        <Route path="bevis" element={<Mdt page="evidence"><EvidencePage /></Mdt>} />
        <Route path="intel/*" element={<Mdt page="intel" notFound><IntelSection /></Mdt>} />
        <Route path="brottskatalog" element={<Mdt page="charges"><ChargesPage /></Mdt>} />
        <Route path="register" element={<Mdt page="roster"><RosterPage /></Mdt>} />
        <Route path="ledning/*" element={<Mdt page="command"><CommandSection /></Mdt>} />
        <Route path={RELEASE_REQUEST_PATH.slice(1)} element={<Mdt><ReleaseRequestPage /></Mdt>} />
        <Route
          path={PERMISSIONS_PATH.slice(1)}
          element={
            <RequirePerm perm={ADMIN_PERMISSIONS_PERM}>
              <PermissionsPage />
            </RequirePerm>
          }
        />
        <Route path="*" element={<NotFoundPage />} />
      </Route>
    </Routes>
  );
}

export function App() {
  return (
    <Routes>
      <Route path="/share/:token" element={<SharePage />} />
      <Route path="/share" element={<Navigate to="/" replace />} />
      <Route path="*" element={<AuthedApp />} />
    </Routes>
  );
}
