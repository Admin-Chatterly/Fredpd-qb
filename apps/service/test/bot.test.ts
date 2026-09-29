// SPDX-License-Identifier: GPL-3.0-only
// src/discord/bot.ts, the discord.js adapter, driven through discord.js's own packet handlers (client.actions,
// client.ws.handlePacket) on a Client that never logs in: a GUILD_MEMBER_UPDATE that changes only user fields
// (global name, avatar) must still reach Sync as a member update with the OLD values in `before` (discord.js emits
// it as userUpdate only), updates of one member are handled in order, and whenever discord.js empties the member
// cache (the GUILD_CREATE of a new gateway session or after a guild outage) the gateway is not ready until the guild
// is reloaded, then re-syncs; a failed load, or the bot leaving the guild, is fatal. No database or network needed.
import { Client, Events, GatewayIntentBits, Status } from 'discord.js';
import type { Guild } from 'discord.js';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createDiscordBot } from '../src/discord/bot';
import type { DiscordBot } from '../src/discord/bot';
import type { GatewayEvents, GatewayMember, GatewayRole } from '../src/discord/gateway';
import { identityChanged } from '../src/discord/sync';
import { silentLogger } from '../src/log';
import { GUILD_ID } from './helpers';

const POLIS = '410000000000000001';
const ANNA = '420000000000000001';
const BOT = '499999999999999999';
const HASH_OLD = '0123456789abcdef0123456789abcdef';
const HASH_NEW = 'fedcba9876543210fedcba9876543210';
/** Role ids as the adapter reports them: discord.js always adds @everyone (id = guild id). */
const WITH_POLIS = expect.arrayContaining([GUILD_ID, POLIS]) as unknown as string[];
const ONLY_EVERYONE = [GUILD_ID];

interface RawUser { id: string; username: string; global_name: string | null; avatar: string | null; discriminator: string }
const annaUser = (over: Partial<RawUser> = {}): RawUser => ({ id: ANNA, username: 'anna_b', global_name: 'Anna Berg', avatar: HASH_OLD, discriminator: '0', ...over });
const annaMember = (over: { user?: Partial<RawUser>; nick?: string | null; roles?: string[] } = {}) => ({
  user: annaUser(over.user),
  nick: over.nick === undefined ? null : over.nick,
  avatar: null,
  roles: over.roles ?? [POLIS],
  joined_at: '2024-01-01T00:00:00.000Z',
  deaf: false,
  mute: false,
  flags: 0,
});

class RecordingEvents implements GatewayEvents {
  calls: { event: string; args: unknown[] }[] = [];
  /** When set, memberUpdated waits for it (to test ordering). */
  gate: Promise<void> | null = null;
  async ready(roles: GatewayRole[]) {
    this.calls.push({ event: 'ready', args: [roles] });
  }
  async resynced(roles: GatewayRole[]) {
    this.calls.push({ event: 'resynced', args: [roles] });
  }
  async roleUpserted(role: GatewayRole, before: GatewayRole | null) {
    this.calls.push({ event: 'roleUpserted', args: [role, before] });
  }
  async roleDeleted(roleId: string) {
    this.calls.push({ event: 'roleDeleted', args: [roleId] });
  }
  async memberUpdated(before: GatewayMember | null, after: GatewayMember) {
    this.calls.push({ event: 'memberUpdated:start', args: [before, after] });
    if (this.gate) await this.gate;
    this.calls.push({ event: 'memberUpdated', args: [before, after] });
  }
  async memberRemoved(discordId: string) {
    this.calls.push({ event: 'memberRemoved', args: [discordId] });
  }
  of(event: string) {
    return this.calls.filter((c) => c.event === event);
  }
}

const rawRoles = (polisName = 'Polis') => [
  { id: GUILD_ID, name: '@everyone', color: 0, position: 0, permissions: '0', hoist: false, managed: false, mentionable: false, flags: 0 },
  { id: POLIS, name: polisName, color: 0x3366ff, position: 5, permissions: '0', hoist: false, managed: false, mentionable: false, flags: 0 },
];
/** The bot's own member: all a GUILD_CREATE carries in `members` without the presences intent. */
const botMember = () => ({
  user: { id: BOT, username: 'fredpd', global_name: null, avatar: null, discriminator: '0', bot: true },
  nick: null, avatar: null, roles: [], joined_at: '2024-01-01T00:00:00.000Z', deaf: false, mute: false, flags: 0,
});

type Handler = { handle(data: unknown, shard?: unknown): void };
type Actions = { GuildMemberUpdate: Handler; GuildDelete: Handler; GuildRoleUpdate: Handler };

