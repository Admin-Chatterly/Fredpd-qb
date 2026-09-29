// SPDX-License-Identifier: GPL-3.0-only
// Code-splitting guards (docs/modules/ui.md "Bundle"): Cytoscape must only be reachable through dynamic imports
// (GraphView imports it with import(), and GraphView itself is React.lazy), and every section page is a lazy route,
// so neither lands in the main chunk that the first paint after `open` needs. A static import anywhere would pull
// it into the main chunk without any build error, so the sources are scanned here.
import { readFile, readdir } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '../src');

async function sources(dir: string): Promise<string[]> {
  const out: string[] = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...(await sources(path)));
    else if (/\.(ts|tsx)$/.test(entry.name)) out.push(path);
  }
  return out;
}

/** Static (value) imports of `spec`; `import type` is erased by the compiler and does not count. */
const staticImport = (spec: string) => new RegExp(`^\\s*import\\s+(?!type\\b)[^;]*?from\\s+['"]${spec}['"]`, 'm');

describe('code splitting', () => {
  it('cytoscape is only imported dynamically, and only by the graph view', async () => {
    const offenders: string[] = [];
    const dynamic: string[] = [];
    for (const file of await sources(src)) {
      const text = await readFile(file, 'utf8');
      if (staticImport('cytoscape').test(text)) offenders.push(relative(src, file));
      if (/import\(\s*['"]cytoscape['"]\s*\)/.test(text)) dynamic.push(relative(src, file));
    }
    expect(offenders).toEqual([]);
    expect(dynamic).toEqual([join('pages', 'intel', 'GraphView.tsx')]);
  });

  it('the graph view and every section page are reached only through lazy imports', async () => {
    const lazyOnly = ['GraphView', 'AlertsPage', 'CasesPage', 'CasePage', 'ReportPage', 'EvidencePage', 'ChargesPage', 'IntelSection'];
    const offenders: string[] = [];
    for (const file of await sources(src)) {
      const text = await readFile(file, 'utf8');
      for (const name of lazyOnly) {
        if (staticImport(`[./a-z]*/${name}`).test(text)) offenders.push(`${relative(src, file)} → ${name}`);
      }
    }
    expect(offenders).toEqual([]);
  });
});
