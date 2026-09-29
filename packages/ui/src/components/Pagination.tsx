// SPDX-License-Identifier: GPL-3.0-only
// Previous / "Sida x av y" / next for server-paginated lists (50 per page, IMPLEMENTATION.md §4.7). Renders
// nothing when everything fits on one page.
import { cn } from '../cn';
import { useT } from '../i18n';
import { Button } from './Button';

export interface PaginationProps {
  /** 1-based. */
  page: number;
  total: number;
  pageSize: number;
  onPageChange: (page: number) => void;
  /** Disables both buttons (e.g. while the next page loads). */
  disabled?: boolean;
  className?: string;
}

export function pageCount(total: number, pageSize: number): number {
  return Math.max(1, Math.ceil(Math.max(0, total) / Math.max(1, pageSize)));
}

export function Pagination({ page, total, pageSize, onPageChange, disabled = false, className }: PaginationProps) {
  const t = useT();
  const pages = pageCount(total, pageSize);
  if (pages <= 1) return null;
  const label = t('common.page', { page, pages });
  return (
    <nav aria-label={label} className={cn('flex items-center justify-between gap-3 px-3 py-2', className)}>
      <Button size="sm" variant="ghost" disabled={disabled || page <= 1} onClick={() => onPageChange(page - 1)}>
        {t('common.previous')}
      </Button>
      <span className="text-sm text-muted">{label}</span>
      <Button size="sm" variant="ghost" disabled={disabled || page >= pages} onClick={() => onPageChange(page + 1)}>
        {t('common.next')}
      </Button>
    </nav>
  );
}
