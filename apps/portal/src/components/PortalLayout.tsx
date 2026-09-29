// SPDX-License-Identifier: GPL-3.0-only
import { Outlet, useHref, useLocation, useNavigate } from 'react-router';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { AppShell, IconButton, IconHome, IconKey, IconLogout, IconShield, NavItem, Sidebar, useT } from '@fredpd/ui';
import type { IconProps } from '@fredpd/ui';
import type { ComponentType } from 'react';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { apiFetch } from '../api';
import { ADMIN_PERMISSIONS_PERM, SESSION_QUERY_KEY, hasPerm, useSession } from '../session';
import type { PortalSession } from '../session';

interface PortalNavEntry {
  to: string;
  label: LocaleKey;
  icon: ComponentType<IconProps>;
  /** perm grant needed; null = every logged-in user. */
  perm: string | null;
}

export const PORTAL_NAV: readonly PortalNavEntry[] = [
  { to: '/', label: 'nav.home', icon: IconHome, perm: null },
  { to: '/behorigheter', label: 'nav.permissions', icon: IconKey, perm: ADMIN_PERMISSIONS_PERM },
];

function RouterNavItem({ entry }: { entry: PortalNavEntry }) {
  const t = useT();
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const href = useHref(entry.to);
  const Icon = entry.icon;
  const active = entry.to === '/' ? pathname === '/' : pathname === entry.to || pathname.startsWith(`${entry.to}/`);
  return <NavItem href={href} label={t(entry.label)} icon={<Icon />} active={active} onNavigate={() => void navigate(entry.to)} />;
}

const EmptyBody = { parse: () => undefined };

export function PortalLayout() {
  const t = useT();
  const { user, csrfToken } = useSession();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

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

  const sidebar = (
    <Sidebar
      brand={
        <span className="flex items-center gap-2 font-semibold">
          <IconShield className="text-accent-text" />
          {t('portal.title')}
        </span>
      }
      footer={
        <div className="flex items-center gap-2 px-1">
          <span className="min-w-0 flex-1 truncate text-sm">{user?.displayName}</span>
          <IconButton label={t('portal.logout')} icon={<IconLogout />} onClick={() => logout.mutate()} disabled={logout.isPending} />
        </div>
      }
    >
      {PORTAL_NAV.filter((e) => e.perm === null || hasPerm(user, e.perm)).map((entry) => (
        <RouterNavItem key={entry.to} entry={entry} />
      ))}
    </Sidebar>
  );

  return (
    <AppShell sidebar={sidebar} className="h-dvh">
      <div className="p-6">
        <Outlet />
      </div>
    </AppShell>
  );
}
