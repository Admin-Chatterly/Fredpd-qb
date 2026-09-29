// SPDX-License-Identifier: GPL-3.0-only
import type { ComponentProps } from 'react';
import { cn } from '../cn';

export interface InputProps extends ComponentProps<'input'> {
  /** Marks the field invalid (red border, aria-invalid). */
  invalid?: boolean;
}

/**
 * Field look without a width, for controls that size to their content (a native <select>). Add sizes with
 * max-w-* or a wrapper rather than w-*: cn() only concatenates, and which of two w-* utilities wins depends on
 * Tailwind's stylesheet order, not on class order.
 */
export const fieldClass = cn(
  'h-9 rounded-md border border-line bg-canvas px-3 text-fg placeholder:text-subtle',
  'hover:border-line-strong focus:border-accent focus:outline-none',
  'disabled:opacity-50 aria-invalid:border-danger',
);

export const inputClass = cn(fieldClass, 'w-full');

export function Input({ invalid, className, type = 'text', ...rest }: InputProps) {
  return <input type={type} aria-invalid={invalid || undefined} className={cn(inputClass, className)} {...rest} />;
}

export interface LabelProps extends ComponentProps<'label'> {
  /** Optional hint under the label text. */
  hint?: string;
}

export function Label({ className, children, hint, ...rest }: LabelProps) {
  return (
    <label className={cn('flex flex-col gap-1.5 text-sm text-muted', className)} {...rest}>
      {children}
      {hint && <span className="text-xs text-subtle">{hint}</span>}
    </label>
  );
}
