// SPDX-License-Identifier: GPL-3.0-only
// Small status label. `level` renders the classification of a record (sekretessnivå 0 standard, 1 begränsad,
// 2 hemlig; docs/modules/locales.md "level" row).
import type { ReactNode } from 'react';
import type { IntelTier } from '@fredpd/types/grants';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { cn } from '../cn';
import { useT } from '../i18n';

export type BadgeTone = 'neutral' | 'accent' | 'success' | 'warning' | 'danger';

export const LEVEL_LOCALE_KEYS = {
  0: 'level.standard',
  1: 'level.begransad',
  2: 'level.hemlig',
} as const satisfies Record<IntelTier, LocaleKey>;

export const LEVEL_TONES: Record<IntelTier, BadgeTone> = { 0: 'neutral', 1: 'warning', 2: 'danger' };

const TONES: Record<BadgeTone, string> = {
  neutral: 'border-line-strong text-muted',
  accent: 'border-accent/50 bg-accent-soft text-accent-text',
  success: 'border-success/50 bg-success/10 text-success',
  warning: 'border-warning/50 bg-warning/10 text-warning',
  danger: 'border-danger/50 bg-danger/10 text-danger',
};

export interface BadgeProps {
  tone?: BadgeTone;
  /** Classification level; sets the tone and, without children, the text. */
  level?: IntelTier;
  className?: string;
  children?: ReactNode;
}

export function Badge({ tone, level, className, children }: BadgeProps) {
  const t = useT();
  const resolvedTone = tone ?? (level !== undefined ? LEVEL_TONES[level] : 'neutral');
  const content = children ?? (level !== undefined ? t(LEVEL_LOCALE_KEYS[level]) : null);
  return (
    <span
      data-tone={resolvedTone}
      className={cn('inline-flex h-5 items-center rounded-sm border px-1.5 text-xs font-medium whitespace-nowrap', TONES[resolvedTone], className)}
    >
      {content}
    </span>
  );
}
