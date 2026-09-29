// SPDX-License-Identifier: GPL-3.0-only
// packages/types/src/actions.ts: the shared schemas the service validates with, and the locale keys it points at.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  API_ERROR_LOCALE_KEYS, AdminRoleGrantsPutBodySchema, InternalEventSchema, InternalUploadBodySchema, LOGIN_ERROR_LOCALE_KEYS,
  MdtOpenPayloadSchema, SessionResponseSchema,
} from '@fredpd/types/actions';
import { emptyGrantSet } from '@fredpd/types/grants';
import { ROOT } from './helpers';

describe('actions schemas', () => {
  it('admin PUT body: one row per (type, key), keys per GRANT_KEY_PATTERN, at most 500 rows', () => {
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: [{ grantType: 'unit', grantKey: 'igv', effect: 'allow' }] }).success).toBe(true);
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: [
      { grantType: 'unit', grantKey: 'igv', effect: 'allow' },
      { grantType: 'unit', grantKey: 'igv', effect: 'deny' },
    ] }).success).toBe(false);
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: [{ grantType: 'unit', grantKey: 'ig v', effect: 'allow' }] }).success).toBe(false);
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: [{ grantType: 'badge', grantKey: 'x', effect: 'allow' }] }).success).toBe(false);
    const many = Array.from({ length: 501 }, (_, i) => ({ grantType: 'weapon', grantKey: `w${i}`, effect: 'allow' }));
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: many }).success).toBe(false);
  });

  it('admin PUT body: unit keys must be * or a unit code fredpd_core accepts ([A-Za-z0-9_-]{1,32})', () => {
    const unit = (grantKey: string) => AdminRoleGrantsPutBodySchema.safeParse({ grants: [{ grantType: 'unit', grantKey, effect: 'allow' }] }).success;
    expect(unit('*')).toBe(true);
    expect(unit('igv')).toBe(true);
    expect(unit('Span_2-a')).toBe(true);
    expect(unit('x'.repeat(32))).toBe(true);
    expect(unit('igv.nord')).toBe(false);
    expect(unit('igv:nord')).toBe(false);
    expect(unit('x'.repeat(33))).toBe(false);
    expect(unit('ig*')).toBe(false);
    // Other types keep the wider GRANT_KEY_PATTERN (perm rank keys contain ':').
    expect(AdminRoleGrantsPutBodySchema.safeParse({ grants: [{ grantType: 'perm', grantKey: 'rank:inspektor', effect: 'allow' }] }).success).toBe(true);
  });

  it('internal event: known type, no extra keys', () => {
    expect(InternalEventSchema.safeParse({ type: 'playerJoined', payload: { src: 1 } }).success).toBe(true);
    expect(InternalEventSchema.safeParse({ type: 'playerJoined', payload: null, extra: 1 }).success).toBe(false);
    expect(InternalUploadBodySchema.safeParse({ data: 'AAAA', grants: {} }).success).toBe(false);
  });

  it('session and MDT payload shapes', () => {
    expect(SessionResponseSchema.safeParse({ user: null, csrfToken: null }).success).toBe(true);
    const grants = emptyGrantSet();
    expect(MdtOpenPayloadSchema.safeParse({ grants, unit: 'igv', me: { citizenid: 'ABC12345', displayName: 'Anna B.', callsign: 'IGV-07' } }).success).toBe(true);
    expect(MdtOpenPayloadSchema.safeParse({ grants, unit: null, me: { citizenid: 'bad id', displayName: 'x', callsign: null } }).success).toBe(false);
    expect(MdtOpenPayloadSchema.safeParse({ grants, unit: 'igv.nord', me: { citizenid: 'ABC12345', displayName: 'x', callsign: null } }).success).toBe(false);
  });

  it('every error and login code maps to an existing locale key', () => {
    const sv = JSON.parse(readFileSync(join(ROOT, 'locales', 'sv.json'), 'utf8')) as Record<string, string>;
    for (const key of [...Object.values(API_ERROR_LOCALE_KEYS), ...Object.values(LOGIN_ERROR_LOCALE_KEYS)]) expect(sv, key).toHaveProperty([key]);
  });
});
