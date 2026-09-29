// SPDX-License-Identifier: GPL-3.0-only
// Side panel for a record's details over a list (Bevis → beviskedja). Like Dialog it covers the nearest positioned
// ancestor (the tablet frame), leaves Esc to the tablet (IMPLEMENTATION.md §5.2) and gives focus back on close.
import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';
import { cn } from '../cn';
import { useT } from '../i18n';
import { IconClose } from '../icons';
import { IconButton } from './IconButton';

export interface DrawerProps {
  open: boolean;
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  className?: string;
}

export function Drawer({ open, title, onClose, children, footer, className }: DrawerProps) {
  const t = useT();
  const titleId = useId();
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    panelRef.current?.focus();
    return () => previous?.focus();
  }, [open]);

  if (!open) return null;
  return (
    <div
      className="absolute inset-0 z-40 flex justify-end bg-black/40"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        tabIndex={-1}
        className={cn('flex h-full w-full max-w-md flex-col border-l border-line bg-surface text-fg focus:outline-none', className)}
      >
        <header className="flex min-h-12 items-center justify-between gap-3 border-b border-line px-4 py-2">
          <h2 id={titleId} className="truncate text-base font-semibold">
            {title}
          </h2>
          <IconButton label={t('common.close')} icon={<IconClose size={16} />} size="sm" onClick={onClose} />
        </header>
        <div className="min-h-0 flex-1 overflow-y-auto p-4">{children}</div>
        {footer && <footer className="flex flex-wrap justify-end gap-2 border-t border-line px-4 py-3">{footer}</footer>}
      </div>
    </div>
  );
}
