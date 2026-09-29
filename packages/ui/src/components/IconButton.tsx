// SPDX-License-Identifier: GPL-3.0-only
import type { ComponentProps, ReactNode } from 'react';
import { buttonClass } from './Button';
import type { ButtonSize, ButtonVariant } from './Button';

export interface IconButtonProps extends Omit<ComponentProps<'button'>, 'children'> {
  /** Accessible name and tooltip (required: the button shows only an icon). */
  label: string;
  icon: ReactNode;
  variant?: ButtonVariant;
  size?: ButtonSize;
}

export function IconButton({ label, icon, variant = 'ghost', size = 'md', className, type = 'button', ...rest }: IconButtonProps) {
  return (
    <button type={type} aria-label={label} title={label} className={buttonClass(variant, size, className, 'icon')} {...rest}>
      {icon}
    </button>
  );
}