interface Harness {
  client: Client;
  bot: DiscordBot;
  events: RecordingEvents;
  actions: Actions;
  loads: number;
  onFatal: ReturnType<typeof vi.fn>;
  /** Deliver a GUILD_MEMBER_UPDATE packet the way the gateway would. */
  memberUpdate(data: ReturnType<typeof annaMember>): void;
  /** What discord.js's READY handler does to a cached guild on a new gateway session: mark it unavailable. */
  sessionReady(): void;
  /** GUILD_DELETE { unavailable: true }: a guild outage. */
  outage(): void;
  /** GUILD_CREATE of an unavailable guild: discord.js replaces roles and members (the bot only) and emits GuildAvailable. */
  guildCreate(): void;
  /** Hold every later guild load until the returned function is called. */
  holdLoads(): () => void;
}

const clients: Client[] = [];
afterEach(async () => {
  for (const c of clients.splice(0)) await c.destroy();
});

interface HarnessOptions {
  /** Guild loads from this one on (1 = the first) fail. */
  failLoadFrom?: number;
  /** Emit GuildAvailable before ClientReady, as the GUILD_CREATE of the first connect does. */
  availableBeforeReady?: boolean;
}

async function harness(opts: HarnessOptions = {}): Promise<Harness> {
  const client = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMembers] });
  clients.push(client);
  // The bot user (discord.js compares every user update against it).
  (client as unknown as { user: { id: string } }).user = { id: BOT };
  // What a GUILD_CREATE packet would put into the cache (discord.js's internal _add; with `channels`, the guild is
  // available).
  const guilds = client.guilds as unknown as { _add(data: unknown): Guild };
  const guild = guilds._add({ id: GUILD_ID, name: 'Polisen', channels: [], roles: rawRoles(), members: [annaMember(), botMember()] });
  const members = guild.members as unknown as { _add(data: unknown): unknown };
  const ws = client.ws as unknown as { handlePacket(packet: unknown, shard: unknown): boolean };
  const actions = (client as unknown as { actions: Actions }).actions;

  const onFatal = vi.fn();
  let gate: Promise<void> | null = null;
  const h = { loads: 0 } as Harness;
  const bot = createDiscordBot({
    token: 'unused',
    guildId: GUILD_ID,
    log: silentLogger,
    client,
    onFatal,
    // Like fetchGuild: the guild object discord.js keeps patching, with every member fetched into its cache.
    loadGuild: async () => {
      h.loads += 1;
      if (opts.failLoadFrom !== undefined && h.loads >= opts.failLoadFrom) throw new Error('GuildMembersTimeout');
      if (gate) await gate;
      members._add(annaMember());
      members._add(botMember());
      return guild;
    },
  });
  const events = new RecordingEvents();
  bot.attach(events);
  if (opts.availableBeforeReady) client.emit(Events.GuildAvailable, guild);
  client.emit(Events.ClientReady, client as Client<true>);
  if (opts.failLoadFrom !== 1) await vi.waitFor(() => expect(events.of('ready')).toHaveLength(1));
  return Object.assign(h, {
    client,
    bot,
    events,
    actions,
    onFatal,
    memberUpdate: (data: ReturnType<typeof annaMember>) => actions.GuildMemberUpdate.handle({ guild_id: GUILD_ID, ...data }, { status: Status.Ready }),
    sessionReady: () => void guilds._add({ id: GUILD_ID, unavailable: true }),
    outage: () => actions.GuildDelete.handle({ id: GUILD_ID, unavailable: true }),
    guildCreate: () =>
      void ws.handlePacket(
        { t: 'GUILD_CREATE', d: { id: GUILD_ID, name: 'Polisen', unavailable: false, channels: [], roles: rawRoles(), members: [botMember()] } },
        { id: 0 },
      ),
    holdLoads: () => {
      let release!: () => void;
      gate = new Promise<void>((r) => {
        release = r;
      });
      return () => {
        gate = null;
        release();
      };
    },
  });
}

