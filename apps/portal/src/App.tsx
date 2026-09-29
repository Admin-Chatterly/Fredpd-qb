// SPDX-License-Identifier: GPL-3.0-only
import type { ReactNode } from 'react';
import { Route, Routes } from 'react-router';
import { Button, EmptyState, Spinner, useT } from '@fredpd/ui';
import { errorLocaleKey } from './api';
import { PortalLayout } from './components/PortalLayout';
import { HomePage } from './pages/HomePage';
import { LoginPage } from './pages/LoginPage';
import { NotFoundPage } from './pages/NotFoundPage';
import { PermissionsPage } from './pages/PermissionsPage';
import { ADMIN_PERMISSIONS_PERM, hasPerm, useSession } from './session';

/** Renders the page only with the perm; otherwise the same "not found" as an unknown route. */
function RequirePerm({ perm, children }: { perm: string; children: ReactNode }) {
  const { user } = useSession();
  return hasPerm(user, perm) ? <>{children}</> : <NotFoundPage />;
}

export function App() {
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
        <Route index element={<HomePage />} />
        <Route
          path="behorigheter"
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
