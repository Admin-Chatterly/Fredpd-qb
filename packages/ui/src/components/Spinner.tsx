// SPDX-License-Identifier: GPL-3.0-only
// CSS-only spinner (no JS timer). role="status" so screen readers announce the loading label.
import { cn } from '../cn';
import { useT } from '../i18n';

export interface SpinnerProps {
  size?: 'sm' | 'md' | 'lg';
  /** Accessible label; defaults to t('common.loading'). */
  label?: string;
  className?: string;
}

const SIZES = { sm: 'size-3.5 border-2', md: 'size-5 border-2', lg: 'size-8 border-[3px]' } as const;

export function Spinner({ size = 'md', label, className }: SpinnerProps) {
  const t = useT();
  return (
    <span role="status" aria-label={label ?? t('common.loading')} className={cn('inline-flex', className)}>
      <span className={cn('animate-spin rounded-full border-line-strong border-t-accent-text', SIZES[size])} />
    </span>
  );
}
