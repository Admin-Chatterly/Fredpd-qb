// SPDX-License-Identifier: GPL-3.0-only
import { describe, expect, it } from 'vitest';
import { signBody, verifySignature } from '../src/hmac';
import fixtures from './fixtures/hmac.fixtures.json';

describe('hmac', () => {
  for (const v of fixtures.vectors) {
    it(v.name, () => {
      const res = verifySignature({ secret: fixtures.secret, ts: v.ts, sig: v.sig, rawBody: v.rawBody, nowSeconds: v.now });
      expect(res.ok).toBe(v.ok);
      if (!res.ok) expect(res.reason).toBe(v.reason);
    });
  }
  it('signBody is deterministic hex', () => {
    expect(signBody('k'.repeat(32), 1, '')).toMatch(/^[0-9a-f]{64}$/);
  });
});
