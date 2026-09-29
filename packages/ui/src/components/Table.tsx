// SPDX-License-Identifier: GPL-3.0-only
// Plain semantic table for short, paginated lists (≤ 50 rows per page, §4.7). Use VirtualList for long ones.
import type { Key, ReactNode } from 'react';
import { cn } from '../cn';
import { EmptyState } from './EmptyState';

export interface TableColumn<T> {
  id: string;
  header: ReactNode;
  cell: (row: T, index: number) => ReactNode;
  className?: string;
  headerClassName?: string;
}

export interface TableProps<T> {
  columns: readonly TableColumn<T>[];
  rows: readonly T[];
  getRowKey: (row: T, index: number) => Key;
  /** Makes rows clickable (also Enter/Space when focused). */
  onRowClick?: (row: T) => void;
  /** Shown instead of the body when there are no rows. Defaults to EmptyState. */
  empty?: ReactNode;
  caption?: ReactNode;
  className?: string;
}

export function Table<T>({ columns, rows, getRowKey, onRowClick, empty, caption, className }: TableProps<T>) {
  return (
    <div className={cn('min-w-0 overflow-x-auto', className)}>
      <table className="w-full border-collapse text-left text-sm">
        {caption && <caption className="sr-only">{caption}</caption>}
        <thead>
          <tr className="border-b border-line">
            {columns.map((c) => (
              <th key={c.id} scope="col" className={cn('px-3 py-2 text-xs font-medium tracking-wide text-muted uppercase', c.headerClassName)}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={columns.length}>{empty ?? <EmptyState />}</td>
            </tr>
          ) : (
            rows.map((row, i) => (
              <tr
                key={getRowKey(row, i)}
                className={cn('border-b border-line last:border-b-0', onRowClick && 'cursor-pointer hover:bg-raised focus-visible:bg-raised')}
                tabIndex={onRowClick ? 0 : undefined}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
                onKeyDown={
                  onRowClick
                    ? (e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault();
                          onRowClick(row);
                        }
                      }
                    : undefined
                }
              >
                {columns.map((c) => (
                  <td key={c.id} className={cn('px-3 py-2 align-middle text-fg', c.className)}>
                    {c.cell(row, i)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
