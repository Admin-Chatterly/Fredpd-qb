// SPDX-License-Identifier: GPL-3.0-only
// src/discord/sync.ts: pure helpers (display name per OFFICER_NAME_SOURCE, avatar, diffs) and the orchestration
// (role import, resync, member role change -> recompute -> /grants push, nickname or global name change ->
// fredpd_officers + /officer push)
// with a fake gateway and a fake FXServer. The orchestration tests use their own database
// (fredpd_test_service_sync) because a role import soft-deletes every role it does not see.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { hasGrant } from '@fredpd/types/grants';
import {
  avatarRef, cleanName, createSync, diffRoles, identityChanged, officerAvatarUrl, officerIdentity, portalDisplayName,
  resolveDisplayName, rolesChanged,
} from '../src/discord/sync';
import type { Sync } from '../src/discord/sync';
import type { GatewayMember } from '../src/discord/gateway';
import { silentLogger } from '../src/log';
import { FakeFx, FakeGateway, fixedClock, GUILD_ID, rows, setupTestDb } from './helpers';

const HASH = '0123456789abcdef0123456789abcdef';
const member = (over: Partial<GatewayMember> = {}): GatewayMember => ({
  id: '300000000000000001', username: 'anna_b', globalName: 'Anna Berg', nick: 'Anna B.', avatar: null, guildAvatar: null, roleIds: [], ...over,
});

describe('display name (IMPLEMENTATION.md §4.9)', () => {
  it('discord_nick: nickname, then global name, then username', () => {
    expect(resolveDisplayName(member(), 'discord_nick')).toBe('Anna B.');
    expect(resolveDisplayName(member({ nick: null }), 'discord_nick')).toBe('Anna Berg');
    expect(resolveDisplayName(member({ nick: '  ', globalName: null }), 'discord_nick')).toBe('anna_b');
  });
  it('discord_global: global name, then username (nickname ignored)', () => {
    expect(resolveDisplayName(member(), 'discord_global')).toBe('Anna Berg');
    expect(resolveDisplayName(member({ globalName: null }), 'discord_global')).toBe('anna_b');
  });
  it('character: not taken from Discord (null); the portal header still gets a Discord name', () => {
    expect(resolveDisplayName(member(), 'character')).toBeNull();
    expect(portalDisplayName(member(), 'character')).toBe('Anna B.');
  });
  it('cleans control/format characters, collapses whitespace, caps at 100 code points', () => {
    expect(cleanName('  Anna\u200b \t B.\u202e ')).toBe('Anna B.');
    expect(cleanName('\u0000\u0007')).toBeNull();
    const long = '😀'.repeat(150);
    expect([...cleanName(long)!]).toHaveLength(100);
  });
});

describe('avatar', () => {
  it('guild avatar only under discord_nick, then the user avatar, then the default avatar', () => {
    const m = member({ avatar: HASH, guildAvatar: `a_${HASH}` });
    expect(avatarRef(m, GUILD_ID, 'discord_nick')).toEqual({ key: `ga_${HASH}`, cdnUrl: `https://cdn.discordapp.com/guilds/${GUILD_ID}/users/${m.id}/avatars/a_${HASH}.png?size=128` });
    expect(avatarRef(m, GUILD_ID, 'discord_global').key).toBe(`u${HASH}`);
    const d = avatarRef(member(), GUILD_ID, 'discord_nick');
    expect(d.key).toMatch(/^d[0-5]$/);
    expect(d.cdnUrl).toMatch(/^https:\/\/cdn\.discordapp\.com\/embed\/avatars\/[0-5]\.png$/);
    // A malformed hash is never put into a URL or file name.
    expect(avatarRef(member({ avatar: '../../x' }), GUILD_ID, 'discord_nick').key).toMatch(/^d/);
  });
  it('officer avatar URL points at this service, never the CDN', () => {
    const m = member({ avatar: HASH });
    expect(officerAvatarUrl('https://p.test', m.id, avatarRef(m, GUILD_ID, 'discord_nick'))).toBe(`https://p.test/avatar/${m.id}?v=u${HASH}`);
    expect(officerIdentity(m, { publicUrl: 'https://p.test', guildId: GUILD_ID, nameSource: 'discord_nick' })).toEqual({ displayName: 'Anna B.', avatarUrl: `https://p.test/avatar/${m.id}?v=u${HASH}` });
  });
});

