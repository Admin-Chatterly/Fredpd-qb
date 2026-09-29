// SPDX-License-Identifier: GPL-3.0-only
// Portal frame: sidebar with the grant-filtered sections (the tablet's nav model without its 6-slot cap, so every
// allowed section is listed), "Begär ut allmän handling", Behörigheter (perm admin.permissions), the officer with
// "Byt karaktär" and logout; header with the tablet's search. With a picked character everything below runs inside
// the portal MDT host (transport + session), so the shared tablet pages work unchanged. The client copy of the grants
// only shapes the menus; the service and FXServer check every call.
import { Suspense } from 'react';
import type { ComponentType } from 'react';
import { Outlet, useHref, useLocation, useNavigate } from 'react-router';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { AppShell, IconButton, IconFolder, IconKey, IconLogout, IconShield, IconUsers, NavItem, Sidebar, useI18n } from '@fredpd/ui';
import type { IconProps } from '@fredpd/ui';
import type { GrantSet } from '@fredpd/types/grants';
import { apiFetch } from '../api';
import { PortalMdtHost, primaryUnit } from '../mdt/PortalHost';
import { HeaderSearch, PageSpinner, activeNavId, allowedNavEntries, canSeePage } from '../mdt/shared';
import { ADMIN_PERMISSIONS_PERM, SESSION_QUERY_KEY, hasPerm, useSession } from '../session';
import type { PortalSession } from '../session';

export interface PortalNavEntry {
  id: string;
  to: string;
  label: string;
  icon: ComponentType<IconProps>;
}

export const RELEASE_REQUEST_PATH = '/begar-ut';
export const CHARACTER_PATH = '/karaktar';
export const PERMISSIONS_PATH = '/behorigheter';

/** Sidebar entries for a user: MDT sections only with a picked character (they act as it). */
export function portalNav(
  grants: GrantSet,
  hasCharacter: boolean,
  isAdmin: boolean,
  t: (key: 'nav.home' | 'release.title' | 'nav.permissions') => string,
  label: (key: string) => string,
): PortalNavEntry[] {
  const out: PortalNavEntry[] = [];
  if (hasCharacter) {
    for (const e of allowedNavEntries(grants, primaryUnit(grants))) out.push({ id: e.id, to: e.to, label: label(e.label), icon: e.icon });
    out.push({ id: 'release', to: RELEASE_REQUEST_PATH, label: t('release.title'), icon: IconFolder });
  } else {
    out.push({ id: 'home', to: '/', label: t('nav.home'), icon: IconUsers });
  }
  if (isAdmin) out.push({ id: 'permissions', to: PERMISSIONS_PATH, label: t('nav.permissions'), icon: IconKey });
  return out;
}

function activeId(pathname: string): string | undefined {
  if (pathname === RELEASE_REQUEST_PATH) return 'release';
  if (pathname === PERMISSIONS_PATH) return 'permissions';
  return activeNavId(pathname);
}

function RouterNavItem({ entry, active }: { entry: PortalNavEntry; active: boolean }) {
  const navigate = useNavigate();
  const href = useHref(entry.to);
  const Icon = entry.icon;
  return <NavItem href={href} label={entry.label} icon={<Icon />} active={active} data-nav={entry.id} onNavigate={() => void navigate(entry.to)} />;
}

const EmptyBody = { parse: () => undefined };

export function PortalLayout() {
  const { t, tx } = useI18n();
  const { user, csrfToken } = useSession();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { pathname } = useLocation();

  const logout = useMutation({
    mutationFn: () => apiFetch('/auth/logout', { method: 'POST', csrfToken, schema: EmptyBody }),
    onSuccess: () => {
      queryClient.clear();
      queryClient.setQueryData<PortalSession>(SESSION_QUERY_KEY, { user: null, csrfToken: null });
      void navigate('/', { replace: true, state: { loggedOut: true } });
    },
    // Refused (stale CSRF token) or unreachable: re-read the session, which also brings a fresh token.
    onError: () => void queryClient.invalidateQueries({ queryKey: SESSION_QUERY_KEY }),
  });

  if (!user) return null;
  const hasCharacter = user.citizenid !== null;
  const nav = portalNav(user.grants, hasCharacter, hasPerm(user, ADMIN_PERMISSIONS_PERM), t, (key) => tx(key));
  const current = activeId(pathname);

  const sidebar = (
    <Sidebar
      className="print:hidden"
      brand={
        <span className="flex items-center gap-2 font-semibold">
          <IconShield className="text-accent-text" />
          {t('portal.title')}
        </span>
      }
      footer={
        <div className="flex items-center gap-1 px-1">
          <span className="min-w-0 flex-1 truncate text-sm">{user.displayName}</span>
          {hasCharacter && (
            <IconButton label={t('portal.character.switch')} icon={<IconUsers />} onClick={() => void navigate(CHARACTER_PATH)} data-switch-character />
          )}
          <IconButton label={t('portal.logout')} icon={<IconLogout />} onClick={() => logout.mutate()} disabled={logout.isPending} />
        </div>
      }
    >
      {nav.map((entry) => (
        <RouterNavItem key={entry.id} entry={entry} active={entry.id === current} />
      ))}
    </Sidebar>
  );

  const header =
    hasCharacter && canSeePage(user.grants, 'search') ? (
      <header className="flex h-14 shrink-0 items-center gap-3 border-b border-line bg-surface px-4 print:hidden" data-print-hide>
        <HeaderSearch />
      </header>
    ) : undefined;

  const shell = (
    <AppShell sidebar={sidebar} header={header} className="h-dvh print:h-auto">
      <div className="p-6 print:p-0">
        <Suspense fallback={<PageSpinner />}>
          <Outlet />
        </Suspense>
      </div>
    </AppShell>
  );
  return hasCharacter ? <PortalMdtHost>{shell}</PortalMdtHost> : shell;
}