describe('discord.js adapter (bot.ts)', () => {
  it('ready: loads the guild once and imports its roles', async () => {
    const h = await harness();
    expect(h.loads).toBe(1);
    expect(h.bot.isReady()).toBe(true);
    const [roles] = h.events.of('ready')[0]!.args as [GatewayRole[]];
    expect(roles.map((r) => r.id).sort()).toEqual([GUILD_ID, POLIS].sort());
    expect(h.bot.getMember(ANNA)).toMatchObject({ globalName: 'Anna Berg', nick: null, roleIds: WITH_POLIS });
  });

  it('a global display name change arrives as a member update with the old name in `before`', async () => {
    const h = await harness();
    h.memberUpdate(annaMember({ user: { global_name: 'Anna Berg-Svensson' } }));
    await vi.waitFor(() => expect(h.events.of('memberUpdated')).toHaveLength(1));
    const [before, after] = h.events.of('memberUpdated')[0]!.args as [GatewayMember, GatewayMember];
    expect(before).toMatchObject({ id: ANNA, globalName: 'Anna Berg', roleIds: WITH_POLIS });
    expect(after).toMatchObject({ id: ANNA, globalName: 'Anna Berg-Svensson', roleIds: WITH_POLIS });
    // What Sync then decides: a name change under both Discord name sources (Anna has no nickname).
    const o = { publicUrl: 'https://p.test', guildId: GUILD_ID };
    expect(identityChanged(before, after, { ...o, nameSource: 'discord_global' })).toBe(true);
    expect(identityChanged(before, after, { ...o, nameSource: 'discord_nick' })).toBe(true);
    expect(h.bot.getMember(ANNA)?.globalName).toBe('Anna Berg-Svensson');
  });

  it('a user avatar change arrives with the old avatar hash in `before`', async () => {
    const h = await harness();
    h.memberUpdate(annaMember({ user: { avatar: HASH_NEW } }));
    await vi.waitFor(() => expect(h.events.of('memberUpdated')).toHaveLength(1));
    const [before, after] = h.events.of('memberUpdated')[0]!.args as [GatewayMember, GatewayMember];
    expect(before.avatar).toBe(HASH_OLD);
    expect(after.avatar).toBe(HASH_NEW);
  });

  it('one packet changing nickname, roles and global name: every update sees the final member state', async () => {
    const h = await harness();
    h.memberUpdate(annaMember({ user: { global_name: 'Anna B-S' }, nick: 'Anna', roles: [] }));
    await vi.waitFor(() => expect(h.events.of('memberUpdated')).toHaveLength(2));
    const updates = h.events.of('memberUpdated').map((c) => c.args as [GatewayMember, GatewayMember]);
    // guildMemberUpdate (nickname + roles): old nickname and roles in `before`.
    expect(updates[0]![0]).toMatchObject({ nick: null, roleIds: WITH_POLIS });
    // userUpdate (global name): old global name in `before`; nothing half-applied reaches Sync.
    expect(updates[1]![0]).toMatchObject({ nick: 'Anna', roleIds: ONLY_EVERYONE, globalName: 'Anna Berg' });
    for (const [, after] of updates) expect(after).toMatchObject({ nick: 'Anna', roleIds: ONLY_EVERYONE, globalName: 'Anna B-S' });
  });

  it('a nickname-only change is a single member update (no user update)', async () => {
    const h = await harness();
    h.memberUpdate(annaMember({ nick: 'Anna B.' }));
    await vi.waitFor(() => expect(h.events.of('memberUpdated')).toHaveLength(1));
    await Promise.resolve();
    expect(h.events.of('memberUpdated')).toHaveLength(1);
    const [before, after] = h.events.of('memberUpdated')[0]!.args as [GatewayMember, GatewayMember];
    expect(before.nick).toBeNull();
    expect(after.nick).toBe('Anna B.');
  });

  it('updates of one member are handled one after the other', async () => {
    const h = await harness();
    let release!: () => void;
    h.events.gate = new Promise<void>((r) => {
      release = r;
    });
    h.memberUpdate(annaMember({ nick: 'Första' }));
    h.memberUpdate(annaMember({ nick: 'Andra' }));
    await vi.waitFor(() => expect(h.events.of('memberUpdated:start')).toHaveLength(1));
    // The second has not started while the first is still running.
    await new Promise((r) => setImmediate(r));
    expect(h.events.of('memberUpdated:start')).toHaveLength(1);
    h.events.gate = null;
    release();
    await vi.waitFor(() => expect(h.events.of('memberUpdated')).toHaveLength(2));
    expect(h.events.of('memberUpdated').map((c) => (c.args[1] as GatewayMember).nick)).toEqual(['Första', 'Andra']);
  });

  it('a new gateway session: not ready while discord.js has emptied the member cache; one reload, then re-synced', async () => {
    const h = await harness();
    const release = h.holdLoads();
    h.sessionReady();
    expect(h.bot.isReady()).toBe(false);
    // GUILD_CREATE (GuildAvailable), then discord.js's ShardReady for the shard, in the same tick.
    h.guildCreate();
    h.client.emit(Events.ShardReady, 0, undefined);
    // The member cache now holds only the bot: answering from it would put everyone "outside the guild".
    expect(h.bot.getMember(ANNA)).toBeNull();
    expect(h.bot.membersWithRole(POLIS)).toEqual([]);
    expect(h.bot.isReady()).toBe(false);
    await vi.waitFor(() => expect(h.loads).toBe(2));
    expect(h.bot.isReady()).toBe(false);
    // A role update while reloading is not forwarded: the re-sync imports the roles as they are after the reload.
    h.actions.GuildRoleUpdate.handle({ guild_id: GUILD_ID, role: rawRoles('Polis 2')[1] });
    release();
    await vi.waitFor(() => expect(h.events.of('resynced')).toHaveLength(1));
    expect(h.bot.isReady()).toBe(true);
    expect(h.bot.getMember(ANNA)).toMatchObject({ id: ANNA, roleIds: WITH_POLIS });
    expect(h.bot.membersWithRole(POLIS)).toEqual([ANNA]);
    const [roles] = h.events.of('resynced')[0]!.args as [GatewayRole[]];
    expect(roles.find((r) => r.id === POLIS)?.name).toBe('Polis 2');
    expect(h.events.of('roleUpserted')).toEqual([]);
    // GuildAvailable and ShardReady shared the one reload.
    await new Promise((r) => setImmediate(r));
    expect(h.loads).toBe(2);
    expect(h.events.of('resynced')).toHaveLength(1);
    expect(h.onFatal).not.toHaveBeenCalled();
  });

  it('a guild outage (GUILD_DELETE unavailable, then GUILD_CREATE; no ShardReady): not ready, reloaded, re-synced', async () => {
    const h = await harness();
    h.outage();
    expect(h.bot.isReady()).toBe(false);
    h.guildCreate();
    expect(h.bot.getMember(ANNA)).toBeNull();
    expect(h.bot.isReady()).toBe(false);
    await vi.waitFor(() => expect(h.events.of('resynced')).toHaveLength(1));
    expect(h.loads).toBe(2);
    expect(h.bot.isReady()).toBe(true);
    expect(h.bot.getMember(ANNA)).toMatchObject({ id: ANNA, roleIds: WITH_POLIS });
  });

  it('emptied again while reloading: loads once more and re-syncs once, after the last load', async () => {
    const h = await harness();
    const release = h.holdLoads();
    h.outage();
    h.guildCreate();
    await vi.waitFor(() => expect(h.loads).toBe(2));
    h.outage();
    h.guildCreate();
    release();
    await vi.waitFor(() => expect(h.events.of('resynced')).toHaveLength(1));
    expect(h.loads).toBe(3);
    expect(h.bot.isReady()).toBe(true);
    expect(h.bot.getMember(ANNA)).not.toBeNull();
    await new Promise((r) => setImmediate(r));
    expect(h.events.of('resynced')).toHaveLength(1);
  });

  it('a failed reload after the guild came back is fatal', async () => {
    const h = await harness({ failLoadFrom: 2 });
    h.outage();
    h.guildCreate();
    await vi.waitFor(() => expect(h.onFatal).toHaveBeenCalledTimes(1));
    expect(h.bot.isReady()).toBe(false);
    expect(h.events.of('resynced')).toEqual([]);
  });

  it('GuildAvailable during the first connect (before ClientReady) needs no second load', async () => {
    const h = await harness({ availableBeforeReady: true });
    await new Promise((r) => setImmediate(r));
    expect(h.loads).toBe(1);
    expect(h.bot.isReady()).toBe(true);
    expect(h.events.of('resynced')).toEqual([]);
  });

  it('ShardReady alone after ready (fallback) still reloads and re-syncs', async () => {
    const h = await harness();
    h.client.emit(Events.ShardReady, 0, undefined);
    await vi.waitFor(() => expect(h.events.of('resynced')).toHaveLength(1));
    expect(h.loads).toBe(2);
    expect(h.onFatal).not.toHaveBeenCalled();
  });

  it('the bot removed from the guild (GUILD_DELETE, not an outage) is fatal', async () => {
    const h = await harness();
    h.actions.GuildDelete.handle({ id: GUILD_ID });
    expect(h.onFatal).toHaveBeenCalledTimes(1);
    expect(h.bot.isReady()).toBe(false);
  });

  it('ShardReady before the first ready does nothing (ClientReady does the initial load)', async () => {
    const client = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMembers] });
    clients.push(client);
    const loadGuild = vi.fn();
    const bot = createDiscordBot({ token: 'unused', guildId: GUILD_ID, log: silentLogger, client, loadGuild });
    const events = new RecordingEvents();
    bot.attach(events);
    client.emit(Events.ShardReady, 0, undefined);
    await new Promise((r) => setImmediate(r));
    expect(loadGuild).not.toHaveBeenCalled();
    expect(events.calls).toEqual([]);
    expect(bot.isReady()).toBe(false);
  });

  it('a failed guild load is fatal: onFatal is called and the gateway stays not ready', async () => {
    const h = await harness({ failLoadFrom: 1 });
    await vi.waitFor(() => expect(h.onFatal).toHaveBeenCalledTimes(1));
    expect(h.bot.isReady()).toBe(false);
    expect(h.events.calls).toEqual([]);
  });
});