describe('diffs', () => {
  const o = { publicUrl: 'https://p.test', guildId: GUILD_ID, nameSource: 'discord_nick' as const };
  it('rolesChanged compares sets; unknown before counts as changed', () => {
    expect(rolesChanged(member({ roleIds: ['1', '2'] }), member({ roleIds: ['2', '1'] }))).toBe(false);
    expect(rolesChanged(member({ roleIds: ['1'] }), member({ roleIds: ['1', '2'] }))).toBe(true);
    expect(rolesChanged(null, member())).toBe(true);
  });
  it('identityChanged follows the configured name source', () => {
    expect(identityChanged(member(), member({ nick: 'Anna Berg-Svensson' }), o)).toBe(true);
    expect(identityChanged(member(), member({ nick: 'Anna Berg-Svensson' }), { ...o, nameSource: 'discord_global' })).toBe(false);
    expect(identityChanged(member(), member({ avatar: HASH }), o)).toBe(true);
    expect(identityChanged(member(), member({ roleIds: ['9'] }), o)).toBe(false);
  });
  it('diffRoles: created, updated (incl. restored), deleted', () => {
    const stored = [
      { discordRoleId: '1', name: 'A', colour: 0, position: 1, deleted: false },
      { discordRoleId: '2', name: 'B', colour: 0, position: 2, deleted: false },
      { discordRoleId: '3', name: 'C', colour: 0, position: 3, deleted: true },
      { discordRoleId: '4', name: 'D', colour: 0, position: 4, deleted: false },
    ];
    const guild = [
      { id: '1', name: 'A', colour: 0, position: 1 },
      { id: '2', name: 'B2', colour: 0, position: 2 },
      { id: '3', name: 'C', colour: 0, position: 3 },
      { id: '5', name: 'E', colour: 0xff0000, position: 5 },
    ];
    const d = diffRoles(stored, guild);
    expect(d.created.map((r) => r.id)).toEqual(['5']);
    expect(d.updated.map((r) => r.id)).toEqual(['2', '3']);
    expect(d.deleted).toEqual(['4']);
  });
});

const SYNC_DB = 'fredpd_test_service_sync';
const database = await setupTestDb('sync.test', SYNC_DB);

