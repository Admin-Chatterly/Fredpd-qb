// SPDX-License-Identifier: GPL-3.0-only
import { describe, expect, it, vi } from 'vitest';
import { createI18n, interpolate } from '../src/i18n';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

describe('interpolate', () => {
  it('replaces every named placeholder', () => {
    expect(interpolate('Hej {name}, {name}! {count} st', { name: 'Anna', count: 3 })).toBe('Hej Anna, Anna! 3 st');
  });

  it('leaves placeholders without a value and ignores inherited properties', () => {
    expect(interpolate('{a} {b} {toString}', { a: 1 })).toBe('1 {b} {toString}');
    expect(interpolate('{a}')).toBe('{a}');
  });

  it('stringifies 0 and the empty string', () => {
    expect(interpolate('[{n}][{s}]', { n: 0, s: '' })).toBe('[0][]');
  });
});

describe('createI18n', () => {
  const i18n = createI18n(
    {
      sv: { 'home.greeting': 'Hej {name}', 'common.save': 'Spara' },
      en: { 'home.greeting': 'Hello {name}', 'common.cancel': 'Cancel', 'common.results': 'Results: {count}' },
    },
    { lang: 'sv', fallbackLang: 'en' },
  );

  it('substitutes {name} in the current language', () => {
    expect(i18n.t('home.greeting', { name: 'Anna B.' })).toBe('Hej Anna B.');
    expect(i18n.t('common.save')).toBe('Spara');
  });

  it('falls back to en, then to the key', () => {
    expect(i18n.t('common.cancel')).toBe('Cancel');
    expect(i18n.t('common.results', { count: 4 })).toBe('Results: 4');
    expect(i18n.t('common.close')).toBe('common.close');
    expect(i18n.has('common.cancel')).toBe(true);
    expect(i18n.has('common.close')).toBe(false);
  });

  it('tx() resolves runtime keys and uses the given fallback for unknown ones', () => {
    expect(i18n.tx('common.save')).toBe('Spara');
    expect(i18n.tx('unit.nope', undefined, 'nope')).toBe('nope');
    expect(i18n.tx('unit.nope')).toBe('unit.nope');
  });

  it('reports each missing key once', () => {
    const onMissing = vi.fn();
    const withReport = createI18n({ sv: {} }, { onMissing });
    withReport.tx('a.b');
    withReport.tx('a.b');
    withReport.tx('a.c');
    expect(onMissing.mock.calls).toEqual([['a.b'], ['a.c']]);
  });

  it('works with the real locale files', () => {
    const real = createI18n({ sv, en });
    expect(real.lang).toBe('sv');
    expect(real.t('home.greeting', { name: 'Anna' })).toBe('Hej Anna');
    expect(real.t('visibility.notice.text', { subject: 'ABC 123', owner: 'IGV-07' })).toBe(
      'Det finns uppgifter som rör ABC 123. Kontakta IGV-07.',
    );
    const english = createI18n({ sv, en }, { lang: 'en' });
    expect(english.t('nav.home')).not.toBe('Hem');
  });
});
