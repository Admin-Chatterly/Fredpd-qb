// SPDX-License-Identifier: GPL-3.0-only
// server/random.js (FiveM server JS runtime): the share-token CSPRNG export, evaluated with a mocked `exports`.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const code = readFileSync(join(here, '..', 'server', 'random.js'), 'utf8');

function load(): (n?: unknown) => string {
  const exported: Record<string, (n?: unknown) => string> = {};
  runInNewContext(code, { require: createRequire(import.meta.url), exports: (name: string, fn: (n?: unknown) => string) => { exported[name] = fn; } });
  const fn = exported.randomToken;
  if (!fn) throw new Error('randomToken not exported');
  return fn;
}

describe('fredpd_records server/random.js', () => {
  it('exports randomToken: 32 bytes as base64url (43 chars, no padding), fresh every call', () => {
    const randomToken = load();
    const seen = new Set<string>();
    for (let i = 0; i < 200; i++) {
      const token = randomToken(32);
      expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(Buffer.from(token, 'base64url')).toHaveLength(32);
      seen.add(token);
    }
    expect(seen.size).toBe(200);
  });

  it('clamps odd sizes to 32 bytes and never uses Math.random', () => {
    const randomToken = load();
    expect(randomToken('x')).toHaveLength(43);
    expect(randomToken(1)).toHaveLength(43);
    expect(randomToken(64)).toHaveLength(86);
    expect(code).not.toMatch(/Math\.random/);
    expect(code).toMatch(/nodeCrypto\.randomBytes/);
  });
});
