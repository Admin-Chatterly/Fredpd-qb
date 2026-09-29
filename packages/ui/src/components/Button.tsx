// SPDX-License-Identifier: GPL-3.0-only
import type { ComponentProps, ReactNode } from 'react';
import { cn } from '../cn';
import { Spinner } from './Spinner';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';
export type ButtonSize = 'sm' | 'md';

export interface ButtonProps extends ComponentProps<'button'> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Shows a spinner, sets aria-busy and disables the button. */
  loading?: boolean;
  /** Leading icon. */
  icon?: ReactNode;
}

const VARIANTS: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-accent-fg hover:bg-accent-strong',
  secondary: 'bg-raised text-fg border border-line hover:border-line-strong',
  ghost: 'text-muted hover:bg-raised hover:text-fg',
  danger: 'bg-danger/15 text-danger border border-danger/40 hover:bg-danger/25',
};

/** `text`: label (and optional icon) with horizontal padding. `icon`: a square with no padding (IconButton). */
export type ButtonShape = 'text' | 'icon';

// Separate maps rather than overrides: cn() only concatenates, and a later `px-0` does not beat `px-3.5` (Tailwind
// orders utilities in the stylesheet, not by class order), which once squeezed every icon to 7.5 px.
const SIZES: Record<ButtonShape, Record<ButtonSize, string>> = {
  text: { sm: 'h-7 px-2.5 text-sm gap-1.5', md: 'h-9 px-3.5 gap-2' },
  icon: { sm: 'size-7', md: 'size-9' },
};

/** Shared by Button, IconButton and links styled as buttons. */
export function buttonClass(variant: ButtonVariant, size: ButtonSize, className?: string, shape: ButtonShape = 'text'): string {
  return cn(
    'inline-flex shrink-0 items-center justify-center rounded-md font-medium whitespace-nowrap select-none',
    'disabled:opacity-50 disabled:pointer-events-none',
    VARIANTS[variant],
    SIZES[shape][size],
    className,
  );
}

export function Button({ variant = 'secondary', size = 'md', loading = false, icon, className, children, disabled, type = 'button', ...rest }: ButtonProps) {
  return (
    <button type={type} disabled={disabled || loading} aria-busy={loading || undefined} className={buttonClass(variant, size, className)} {...rest}>
      {loading ? <Spinner size="sm" /> : icon}
      {children}
    </button>
  );
}
