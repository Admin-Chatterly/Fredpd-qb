// SPDX-License-Identifier: GPL-3.0-only
// Segmented filter tabs (role="tablist"), the look of the Efterlysningar Aktiva/Alla switch: list filters on the
// tablet pages (Öppna/Mina/Alla, Att koppla/Alla, Källor/Rapporter/…). Controlled; ←/→ move between tabs.
import type { KeyboardEvent, ReactNode } from 'react';
import { cn } from '../cn';

export interface TabItem<T extends string> {
  id: T;
  label: ReactNode;
  /** Small count after the label (e.g. open alerts). */
  count?: number;
  disabled?: boolean;
}

export interface TabsProps<T extends string> {
  items: readonly TabItem<T>[];
  value: T;
  onChange: (id: T) => void;
  /** Accessible name of the tab list. */
  label: string;
  className?: string;
}

export function Tabs<T extends string>({ items, value, onChange, label, className }: TabsProps<T>) {
  const enabled = items.filter((i) => !i.disabled);
  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    const at = enabled.findIndex((i) => i.id === value);
    const next = enabled[(at + (e.key === 'ArrowRight' ? 1 : enabled.length - 1)) % enabled.length];
    if (next) {
      e.preventDefault();
      onChange(next.id);
    }
  };
  return (
    <div role="tablist" aria-label={label} className={cn('flex flex-wrap gap-1', className)} onKeyDown={onKeyDown}>
      {items.map((item) => {
        const selected = item.id === value;
        return (
          <button
            key={item.id}
            type="button"
            role="tab"
            aria-selected={selected}
            tabIndex={selected ? 0 : -1}
            disabled={item.disabled}
            data-tab={item.id}
            onClick={() => onChange(item.id)}
            className={cn(
              'inline-flex h-8 items-center gap-1.5 rounded-md px-3 text-sm disabled:opacity-50',
              selected ? 'bg-accent-soft text-accent-text' : 'text-muted hover:bg-raised hover:text-fg',
            )}
          >
            {item.label}
            {item.count !== undefined && <span className="rounded-sm bg-raised px-1.5 text-xs text-muted">{item.count}</span>}
          </button>
        );
      })}
    </div>
  );
}
