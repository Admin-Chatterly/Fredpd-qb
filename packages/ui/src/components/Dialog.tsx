// SPDX-License-Identifier: GPL-3.0-only
// Modal dialog. By default it covers the nearest positioned ancestor (`absolute`): in the tablet that is the
// tablet frame, so the dialog never spills over the game around it. The portal can pass `position="fixed"`.
// Esc is not handled here: in the tablet Esc always closes the tablet (IMPLEMENTATION.md §5.2). Clicking the
// backdrop or the close button calls onClose. Focus moves into the dialog on open and back when it closes.
import { useEffect, useId, useRef } from 'react';
import type { ReactNode } from 'react';
import { cn } from '../cn';
import { useT } from '../i18n';
import { IconClose } from '../icons';
import { IconButton } from './IconButton';

export type DialogSize = 'md' | 'lg';

export interface DialogProps {
  open: boolean;
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  /** Buttons, right-aligned under the body. */
  footer?: ReactNode;
  size?: DialogSize;
  /** `absolute` (default) covers the nearest positioned ancestor; `fixed` covers the viewport. */
  position?: 'absolute' | 'fixed';
}

const SIZES: Record<DialogSize, string> = { md: 'max-w-lg', lg: 'max-w-2xl' };
const FOCUSABLE = '[data-autofocus], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled])';

export function Dialog({ open, title, onClose, children, footer, size = 'md', position = 'absolute' }: DialogProps) {
  const t = useT();
  const titleId = useId();
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const panel = panelRef.current;
    // The first field (or button) of the body; the header close button comes last in this search.
    const body = panel?.querySelector<HTMLElement>('[data-dialog-body]');
    const target = body?.querySelector<HTMLElement>(FOCUSABLE) ?? panel;
    target?.focus();
    return () => previous?.focus();
  }, [open]);

  if (!open) return null;
  return (
    <div
      className={cn(position === 'fixed' ? 'fixed' : 'absolute', 'inset-0 z-50 flex items-center justify-center bg-black/60 p-4')}
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
        className={cn('flex max-h-full w-full flex-col rounded-lg border border-line bg-surface text-fg', SIZES[size])}
      >
        <header className="flex min-h-12 items-center justify-between gap-3 border-b border-line px-4 py-2">
          <h2 id={titleId} className="truncate text-base font-semibold">
            {title}
          </h2>
          <IconButton label={t('common.close')} icon={<IconClose size={16} />} size="sm" onClick={onClose} />
        </header>
        <div data-dialog-body className="min-h-0 flex-1 overflow-y-auto p-4">
          {children}
        </div>
        {footer && <footer className="flex flex-wrap justify-end gap-2 border-t border-line px-4 py-3">{footer}</footer>}
      </div>
    </div>
  );
}
