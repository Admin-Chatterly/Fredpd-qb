// SPDX-License-Identifier: GPL-3.0-only
// @vitest-environment node
// Regression guard: the NUI stylesheet must not give the document a dark color-scheme. FiveM shows the NUI as a
// transparent full-screen iframe inside a root page whose scheme is `normal`; when the iframe's used scheme differs,
// Chromium paints its canvas opaque, which blacks out the game even while the tablet is closed. The CSS is compiled
// with Tailwind itself (the same @import chain as the Vite build: tailwindcss, then @fredpd/ui/theme.css).
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { compile } from 'tailwindcss';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

/** Resolves a CSS @import the way Vite does: relative paths, then packages (`tailwindcss` -> its index.css). */
function resolveStylesheet(id: string, base: string): string {
  if (id.startsWith('.') || id.startsWith('/')) return join(base, id);
  const fromBase = createRequire(join(base, 'noop.js'));
  if (id === 'tailwindcss') return fromBase.resolve('tailwindcss/index.css');
  return fromBase.resolve(id);
}

/** Compiles the stylesheet; `candidates` are class names to generate utilities for (as Tailwind's scanner would). */
async function compileCss(file: string, candidates: string[] = []): Promise<string> {
  const compiler = await compile(await readFile(file, 'utf8'), {
    base: dirname(file),
    loadStylesheet: async (id, base) => {
      const path = resolveStylesheet(id, base);
      return { path, base: dirname(path), content: await readFile(path, 'utf8') };
    },
  });
  return compiler.build(candidates);
}

/** Innermost `selector { declarations }` blocks (at-rule wrappers such as @layer are skipped by construction). */
function rules(css: string): { selector: string; body: string }[] {
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ selector: (m[1] ?? '').trim(), body: m[2] ?? '' }));
}

/**
 * A selector that can reach the document element or body: `*`, html, :root, :host or body anywhere in it, bare or
 * compound (`html.dark`, `:root:not(.x)`, `:where(html)`, `* {…}`). Deliberately broad: a false positive such as
 * `body > div` only asks for a closer look, a miss blacks out the game. `#fredpd-tablet` never matches.
 */
const DOCUMENT_SELECTOR = /(^|[\s,>+~(])(\*|html|:root|:host|body)(?=[\s,.:#[()>+~]|$)/;

const colorSchemeRules = (css: string) => rules(css).filter((r) => /(^|[;\s])color-scheme\s*:/.test(r.body));

/** Attributes of the first `<tag …>` in an HTML document (enough for index.html's own html/body tags). */
function tagAttributes(html: string, tag: string): Map<string, string> {
  const open = new RegExp(`<${tag}(\\s[^>]*)?>`, 'i').exec(html)?.[1] ?? '';
  return new Map([...open.matchAll(/([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)')/g)].map((m) => [(m[1] ?? '').toLowerCase(), m[3] ?? m[4] ?? '']));
}

/** A class name as it appears in a compiled selector (`dark:scheme-dark` -> `.dark\:scheme-dark`). */
const classSelector = (name: string) => `.${name.replace(/[^\w-]/g, (c) => `\\${c}`)}`;

describe('NUI stylesheet color-scheme', () => {
  it('the root-selector guard catches compound and wildcard selectors', () => {
    for (const selector of ['html', ':root', 'body', ':host', '*', 'html.dark', ':root:not(.x)', ':where(html)', ':host(.x)', 'body[data-x]', '.a, html', '*, ::before']) {
      expect(DOCUMENT_SELECTOR.test(selector), selector).toBe(true);
    }
    for (const selector of ['#fredpd-tablet', '.somebody', '.html-x', '[data-body]', '#root', '[data-x*="y"]']) {
      expect(DOCUMENT_SELECTOR.test(selector), selector).toBe(false);
    }
  });

  it('never sets color-scheme on html, :root or body (the iframe canvas must stay transparent)', async () => {
    const css = await compileCss(join(here, '../src/index.css'));
    expect(css).toContain('--color-accent'); // the shared theme really was compiled in
    const offenders = colorSchemeRules(css).filter((r) => DOCUMENT_SELECTOR.test(r.selector));
    expect(offenders).toEqual([]);
  });

  it('keeps the tablet itself dark (form controls, scrollbars)', async () => {
    const css = await compileCss(join(here, '../src/index.css'));
    const tablet = colorSchemeRules(css).find((r) => r.selector === '#fredpd-tablet');
    expect(tablet?.body).toMatch(/color-scheme:\s*dark/);
  });

  it('index.html gives html and body no color-scheme (class, style or meta)', async () => {
    const html = await readFile(join(here, '../index.html'), 'utf8');
    expect(html).not.toMatch(/<meta[^>]+name\s*=\s*["']color-scheme["']/i);
    const classes: string[] = [];
    for (const tag of ['html', 'body']) {
      const attrs = tagAttributes(html, tag);
      expect(attrs.get('style') ?? '', `<${tag} style>`).not.toMatch(/color-scheme/i);
      classes.push(...(attrs.get('class') ?? '').split(/\s+/).filter(Boolean));
    }
    // Generate the utilities those classes stand for (e.g. Tailwind's scheme-dark) and look for a color-scheme.
    const css = await compileCss(join(here, '../src/index.css'), classes);
    const offenders = colorSchemeRules(css).filter((r) => classes.some((c) => r.selector.includes(classSelector(c))));
    expect(offenders).toEqual([]);
  });

  it('the class check sees a Tailwind scheme utility', async () => {
    const css = await compileCss(join(here, '../src/index.css'), ['scheme-dark']);
    expect(colorSchemeRules(css).some((r) => r.selector.includes(classSelector('scheme-dark')))).toBe(true);
  });

  it('the shared theme leaves color-scheme to the apps', async () => {
    const theme = await readFile(require.resolve('@fredpd/ui/theme.css'), 'utf8');
    const withoutComments = theme.replace(/\/\*[\s\S]*?\*\//g, '');
    expect(withoutComments).not.toMatch(/color-scheme\s*:/);
  });
});
