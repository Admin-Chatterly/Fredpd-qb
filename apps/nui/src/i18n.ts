// SPDX-License-Identifier: GPL-3.0-only
// The tablet's t(): locales/*.json are bundled into the single-file build (IMPLEMENTATION.md §4.4).
//
// Keys this app added in locales/pending/nui.json (not merged yet) are layered under the main files and read with
// tx(). The glob finds nothing once scripts/merge-pending-locales.mjs has merged and deleted the file, so the build
// keeps working and the keys then come from sv.json/en.json.
import { createI18n } from '@fredpd/ui';
import type { Messages } from '@fredpd/ui';
import { IS_DEV_BUILD } from './utils/env';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

type PendingFile = Record<string, unknown>;
const pendingFiles = import.meta.glob<PendingFile>('../../../locales/pending/nui.json', { eager: true, import: 'default' });

/** One language of the pending file(s): `{ key: { sv, en } }` → `{ key: text }` (`$comment` and the like skipped). */
export function pendingMessages(files: Readonly<Record<string, PendingFile>>, lang: string): Messages {
  const out: Record<string, string> = {};
  for (const file of Object.values(files)) {
    for (const [key, value] of Object.entries(file)) {
      if (key.startsWith('$') || typeof value !== 'object' || value === null) continue;
      const text = (value as Record<string, unknown>)[lang];
      if (typeof text === 'string') out[key] = text;
    }
  }
  return out;
}

export const i18n = createI18n(
  {
    sv: { ...pendingMessages(pendingFiles, 'sv'), ...sv },
    en: { ...pendingMessages(pendingFiles, 'en'), ...en },
  },
  {
    lang: 'sv',
    fallbackLang: 'en',
    onMissing: IS_DEV_BUILD ? (key) => console.warn(`[fredpd] missing locale key ${key}`) : undefined,
  },
);
