// SPDX-License-Identifier: GPL-3.0-only
import type { ReactNode } from 'react';
import { cn } from '../cn';
import { useT } from '../i18n';

export interface EmptyStateProps {
  /** Defaults to t('common.empty'). */
  title?: ReactNode;
  description?: ReactNode;
  icon?: ReactNode;
  /** A button or link that gets the user out of the empty state. */
  action?: ReactNode;
  className?: string;
}

export function EmptyState({ title, description, icon, action, className }: EmptyStateProps) {
  const t = useT();
  return (
    <div className={cn('flex flex-col items-center justify-center gap-2 px-4 py-8 text-center', className)}>
      {icon && <div className="text-subtle">{icon}</div>}
      <p className="text-muted">{title ?? t('common.empty')}</p>
      {description && <p className="max-w-md text-sm text-subtle">{description}</p>}
      {action && <div className="mt-2">{action}</div>}
    </div>
  );
}
