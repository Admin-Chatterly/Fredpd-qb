// SPDX-License-Identifier: GPL-3.0-only
// Windowed list (TanStack Virtual): only the rows in view plus `overscan` are in the DOM, so 5 000 search hits
// cost the same to render as 20 (IMPLEMENTATION.md §4.7). The list scrolls inside its own container: give it a
// height through `className` (h-full in a flex column, or max-h-*).
import { useCallback, useRef } from 'react';
import type { Key, ReactNode } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { cn } from '../cn';

export interface VirtualListProps<T> {
  items: readonly T[];
  /** Row height in px, or an estimate per index when `measure` is on. */
  estimateSize: number | ((index: number) => number);
  renderItem: (item: T, index: number) => ReactNode;
  getKey?: (item: T, index: number) => Key;
  /** Rows rendered beyond the visible window on each side. Default 6. */
  overscan?: number;
  /** Measure each row after render (variable heights). Off by default: fixed rows are cheaper. */
  measure?: boolean;
  /** Accessible name of the list. */
  label?: string;
  className?: string;
}

export function VirtualList<T>({ items, estimateSize, renderItem, getKey, overscan = 6, measure = false, label, className }: VirtualListProps<T>) {
  const scrollRef = useRef<HTMLDivElement>(null);
  // Stable callbacks: virtual-core memoises its measurements on getItemKey's identity, so a fresh closure per
  // render would rebuild every row's measurement (O(items)) on each scroll-driven re-render. Scrolling re-renders
  // only this component, so the props (and these callbacks) stay the same until the parent passes new ones.
  const estimate = useCallback((index: number) => (typeof estimateSize === 'number' ? estimateSize : estimateSize(index)), [estimateSize]);
  const getItemKey = useCallback((index: number) => (getKey ? getKey(items[index] as T, index) : index), [getKey, items]);
  // useVirtualizer keeps mutable state and returns fresh functions each render; that is how the library is meant
  // to be used, so React Compiler memoisation is not expected here.
  // eslint-disable-next-line react-hooks/incompatible-library
  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: estimate,
    overscan,
    getItemKey,
  });

  return (
    <div ref={scrollRef} className={cn('relative overflow-auto overscroll-contain', className)}>
      <div role="list" aria-label={label} className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
        {virtualizer.getVirtualItems().map((row) => (
          <div
            key={row.key}
            role="listitem"
            aria-setsize={items.length}
            aria-posinset={row.index + 1}
            data-index={row.index}
            ref={measure ? virtualizer.measureElement : undefined}
            className="absolute top-0 left-0 w-full"
            style={{ transform: `translateY(${row.start}px)`, height: measure ? undefined : row.size }}
          >
            {renderItem(items[row.index] as T, row.index)}
          </div>
        ))}
      </div>
    </div>
  );
}