describe.skipIf(!database)('sync orchestration (DB)', () => {
  const gateway = new FakeGateway();
  const fx = new FakeFx();
  const clock = fixedClock();
  const changed: string[] = [];
  let sync: Sync;
  const R = { everyone: GUILD_ID, polis: '310000000000000001', insp: '310000000000000002', old: '310000000000000003' };
  const anna = '320000000000000001';

  beforeAll(async () => {
    if (!database) return;
    for (const table of ['fredpd_role_grants', 'fredpd_roles', 'fredpd_officers', 'fredpd_grant_cache', 'fredpd_audit']) {
      await database.pool.query(`DELETE FROM ${table}`);
    }
    sync = createSync({
      db: database.db, gateway, fx, clock, log: silentLogger, unitOrder: ['ledning', 'igv'],
      identity: { publicUrl: 'https://portal.example.test', guildId: GUILD_ID, nameSource: 'discord_nick' },
      onGrantsChanged: (id) => changed.push(id),
    });
  });
  afterAll(async () => {
    await database?.close();
  });
  beforeEach(() => {
    fx.calls = [];
  });

  it('ready: imports roles, soft-deletes missing ones, audits once and asks FXServer to recompute', async () => {
    await database!.pool.query("INSERT INTO fredpd_roles (discord_role_id, name, position) VALUES (?, 'Gammal', 1)", [R.old]);
    const guildRoles = [
      { id: R.everyone, name: '@everyone', colour: 0, position: 0 },
      { id: R.polis, name: 'Polis', colour: 0x3366ff, position: 5 },
      { id: R.insp, name: 'Inspektör', colour: 0, position: 8 },
    ];
    await sync.ready(guildRoles);
    const stored = await rows<{ discord_role_id: string; name: string; deleted: number; colour: number }>(database!, 'SELECT discord_role_id, name, deleted, colour FROM fredpd_roles ORDER BY discord_role_id');
    expect(stored).toEqual([
      { discord_role_id: GUILD_ID, name: '@everyone', deleted: 0, colour: 0 },
      { discord_role_id: R.polis, name: 'Polis', deleted: 0, colour: 0x3366ff },
      { discord_role_id: R.insp, name: 'Inspektör', deleted: 0, colour: 0 },
      { discord_role_id: R.old, name: 'Gammal', deleted: 1, colour: 0 },
    ]);
    expect(await rows(database!, "SELECT id FROM fredpd_audit WHERE action = 'roles.sync'")).toHaveLength(1);
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: undefined }]);

    // Same roles again (a plain import): nothing changes, no audit, no recompute.
    fx.calls = [];
    await sync.importRoles(guildRoles);
    expect(fx.calls).toEqual([]);
    expect(await rows(database!, "SELECT id FROM fredpd_audit WHERE action = 'roles.sync'")).toHaveLength(1);

    // A service restart with unchanged roles: ready still has FXServer re-fetch everyone online, since member role
    // changes made while the service was down were never pushed. No role changed, so no audit row.
    await sync.ready(guildRoles);
    expect(fx.calls).toEqual([{ kind: 'recompute', discordIds: undefined }]);
    expect(await rows(database!, "SELECT id FROM fredpd_audit WHERE action = 'roles.sync'")).toHaveLength(1);
  });

  it('member role change: recompute, write fredpd_grant_cache, push /grants to FXServer', async () => {
    await database!.pool.query("INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect) VALUES (?, 'armory', 'station', 'allow'), (?, 'unit', 'igv', 'allow'), (?, 'perm', 'rank:inspektor', 'allow')", [R.polis, R.polis, R.insp]);
    const before = gateway.addMember({ id: anna, nick: 'Anna B.', roleIds: [GUILD_ID] });
    const after = gateway.addMember({ ...before, roleIds: [GUILD_ID, R.polis, R.insp] });
    const result = await sync.memberUpdated(before, after);
    expect(result).toMatchObject({ grantsPushed: true });
    const pushes = fx.of('grants');
    expect(pushes).toHaveLength(1);
    expect(pushes[0]!.discordId).toBe(anna);
    expect(hasGrant(pushes[0]!.grants, 'armory', 'station')).toBe(true);
    expect(pushes[0]!.grants.units).toEqual(['igv']);
    expect(pushes[0]!.grants.rank).toEqual({ roleId: R.insp, key: 'inspektor' });
    expect(fx.of('officer')).toEqual([]); // name and avatar did not change
    const [cache] = await rows<{ grants: string }>(database!, 'SELECT CAST(grants AS CHAR) AS grants FROM fredpd_grant_cache WHERE discord_id = ?', [anna]);
    expect(JSON.parse(cache!.grants).grants).toEqual(pushes[0]!.grants.grants);
    expect(changed).toContain(anna);
  });

  it('nickname change: updates every fredpd_officers row of the user, audits, pushes /officer', async () => {
    await database!.pool.query("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES ('SYNC001', ?, 'FiveM-namn'), ('SYNC002', ?, 'FiveM-namn')", [anna, anna]);
    const before = gateway.getMember(anna)!;
    const after = gateway.addMember({ ...before, nick: 'Anna Berg-Svensson' });
    const result = await sync.memberUpdated(before, after);
    expect(result).toMatchObject({ grantsPushed: false, identity: { rows: 2, changed: 2, pushed: true } });
    expect(fx.of('grants')).toEqual([]);
    const pushes = fx.of('officer');
    expect(pushes).toHaveLength(1);
    expect(pushes[0]).toMatchObject({ discordId: anna, displayName: 'Anna Berg-Svensson' });
    expect(pushes[0]!.avatarUrl).toMatch(new RegExp(`^https://portal\\.example\\.test/avatar/${anna}\\?v=d[0-5]$`));
    const officers = await rows<{ display_name: string; avatar_url: string }>(database!, 'SELECT display_name, avatar_url FROM fredpd_officers WHERE discord_id = ?', [anna]);
    expect(officers.map((o) => o.display_name)).toEqual(['Anna Berg-Svensson', 'Anna Berg-Svensson']);
    expect(officers[0]!.avatar_url).toBe(pushes[0]!.avatarUrl);
    const audit = await rows<{ meta: string }>(database!, "SELECT CAST(meta AS CHAR) AS meta FROM fredpd_audit WHERE action = 'officer.identity' AND target_id = ?", [anna]);
    expect(audit).toHaveLength(1);
    expect(JSON.parse(audit[0]!.meta)).toMatchObject({ displayName: 'Anna Berg-Svensson', previous: ['FiveM-namn'] });
  });

  it('an update that changes neither roles nor identity pushes nothing', async () => {
    const m = gateway.getMember(anna)!;
    expect(await sync.memberUpdated(m, { ...m })).toMatchObject({ grantsPushed: false });
    expect(fx.calls).toEqual([]);
  });

  it('global display name change of a member without nickname: fredpd_officers + /officer push', async () => {
    const bo = '320000000000000002';
    await database!.pool.query("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES ('SYNC003', ?, 'Bo')", [bo]);
    const before = gateway.addMember({ id: bo, username: 'bo_e', globalName: 'Bo', roleIds: [GUILD_ID] });
    const after = gateway.addMember({ ...before, globalName: 'Bo Ek' });
    const result = await sync.memberUpdated(before, after);
    expect(result).toMatchObject({ grantsPushed: false, identity: { rows: 1, changed: 1, pushed: true } });
    expect(fx.of('officer')).toEqual([expect.objectContaining({ discordId: bo, displayName: 'Bo Ek' })]);
    const [row] = await rows<{ display_name: string }>(database!, 'SELECT display_name FROM fredpd_officers WHERE discord_id = ?', [bo]);
    expect(row!.display_name).toBe('Bo Ek');
  });

  it('role moved above another: recompute the holders (rank follows position)', async () => {
    await sync.roleUpserted({ id: R.polis, name: 'Polis', colour: 0x3366ff, position: 9 }, { id: R.polis, name: 'Polis', colour: 0x3366ff, position: 5 });
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: [anna] }]);
    // A rename only: stored, no recompute.
    fx.calls = [];
    await sync.roleUpserted({ id: R.polis, name: 'Polisassistent', colour: 0x3366ff, position: 9 }, null);
    expect(fx.calls).toEqual([]);
    expect((await rows<{ name: string }>(database!, 'SELECT name FROM fredpd_roles WHERE discord_role_id = ?', [R.polis]))[0]!.name).toBe('Polisassistent');
  });

  it('role deleted: soft delete (grants kept) and recompute everyone online', async () => {
    await sync.roleDeleted(R.insp);
    expect((await rows<{ deleted: number }>(database!, 'SELECT deleted FROM fredpd_roles WHERE discord_role_id = ?', [R.insp]))[0]!.deleted).toBe(1);
    expect(await rows(database!, 'SELECT id FROM fredpd_role_grants WHERE discord_role_id = ?', [R.insp])).toHaveLength(1);
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: undefined }]);
  });

  it('resynced (guild caches reloaded after a new gateway session or outage): re-imports roles and always recomputes everyone online', async () => {
    const guildRoles = [
      { id: R.everyone, name: '@everyone', colour: 0, position: 0 },
      { id: R.polis, name: 'Polisassistent', colour: 0x3366ff, position: 9 },
    ];
    await sync.resynced(guildRoles);
    // Nothing changed in fredpd_roles, but member roles may have changed while the gateway was down.
    expect(fx.calls).toEqual([{ kind: 'recompute', discordIds: undefined }]);
  });

  it('member removed from the guild: empty set pushed', async () => {
    gateway.members.delete(anna);
    await sync.memberRemoved(anna);
    const pushes = fx.of('grants');
    expect(pushes).toHaveLength(1);
    expect(pushes[0]!.grants.grants).toEqual([]);
  });

  it('FXServer down: the push fails quietly, the DB is still updated', async () => {
    fx.ok = false;
    try {
      const m = gateway.addMember({ id: anna, nick: 'Anna', roleIds: [GUILD_ID, R.polis] });
      await expect(sync.recomputeAndPush(m.id)).resolves.toMatchObject({ member: true });
      const [cache] = await rows<{ grants: string }>(database!, 'SELECT CAST(grants AS CHAR) AS grants FROM fredpd_grant_cache WHERE discord_id = ?', [anna]);
      expect(JSON.parse(cache!.grants).grants).toContain('unit:igv');
    } finally {
      fx.ok = true;
    }
  });
});
