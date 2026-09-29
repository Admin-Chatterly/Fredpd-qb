// SPDX-License-Identifier: GPL-3.0-only
/** Joins class names, skipping falsy parts: cn('a', cond && 'b'). */
export function cn(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}
