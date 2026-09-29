// SPDX-License-Identifier: GPL-3.0-only
import type { ComponentProps, ReactNode } from 'react';
import { useId } from 'react';
import { cn } from '../cn';

export interface CardProps extends Omit<ComponentProps<'section'>, 'title'> {
  title?: ReactNode;
  /** Right side of the header (buttons, counts). */
  actions?: ReactNode;
  /** Default true: pads the body. Turn off for edge-to-edge tables and lists. */
  padded?: boolean;
}

export function Card({ title, actions, padded = true, className, children, ...rest }: CardProps) {
  const titleId = useId();
  return (
    <section aria-labelledby={title ? titleId : undefined} className={cn('flex min-w-0 flex-col rounded-lg border border-line bg-surface', className)} {...rest}>
      {(title || actions) && (
        <header className="flex min-h-11 items-center justify-between gap-3 border-b border-line px-4 py-2">
          {title && <h2 id={titleId} className="truncate text-sm font-semibold text-fg">{title}</h2>}
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className={cn('min-h-0 flex-1', padded && 'p-4')}>{children}</div>
    </section>
  );
}
