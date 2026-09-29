// SPDX-License-Identifier: GPL-3.0-only
// Keyboard-navigable windowed list (role="listbox"), the interactive sibling of VirtualList: only the rows in view
// plus `overscan` are in the DOM (IMPLEMENTATION.md §4.7). The container holds the focus and points at the active
// row with aria-activedescendant, so the active row can be scrolled out of the DOM without losing the focus.
// Keys: ↑/↓ move, Home/End jump, PageUp/PageDown move by a screenful, Enter activates. A click activates the row.
// Esc is left alone: in the tablet Esc always closes the tablet. Rows have a fixed height (`rowHeight`).
import { useCallback, useEffect, useId, useRef } from 'react';
import type { KeyboardEvent, Key, ReactNode } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { cn } from '../cn';

export interface VirtualListboxProps<T> {
  items: readonly T[];
  /** Fixed row height in px. */
  rowHeight: number;
  renderItem: (item: T, index: number, active: boolean) => ReactNode;
  getKey?: (item: T, index: number) => Key;
  /** Active row (-1: none). Controlled. */
  activeIndex: number;
  onActiveIndexChange: (index: number) => void;
  /** Enter on the active row or a click on a row. Not called for disabled rows. */
  onActivate?: (item: T, index: number) => void;
  /** Rows that can be selected but not activated (announced with aria-disabled). */
  isDisabled?: (item: T) => boolean;
  /** Accessible name (required: a listbox needs one). */
  label: string;
  overscan?: number;
  /** Focus the list when it mounts. */
  autoFocus?: boolean;
  /** Give it a bounded height (h-* or max-h-*); it scrolls inside. */
  className?: string;
}

export function VirtualListbox<T>({
  items,
  rowHeight,
  renderItem,
  getKey,
  activeIndex,
  onActiveIndexChange,
  onActivate,
  isDisabled,
  label,
  overscan = 6,
  autoFocus = false,
  className,
}: VirtualListboxProps<T>) {
  const baseId = useId();
  const scrollRef = useRef<HTMLDivElement>(null);
  const estimate = useCallback(() => rowHeight, [rowHeight]);
  const getItemKey = useCallback((index: number) => (getKey ? getKey(items[index] as T, index) : index), [getKey, items]);
  // See VirtualList: the virtualizer is mutable by design, so React Compiler memoisation is not expected here.
  // eslint-disable-next-line react-hooks/incompatible-library
  const virtualizer = useVirtualizer({ count: items.length, getScrollElement: () => scrollRef.current, estimateSize: estimate, overscan, getItemKey });

  useEffect(() => {
    if (autoFocus) scrollRef.current?.focus();
  }, [autoFocus]);

  useEffect(() => {
    if (activeIndex >= 0 && activeIndex < items.length) virtualizer.scrollToIndex(activeIndex, { align: 'auto' });
  }, [activeIndex, items.length, virtualizer]);

  const optionId = (index: number) => `${baseId}-option-${index}`;
  const activate = (index: number) => {
    const item = items[index];
    if (item === undefined || isDisabled?.(item)) return;
    onActivate?.(item, index);
  };

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const last = items.length - 1;
    if (last < 0) return;
    // The viewport the virtualizer measured (the same size it windows by), one row kept for context.
    const viewport = virtualizer.scrollRect?.height ?? scrollRef.current?.clientHeight ?? 0;
    const pageRows = Math.max(1, Math.floor(viewport / rowHeight) - 1);
    const from = activeIndex < 0 ? -1 : activeIndex;
    let next: number;
    switch (e.key) {
      case 'ArrowDown':
        next = Math.min(last, from + 1);
        break;
      case 'ArrowUp':
        next = Math.max(0, from - 1);
        break;
      case 'Home':
        next = 0;
        break;
      case 'End':
        next = last;
        break;
      case 'PageDown':
        next = Math.min(last, Math.max(0, from) + pageRows);
        break;
      case 'PageUp':
        next = Math.max(0, from - pageRows);
        break;
      case 'Enter':
        if (activeIndex >= 0) {
          e.preventDefault();
          activate(activeIndex);
        }
        return;
      default:
        return;
    }
    e.preventDefault();
    onActiveIndexChange(next);
  };

  return (
    <div
      ref={scrollRef}
      role="listbox"
      tabIndex={0}
      aria-label={label}
      aria-activedescendant={activeIndex >= 0 && activeIndex < items.length ? optionId(activeIndex) : undefined}
      onKeyDown={onKeyDown}
      className={cn('relative overflow-auto overscroll-contain rounded-md focus-visible:outline-offset-0', className)}
    >
      <div role="presentation" className="relative w-full" style={{ height: virtualizer.getTotalSize() }}>
        {virtualizer.getVirtualItems().map((row) => {
          const item = items[row.index] as T;
          const active = row.index === activeIndex;
          return (
            <div
              key={row.key}
              id={optionId(row.index)}
              role="option"
              aria-selected={active}
              aria-disabled={isDisabled?.(item) || undefined}
              aria-setsize={items.length}
              aria-posinset={row.index + 1}
              data-index={row.index}
              onClick={() => {
                onActiveIndexChange(row.index);
                activate(row.index);
              }}
              className="absolute top-0 left-0 w-full"
              style={{ transform: `translateY(${row.start}px)`, height: row.size }}
            >
              {renderItem(item, row.index, active)}
            </div>
          );
        })}
      </div>
    </div>
  );
}
