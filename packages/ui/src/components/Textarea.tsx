// SPDX-License-Identifier: GPL-3.0-only
// Multi-line field with the Input look. Its own class list (not fieldClass + overrides): fieldClass fixes h-9,
// and cn() cannot override a utility with another one for the same property.
import type { ComponentProps } from 'react';
import { cn } from '../cn';

export interface TextareaProps extends ComponentProps<'textarea'> {
  invalid?: boolean;
}

export const textareaClass = cn(
  'min-h-20 w-full rounded-md border border-line bg-canvas px-3 py-2 text-fg placeholder:text-subtle',
  'hover:border-line-strong focus:border-accent focus:outline-none',
  'disabled:opacity-50 aria-invalid:border-danger',
);

export function Textarea({ invalid, className, rows = 3, ...rest }: TextareaProps) {
  return <textarea rows={rows} aria-invalid={invalid || undefined} className={cn(textareaClass, className)} {...rest} />;
}
