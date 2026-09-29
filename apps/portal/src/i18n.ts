// SPDX-License-Identifier: GPL-3.0-only
// The portal's t(). Like the tablet (apps/nui/src/i18n.ts), keys still waiting in locales/pending/*.json (this
// app's portal-ui.json, other modules' files) are layered under sv.json/en.json and read with tx(); once
// scripts/merge-pending-locales.mjs has merged and deleted them the glob finds nothing and nothing breaks.
import { createI18n } from '@fredpd/ui';
import { pendingMessages } from '../../nui/src/i18n';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

type PendingFile = Record<string, unknown>;
const pendingFiles = import.meta.glob<PendingFile>('../../../locales/pending/*.json', { eager: true, import: 'default' });

export const i18n = createI18n(
  {
    sv: { ...pendingMessages(pendingFiles, 'sv'), ...sv },
    en: { ...pendingMessages(pendingFiles, 'en'), ...en },
  },
  { lang: 'sv', fallbackLang: 'en', onMissing: import.meta.env.DEV ? (key) => console.warn(`[fredpd] missing locale key ${key}`) : undefined },
);

/** Audit/log retention shown in the privacy notice (IMPLEMENTATION.md §4.5, §8.8). */
export const AUDIT_RETENTION_DAYS = 90;
