// SPDX-License-Identifier: GPL-3.0-only
// The tablet's t(): locales/*.json are bundled into the single-file build (IMPLEMENTATION.md §4.4).
import { createI18n } from '@fredpd/ui';
import { IS_DEV_BUILD } from './utils/env';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

export const i18n = createI18n(
  { sv, en },
  {
    lang: 'sv',
    fallbackLang: 'en',
    onMissing: IS_DEV_BUILD ? (key) => console.warn(`[fredpd] missing locale key ${key}`) : undefined,
  },
);
