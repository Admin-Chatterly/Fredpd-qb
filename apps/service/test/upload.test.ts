// SPDX-License-Identifier: GPL-3.0-only
// POST /upload: ≤ 5 MB (6 MB -> 413), type sniffed from the bytes (a text file named .png -> 415), session + CSRF of
// a user with at least one grant (portal, multipart) or HMAC (FXServer, JSON base64). Files land in a temporary
// UPLOAD_DIR.
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { UploadResponseSchema } from '@fredpd/types/actions';
import { HMAC_SIG_HEADER, HMAC_TS_HEADER, signBody } from '@fredpd/types/hmac';
import { cleanup, GUILD_ID, HMAC_SECRET, ids, loginAs, makeApp, multipartBody, PNG_1X1, rows, seedRole, setupTestDb, signedInject, testConfig } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '903';
const database = await setupTestDb('upload.test');
const nextId = ids(PREFIX);
// Only when the tests run (hooks of a skipped suite do not run, so it could not be removed).
const uploadDir = database ? mkdtempSync(join(tmpdir(), 'fredpd-upload-')) : '';

describe.skipIf(!database)('POST /upload (DB)', () => {
  let t: TestApp;
  const polisRole = nextId();
  const user = nextId();
  const civilian = nextId();
  let session: { cookie: string; csrf: string };
  let civilianSession: { cookie: string; csrf: string };

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, polisRole, 'Polis', 10, [['mdt_page', 'reports', 'allow']]);
    t = await makeApp({ database, config: testConfig({ UPLOAD_DIR: uploadDir }) });
    t.gateway.addMember({ id: user, roleIds: [GUILD_ID, polisRole] });
    t.gateway.addMember({ id: civilian, roleIds: [GUILD_ID] });
    session = await loginAs(t, database, user);
    civilianSession = await loginAs(t, database, civilian);
  });

  afterAll(async () => {
    if (!database) return;
    rmSync(uploadDir, { recursive: true, force: true });
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  const upload = async (file: Buffer, name: string, type: string, headers: Record<string, string> = {}) => {
    const { payload, contentType } = await multipartBody('file', file, name, type);
    return t.app.inject({ method: 'POST', url: '/upload', payload, headers: { 'content-type': contentType, cookie: session.cookie, 'x-csrf-token': session.csrf, ...headers } });
  };

  it('stores a PNG under a random name and records it', async () => {
    const res = await upload(PNG_1X1, 'mugshot.png', 'image/png');
    expect(res.statusCode).toBe(200);
    const body = UploadResponseSchema.parse(res.json());
    expect(body).toMatchObject({ mime: 'image/png', size: PNG_1X1.length });
    expect(body.fileName).toBe(`${body.id}.png`);
    expect(readFileSync(join(uploadDir, body.fileName)).equals(PNG_1X1)).toBe(true);
    const [row] = await rows<{ source: string; uploader_discord: string; size_bytes: number }>(database!, 'SELECT source, uploader_discord, size_bytes FROM fredpd_uploads WHERE id = ?', [body.id]);
    expect(row).toEqual({ source: 'portal', uploader_discord: user, size_bytes: PNG_1X1.length });
    const audit = await rows(database!, "SELECT id FROM fredpd_audit WHERE action = 'upload.create' AND target_id = ?", [body.id]);
    expect(audit).toHaveLength(1);
  });

  it('413 for a 6 MB file (even with a valid PNG header)', async () => {
    const big = Buffer.alloc(6 * 1024 * 1024, 0);
    PNG_1X1.copy(big);
    const res = await upload(big, 'big.png', 'image/png');
    expect(res.statusCode).toBe(413);
    expect(res.json()).toEqual({ error: 'too_large' });
  });

  it('415 for a text file renamed .png and sent as image/png', async () => {
    const res = await upload(Buffer.from('this is not an image\n'.repeat(20)), 'notes.png', 'image/png');
    expect(res.statusCode).toBe(415);
    expect(res.json()).toEqual({ error: 'unsupported_type' });
  });

  it('415 for a real image of another type (GIF)', async () => {
    const gif = Buffer.from('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7', 'base64');
    const res = await upload(gif, 'x.png', 'image/png');
    expect(res.statusCode).toBe(415);
  });

  it('401 without a session or signature, 403 without the CSRF token', async () => {
    const { payload, contentType } = await multipartBody('file', PNG_1X1, 'a.png', 'image/png');
    const anon = await t.app.inject({ method: 'POST', url: '/upload', payload, headers: { 'content-type': contentType } });
    expect(anon.statusCode).toBe(401);
    const noCsrf = await upload(PNG_1X1, 'a.png', 'image/png', { 'x-csrf-token': '' });
    expect(noCsrf.statusCode).toBe(403);
    expect(noCsrf.json()).toEqual({ error: 'csrf' });
  });

  it('403 for a guild member without any FredPD grant (officers only), 415 for a portal upload that is not multipart', async () => {
    const { payload, contentType } = await multipartBody('file', PNG_1X1, 'a.png', 'image/png');
    const res = await t.app.inject({ method: 'POST', url: '/upload', payload, headers: { 'content-type': contentType, cookie: civilianSession.cookie, 'x-csrf-token': civilianSession.csrf } });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: 'forbidden' });
    expect(await rows(database!, 'SELECT id FROM fredpd_uploads WHERE uploader_discord = ?', [civilian])).toHaveLength(0);

    const json = await t.app.inject({ method: 'POST', url: '/upload', payload: JSON.stringify({ data: PNG_1X1.toString('base64') }), headers: { 'content-type': 'application/json', cookie: session.cookie, 'x-csrf-token': session.csrf } });
    expect(json.statusCode).toBe(415);
  });

  it('HMAC path: stale, malformed or wrong signatures are refused before the body is parsed; a non-JSON body never passes', async () => {
    const now = Math.floor(t.clock.now().getTime() / 1000);
    const broken = '{"data": not json';
    // A stale timestamp: 401 from onRequest (had the body been parsed first, this would be a 400).
    const stale = await t.app.inject({ method: 'POST', url: '/upload', payload: broken, headers: { 'content-type': 'application/json', [HMAC_TS_HEADER]: String(now - 3600), [HMAC_SIG_HEADER]: signBody(HMAC_SECRET, now - 3600, broken) } });
    expect(stale.statusCode).toBe(401);
    const malformed = await t.app.inject({ method: 'POST', url: '/upload', payload: broken, headers: { 'content-type': 'application/json', [HMAC_TS_HEADER]: String(now), [HMAC_SIG_HEADER]: 'zz' } });
    expect(malformed.statusCode).toBe(401);
    // Well-formed, current headers but a wrong signature: 401 from the JSON parser, before JSON.parse (not 400).
    const forged = await t.app.inject({ method: 'POST', url: '/upload', payload: broken, headers: { 'content-type': 'application/json', [HMAC_TS_HEADER]: String(now), [HMAC_SIG_HEADER]: 'a'.repeat(64) } });
    expect(forged.statusCode).toBe(401);
    expect(forged.json()).toEqual({ error: 'unauthorized' });
    // Correctly signed broken JSON: only now is it parsed (400).
    const signedBroken = await t.app.inject({ method: 'POST', url: '/upload', payload: broken, headers: { 'content-type': 'application/json', [HMAC_TS_HEADER]: String(now), [HMAC_SIG_HEADER]: signBody(HMAC_SECRET, now, broken) } });
    expect(signedBroken.statusCode).toBe(400);
    // multipart with a signature over the empty string (what a GET is signed with): 401, not accepted.
    const { payload, contentType } = await multipartBody('file', PNG_1X1, 'a.png', 'image/png');
    const multi = await t.app.inject({ method: 'POST', url: '/upload', payload, headers: { 'content-type': contentType, [HMAC_TS_HEADER]: String(now), [HMAC_SIG_HEADER]: signBody(HMAC_SECRET, now, '') } });
    expect(multi.statusCode).toBe(401);
  });

  it('accepts a signed JSON upload from FXServer (data URI), 401 when unsigned, 413 when too large', async () => {
    const citizenid = `T${PREFIX}ABC`;
    const body = { data: `data:image/png;base64,${PNG_1X1.toString('base64')}`, citizenid };
    const res = await signedInject(t, { method: 'POST', url: '/upload', body });
    expect(res.statusCode).toBe(200);
    const parsed = UploadResponseSchema.parse(res.json());
    const [row] = await rows<{ source: string; uploader_citizenid: string }>(database!, 'SELECT source, uploader_citizenid FROM fredpd_uploads WHERE id = ?', [parsed.id]);
    expect(row).toEqual({ source: 'game', uploader_citizenid: citizenid });

    const unsigned = await t.app.inject({ method: 'POST', url: '/upload', payload: JSON.stringify(body), headers: { 'content-type': 'application/json' } });
    expect(unsigned.statusCode).toBe(401);
    const badSig = await signedInject(t, { method: 'POST', url: '/upload', body, secret: 'another-secret-0123456789abcdef-XYZ' });
    expect(badSig.statusCode).toBe(401);

    const big = Buffer.alloc(5 * 1024 * 1024 + 1, 0);
    PNG_1X1.copy(big);
    const tooBig = await signedInject(t, { method: 'POST', url: '/upload', body: { data: big.toString('base64') } });
    expect(tooBig.statusCode).toBe(413);
  });
});
