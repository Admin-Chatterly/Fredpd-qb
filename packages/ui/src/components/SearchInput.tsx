// SPDX-License-Identifier: GPL-3.0-only
// Search field with an icon, a clear button and Enter-to-submit. Controlled: the caller owns the value.
// Esc is not handled here: in the tablet, Esc always closes (IMPLEMENTATION.md §5.2).
import type { ComponentProps, KeyboardEvent } from 'react';
import { cn } from '../cn';
import { useT } from '../i18n';
import { IconClose, IconSearch } from '../icons';
import { inputClass } from './Input';

export interface SearchInputProps extends Omit<ComponentProps<'input'>, 'value' | 'onChange' | 'onSubmit' | 'type'> {
  value: string;
  onValueChange: (value: string) => void;
  /** Enter with a non-blank value. Receives the trimmed value. */
  onSubmit?: (value: string) => void;
}

export function SearchInput({ value, onValueChange, onSubmit, className, onKeyDown, ...rest }: SearchInputProps) {
  const t = useT();
  const handleKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    onKeyDown?.(e);
    if (e.defaultPrevented || e.key !== 'Enter') return;
    const trimmed = value.trim();
    if (trimmed !== '') {
      e.preventDefault();
      onSubmit?.(trimmed);
    }
  };
  return (
    <div className={cn('relative flex items-center', className)}>
      <IconSearch size={16} className="pointer-events-none absolute left-3 text-subtle" />
      <input
        type="search"
        value={value}
        onChange={(e) => onValueChange(e.target.value)}
        onKeyDown={handleKeyDown}
        className={cn(inputClass, 'pl-9 pr-9 [&::-webkit-search-cancel-button]:hidden')}
        autoComplete="off"
        spellCheck={false}
        {...rest}
      />
      {value !== '' && (
        <button
          type="button"
          aria-label={t('common.clear')}
          title={t('common.clear')}
          onClick={() => onValueChange('')}
          className="absolute right-1.5 inline-flex size-6 items-center justify-center rounded-sm text-subtle hover:bg-raised hover:text-fg"
        >
          <IconClose size={14} />
        </button>
      )}
    </div>
  );
}
