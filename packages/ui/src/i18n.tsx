// SPDX-License-Identifier: GPL-3.0-only
// t() for the NUI and the portal (docs/contracts.md §C8). Messages are the flat locales/<lang>.json objects; the apps
// import them and call createI18n(). Lookup order: current language, then the fallback language (en), then the key
// itself, so a missing string is visible instead of blank.
import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';
import type { LocaleArgs, LocaleKey } from '@fredpd/types/locale-keys';

export type Messages = Readonly<Record<string, string>>;
/** `{ sv: {...}, en: {...} }` */
export type MessageCatalog = Readonly<Record<string, Messages>>;
export type Vars = Readonly<Record<string, string | number>>;

/** Typed lookup: vars are required exactly when the key has `{placeholders}` (LocaleArgs). */
export type TFunction = <K extends LocaleKey>(key: K, ...args: LocaleArgs<K>) => string;

export interface I18n {
  readonly lang: string;
  readonly t: TFunction;
  /**
   * Untyped lookup for keys built from data (``tx(`unit.${code}`, undefined, code)``). Returns `fallback`, or the key
   * when no fallback is given, if neither language has the key.
   */
  readonly tx: (key: string, vars?: Vars, fallback?: string) => string;
  readonly has: (key: string) => boolean;
}

export interface CreateI18nOptions {
  /** Default `sv` (product language). */
  lang?: string;
  /** Default `en`. */
  fallbackLang?: string;
  /** Called once per key found in neither language (apps log it in dev builds). */
  onMissing?: (key: string) => void;
}

const PLACEHOLDER_RE = /\{([A-Za-z0-9_]+)\}/g;

/** Replaces `{name}` with `vars.name`. Placeholders without a value are left as they are. */
export function interpolate(text: string, vars?: Vars): string {
  if (!vars) return text;
  return text.replace(PLACEHOLDER_RE, (match, name: string) => (Object.hasOwn(vars, name) ? String(vars[name]) : match));
}

export function createI18n(messages: MessageCatalog, options: CreateI18nOptions = {}): I18n {
  const lang = options.lang ?? 'sv';
  const primary: Messages = messages[lang] ?? {};
  const fallback: Messages = messages[options.fallbackLang ?? 'en'] ?? {};
  const reported = new Set<string>();

  const lookup = (key: string): string | undefined => {
    if (Object.hasOwn(primary, key)) return primary[key];
    if (Object.hasOwn(fallback, key)) return fallback[key];
    return undefined;
  };

  const tx = (key: string, vars?: Vars, fallbackText?: string): string => {
    const text = lookup(key);
    if (text !== undefined) return interpolate(text, vars);
    if (options.onMissing && !reported.has(key)) {
      reported.add(key);
      options.onMissing(key);
    }
    return fallbackText ?? key;
  };

  // LocaleArgs guarantees at compile time that vars match the key; at run time both paths are the same lookup.
  const t = ((key: string, vars?: Vars) => tx(key, vars)) as TFunction;

  return { lang, t, tx, has: (key) => lookup(key) !== undefined };
}

// Without a provider, components render their keys (useful in isolated tests; the apps always wrap the tree).
const I18nContext = createContext<I18n>(createI18n({}));

export function I18nProvider({ i18n, children }: { i18n: I18n; children: ReactNode }) {
  return <I18nContext value={i18n}>{children}</I18nContext>;
}

export function useI18n(): I18n {
  return useContext(I18nContext);
}

export function useT(): TFunction {
  return useContext(I18nContext).t;
}
