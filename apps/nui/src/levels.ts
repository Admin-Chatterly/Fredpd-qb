// SPDX-License-Identifier: GPL-3.0-only
// Sekretessnivå helpers (level 0 Standard, 1 Begränsad, 2 Hemlig; docs/modules/locales.md "level" row). The labels
// themselves are LEVEL_LOCALE_KEYS in @fredpd/ui (Badge).
import type { Level } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';

export const LEVEL_HINT_KEYS: Readonly<Record<Level, LocaleKey>> = {
  0: 'level.hint.standard',
  1: 'level.hint.begransad',
  2: 'level.hint.hemlig',
};
