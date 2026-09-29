// SPDX-License-Identifier: GPL-3.0-only
import { createI18n } from '@fredpd/ui';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

export const i18n = createI18n(
  { sv, en },
  { lang: 'sv', fallbackLang: 'en', onMissing: import.meta.env.DEV ? (key) => console.warn(`[fredpd] missing locale key ${key}`) : undefined },
);

/** Audit/log retention shown in the privacy notice (IMPLEMENTATION.md §4.5, §8.8). */
export const AUDIT_RETENTION_DAYS = 90;
