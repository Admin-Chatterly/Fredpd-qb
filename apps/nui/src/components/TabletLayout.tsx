// SPDX-License-Identifier: GPL-3.0-only
// Tablet frame: sidebar with the grant-filtered navigation (≤ 6 items), header with search, officer and close.
// Pages other than Hem are lazy (src/routes.tsx); the Suspense boundary around the outlet shows a spinner while one
// loads, so the frame and the header never unmount.
import { Suspense, useId, useMemo, useState } from 'react';
import { Outlet, useHref, useLocation, useNavigate } from 'react-router';
import { AppShell, Badge, IconButton, IconClose, IconMenu, IconShield, NavItem, Sidebar, useI18n } from '@fredpd/ui';
import { activeNavId, buildNav, canSeePage } from '../nav';
import type { NavEntry } from '../nav';
import { useSession, useTablet } from '../tablet/TabletContext';
import { PageSpinner } from './Common';
import { HeaderSearch } from './HeaderSearch';

function RouterNavItem({ entry, active, onNavigated }: { entry: NavEntry; active: boolean; onNavigated?: () => void }) {
  const { t } = useI18n();
  const navigate = useNavigate();
  const href = useHref(entry.to);
  const Icon = entry.icon;
  return (
    <NavItem
      href={href}
      label={t(entry.label)}
      icon={<Icon />}
      active={active}
      data-nav={entry.id}
      onNavigate={() => {
        void navigate(entry.to);
        onNavigated?.();
      }}
    />
  );
}

export function TabletLayout() {
  const { t, tx } = useI18n();
  const { grants, unit, me } = useSession();
  const { requestClose } = useTablet();
  const location = useLocation();
  const menuId = useId();
  const [menuOpen, setMenuOpen] = useState(false);

  const nav = useMemo(() => buildNav(grants, unit), [grants, unit]);
  const activeId = activeNavId(location.pathname);
  const overflowActive = nav.overflow.some((e) => e.id === activeId);
  const unitLabel = unit ? tx(`unit.${unit}`, undefined, unit) : t('unit.none');

  const sidebar = (
    <Sidebar
      brand={
        <span className="flex items-center gap-2 font-semibold">
          <IconShield className="text-accent-text" />
          {t('common.police')}
        </span>
      }
      footer={<p className="truncate px-3 py-1.5 text-xs text-muted">{unitLabel}</p>}
    >
      {nav.items.map((entry) => (
        <RouterNavItem key={entry.id} entry={entry} active={entry.id === activeId} />
      ))}
      {nav.overflow.length > 0 && (
        <>
          <NavItem
            label={t('nav.menu')}
            icon={<IconMenu />}
            active={overflowActive && !menuOpen}
            aria-expanded={menuOpen}
            aria-controls={menuId}
            onClick={() => setMenuOpen((open) => !open)}
          />
          {menuOpen && (
            <div id={menuId} className="ml-3 flex flex-col gap-0.5 border-l border-line pl-2">
              {nav.overflow.map((entry) => (
                <RouterNavItem key={entry.id} entry={entry} active={entry.id === activeId} onNavigated={() => setMenuOpen(false)} />
              ))}
            </div>
          )}
        </>
      )}
    </Sidebar>
  );

  const header = (
    <header className="flex h-14 shrink-0 items-center gap-3 border-b border-line bg-surface px-4">
      {canSeePage(grants, 'search') ? (
        <HeaderSearch />
      ) : (
        <div className="flex-1" />
      )}
      <div className="ml-auto flex min-w-0 items-center gap-2">
        {me.callsign && <Badge tone="accent">{me.callsign}</Badge>}
        <span className="truncate text-sm text-fg">{me.displayName}</span>
        <IconButton label={t('tablet.close')} icon={<IconClose />} onClick={requestClose} />
      </div>
    </header>
  );

  return (
    <AppShell sidebar={sidebar} header={header}>
      <div className="p-5">
        <Suspense fallback={<PageSpinner />}>
          <Outlet />
        </Suspense>
      </div>
    </AppShell>
  );
}
