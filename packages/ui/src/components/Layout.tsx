// SPDX-License-Identifier: GPL-3.0-only
// Layout primitives shared by the tablet and the portal. They know nothing about routing: the apps pass `href`,
// `active` and `onNavigate` from their router (memory router in the NUI, browser router in the portal).
import type { ComponentProps, MouseEvent, ReactNode } from 'react';
import { cn } from '../cn';

export interface AppShellProps {
  sidebar: ReactNode;
  header?: ReactNode;
  children: ReactNode;
  className?: string;
}

/** Sidebar on the left, optional header, scrolling main area. Fills its parent. */
export function AppShell({ sidebar, header, children, className }: AppShellProps) {
  return (
    <div className={cn('flex h-full min-h-0 w-full bg-canvas text-fg', className)}>
      {sidebar}
      <div className="flex min-w-0 flex-1 flex-col">
        {header}
        <main className="min-h-0 flex-1 overflow-y-auto">{children}</main>
      </div>
    </div>
  );
}

export interface SidebarProps {
  /** Accessible name of the navigation landmark (needed only when the page has several). */
  label?: string;
  /** Top of the sidebar (logo, title). */
  brand?: ReactNode;
  /** Bottom of the sidebar (user, logout). */
  footer?: ReactNode;
  children: ReactNode;
  className?: string;
}

export function Sidebar({ label, brand, footer, children, className }: SidebarProps) {
  return (
    <aside className={cn('flex w-52 shrink-0 flex-col border-r border-line bg-surface', className)}>
      {brand && <div className="flex h-14 items-center border-b border-line px-4">{brand}</div>}
      <nav aria-label={label} className="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto p-2">
        {children}
      </nav>
      {footer && <div className="border-t border-line p-2">{footer}</div>}
    </aside>
  );
}

export const navItemClass = (active: boolean) =>
  cn(
    'flex h-9 w-full items-center gap-2.5 rounded-md px-3 text-left text-sm font-medium',
    active ? 'bg-accent-soft text-accent-text' : 'text-muted hover:bg-raised hover:text-fg',
  );

type NavItemBase = {
  label: string;
  icon?: ReactNode;
  active?: boolean;
  /** Count or dot shown on the right. */
  badge?: ReactNode;
};

export type NavItemProps =
  | (NavItemBase & { href: string; onNavigate?: () => void } & Omit<ComponentProps<'a'>, 'href' | 'children'>)
  | (NavItemBase & { href?: undefined; onNavigate?: undefined } & Omit<ComponentProps<'button'>, 'children'>);

function isPlainLeftClick(e: MouseEvent) {
  return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey;
}

/**
 * A link (with `href`, marked aria-current when active) or a button (without, e.g. a menu toggle). With
 * `onNavigate`, a plain left click is handled by the router instead of a page load.
 */
export function NavItem(props: NavItemProps) {
  const { label, icon, active = false, badge } = props;
  const body = (
    <>
      {icon && <span className="shrink-0">{icon}</span>}
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {badge !== undefined && badge !== null && <span className="text-xs text-muted">{badge}</span>}
    </>
  );
  if (props.href !== undefined) {
    const { label: _l, icon: _i, active: _a, badge: _b, onNavigate, className, onClick, ...rest } = props;
    return (
      <a
        {...rest}
        aria-current={active ? 'page' : undefined}
        className={cn(navItemClass(active), className)}
        onClick={(e) => {
          onClick?.(e);
          if (onNavigate && !e.defaultPrevented && isPlainLeftClick(e)) {
            e.preventDefault();
            onNavigate();
          }
        }}
      >
        {body}
      </a>
    );
  }
  const { label: _l, icon: _i, active: _a, badge: _b, onNavigate: _n, className, type = 'button', ...rest } = props;
  return (
    <button type={type} {...rest} className={cn(navItemClass(active), className)}>
      {body}
    </button>
  );
}

export interface PageHeaderProps {
  title: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  className?: string;
}

export function PageHeader({ title, subtitle, actions, className }: PageHeaderProps) {
  return (
    <div className={cn('flex flex-wrap items-end justify-between gap-3 pb-4', className)}>
      <div className="min-w-0">
        <h1 className="truncate text-xl font-semibold text-fg">{title}</h1>
        {subtitle && <p className="mt-0.5 text-sm text-muted">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  );
}
