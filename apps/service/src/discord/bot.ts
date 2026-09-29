// SPDX-License-Identifier: GPL-3.0-only
// discord.js gateway client (IMPLEMENTATION.md §5.9). Intents: Guilds (roles) + GuildMembers (member updates; a
// privileged intent: enable "Server Members Intent" for the bot in the Discord developer portal). The bot is a
// thin adapter: it flattens discord.js objects into GatewayMember/GatewayRole, answers DiscordGateway queries
// from its cache, and forwards events to the Sync orchestrator (src/discord/sync.ts), where the logic lives.
import { Client, Events, GatewayIntentBits } from 'discord.js';
import type { Guild, GuildMember, PartialGuildMember, PartialUser, Role, User } from 'discord.js';
import type { Logger } from '../log';
import type { DiscordGateway, GatewayEvents, GatewayMember, GatewayRole } from './gateway';

export function toGatewayMember(m: GuildMember): GatewayMember {
  return {
    id: m.id,
    username: m.user.username,
    globalName: m.user.globalName ?? null,
    nick: m.nickname ?? null,
    avatar: m.user.avatar ?? null,
    guildAvatar: m.avatar ?? null,
    roleIds: [...m.roles.cache.keys()],
  };
}

export function toGatewayRole(r: Role): GatewayRole {
  return { id: r.id, name: r.name, colour: r.colors?.primaryColor ?? r.color ?? 0, position: r.position };
}

export interface DiscordBot extends DiscordGateway {
  /** Where events go; set before start(). */
  attach(events: GatewayEvents): void;
  start(): Promise<void>;
  stop(): Promise<void>;
}

export interface DiscordBotOptions {
  token: string;
  guildId: string;
  log: Logger;
  /**
   * The bot can no longer answer correctly (the guild, its roles or its members could not be loaded, on start or
   * after the guild became available again; or the bot left the guild). main.ts exits so the service manager (NSSM)
   * restarts the process; until then isReady() is false and grant lookups answer 503.
   */
  onFatal?: (err: unknown) => void;
  /** Tests: a Client that never logs in. */
  client?: Client;
  /** Tests: how the guild caches are filled. Default: fetch the guild, all roles and all members. */
  loadGuild?: (client: Client<true>, guildId: string) => Promise<Guild>;
}

/** Fill the caches; gateway events keep them current afterwards (members need the GuildMembers intent). */
async function fetchGuild(client: Client<true>, guildId: string): Promise<Guild> {
  const g = await client.guilds.fetch(guildId);
  await g.roles.fetch();
  await g.members.fetch();
  return g;
}

export function createDiscordBot(opts: DiscordBotOptions): DiscordBot {
  const { log, guildId } = opts;
  const loadGuild = opts.loadGuild ?? fetchGuild;
  const client = opts.client ?? new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMembers] });
  let events: GatewayEvents | null = null;
  let guild: Guild | null = null;
  let ready = false;
  let failed = false;
  // Cache generations. Whenever the guild becomes available again (the GUILD_CREATE of a new gateway session, or
  // the end of a guild outage), discord.js replaces the guild's member and role caches with what that packet
  // carries: without the presences intent, only the bot's own member. Each such event bumps `wanted`; `loaded` is
  // the generation the caches were last completely loaded for. Until they match, isReady() is false (routes answer
  // 503, FXServer keeps its fredpd_grant_cache) instead of every member reading as "not in the guild".
  let wanted = 0;
  let loaded = 0;
  let reloadQueued = false;

  const fatal = (err: unknown, what: string) => {
    if (failed) return;
    failed = true;
    ready = false;
    log.error({ err, component: 'discord', guildId }, `${what} (is the bot in DISCORD_GUILD_ID and the members intent enabled?)`);
    opts.onFatal?.(err);
  };

  // Handlers for one key (a member, a role, the guild) run one after the other, so two quick updates of the same
  // member cannot write fredpd_officers / push to FXServer out of order.
  const queues = new Map<string, Promise<void>>();

  /** Run `fn` after the previous task of the same key; a failure is logged, never thrown into discord.js. */
  const enqueue = (name: string, key: string, fn: () => Promise<unknown>) => {
    const run = () =>
      fn().then(
        () => undefined,
        (err: unknown) => log.error({ err, component: 'discord', event: name }, 'Discord event handler failed'),
      );
    const next = (queues.get(key) ?? Promise.resolve()).then(run);
    queues.set(key, next);
    void next.then(() => {
      if (queues.get(key) === next) queues.delete(key);
    });
  };

  /**
   * Forward a gateway event to Sync. Dropped before the first load and while the caches are being reloaded: the
   * re-sync that follows the reload re-imports the roles and has FXServer re-fetch everyone online.
   */
  const handle = (name: string, key: string, fn: (ev: GatewayEvents) => Promise<unknown>) => {
    const ev = events;
    if (!ev || !ready || loaded !== wanted) return;
    enqueue(name, key, () => fn(ev));
  };
  const ours = (g: { id: string } | null | undefined) => g?.id === guildId;
  const guildRoles = (g: Guild) => [...g.roles.cache.values()].map(toGatewayRole);

  /** Reload the guild caches (once for any number of invalidations queued meanwhile), then re-sync. */
  const reload = (why: string) => {
    if (reloadQueued || failed) return;
    reloadQueued = true;
    enqueue(why, 'guild', async () => {
      reloadQueued = false;
      const target = wanted;
      let g: Guild;
      try {
        g = await loadGuild(client as Client<true>, guildId);
      } catch (err) {
        fatal(err, 'Discord guild could not be reloaded after it became available again');
        return;
      }
      guild = g;
      loaded = target;
      // Invalidated again while loading: the reload queued by that invalidation re-syncs.
      if (loaded !== wanted) return;
      log.info({ component: 'discord', why, members: g.members.cache.size, roles: g.roles.cache.size }, 'Discord gateway resynced');
      if (events && ready) await events.resynced(guildRoles(g));
    });
  };

  /** The guild caches were (or may have been) emptied: not ready until they are reloaded. */
  const invalidate = (why: string) => {
    if (failed) return;
    wanted += 1;
    // Before the first ready, the initial load (still to come or running) takes care of it.
    if (ready) reload(why);
  };

  client.once(Events.ClientReady, (c) => {
    // GuildAvailable also fires during the first connect (before ClientReady); only later ones need a reload.
    const target = wanted;
    loadGuild(c, guildId).then(
      (g) => {
        if (failed) return;
        guild = g;
        loaded = target;
        ready = true;
        log.info({ component: 'discord', guild: g.name, members: g.members.cache.size, roles: g.roles.cache.size }, 'Discord gateway ready');
        const ev = events;
        if (ev) enqueue('ready', 'guild', () => ev.ready(guildRoles(g)));
        // The guild became available again while it was loading: load once more (and re-sync).
        if (loaded !== wanted) reload('guildAvailable');
      },
      (err: unknown) => fatal(err, 'Discord guild could not be loaded'),
    );
  });

  // A new gateway session (READY marks every guild unavailable, then GUILD_CREATE restores it) or the end of a guild
  // outage (GUILD_DELETE {unavailable} then GUILD_CREATE; no ShardReady). Discord replays nothing that changed while
  // we were away, and discord.js has just emptied the member cache.
  client.on(Events.GuildAvailable, (g) => {
    if (ours(g)) invalidate('guildAvailable');
  });
  // After the first ready, ShardReady means a new gateway session (a resume emits ShardResume instead). discord.js
  // emits it right after our guild's GuildAvailable, in the same tick, so both share one reload; this is the fallback
  // should that ever change. A guild still unavailable here gets its GuildAvailable later.
  client.on(Events.ShardReady, () => {
    if (ready && guild?.available) invalidate('shardReady');
  });
  client.on(Events.GuildUnavailable, (g) => {
    if (ours(g)) log.warn({ component: 'discord', guildId }, 'Discord guild unavailable (outage); grant lookups answer 503 until it is back');
  });
  // Not an outage (that is GuildUnavailable): the guild was deleted or the bot was removed from it.
  client.on(Events.GuildDelete, (g) => {
    if (ours(g)) fatal(new Error('guild deleted or bot removed'), 'The bot is no longer in the Discord guild');
  });

  client.on(Events.GuildRoleCreate, (role) => {
    if (ours(role.guild)) handle('roleCreate', `role:${role.id}`, (ev) => ev.roleUpserted(toGatewayRole(role), null));
  });
  client.on(Events.GuildRoleUpdate, (before, after) => {
    if (ours(after.guild)) handle('roleUpdate', `role:${after.id}`, (ev) => ev.roleUpserted(toGatewayRole(after), toGatewayRole(before)));
  });
  client.on(Events.GuildRoleDelete, (role) => {
    if (ours(role.guild)) handle('roleDelete', `role:${role.id}`, (ev) => ev.roleDeleted(role.id));
  });

  // Nickname, guild avatar and roles. discord.js only emits this when a member-level field changed; `before` is a
  // clone that shares the (already updated) User, so user-level changes are handled by UserUpdate below.
  client.on(Events.GuildMemberUpdate, (before: GuildMember | PartialGuildMember, after: GuildMember) => {
    if (!ours(after.guild)) return;
    const old = before.partial ? null : toGatewayMember(before);
    const now = toGatewayMember(after);
    handle('guildMemberUpdate', `member:${after.id}`, (ev) => ev.memberUpdated(old, now));
  });

  // Global display name, username and user avatar. Discord sends them in GUILD_MEMBER_UPDATE, but discord.js turns
  // that part into UserUpdate only (GuildMember#equals ignores user fields). It fires BEFORE the member half of the
  // same packet is applied, so the member is read a microtask later, once that packet is fully processed; `before`
  // is then the current member with the old user fields.
  client.on(Events.UserUpdate, (oldUser: User | PartialUser, newUser: User) => {
    const prev = { username: oldUser.username ?? '', globalName: oldUser.globalName ?? null, avatar: oldUser.avatar ?? null };
    queueMicrotask(() => {
      const m = guild?.members.cache.get(newUser.id);
      if (!m) return;
      const now = toGatewayMember(m);
      handle('userUpdate', `member:${m.id}`, (ev) => ev.memberUpdated({ ...now, ...prev }, now));
    });
  });

  client.on(Events.GuildMemberRemove, (member) => {
    if (ours(member.guild)) handle('guildMemberRemove', `member:${member.id}`, (ev) => ev.memberRemoved(member.id));
  });
  client.on(Events.ShardDisconnect, () => log.warn({ component: 'discord' }, 'Discord gateway disconnected; discord.js reconnects'));
  client.on(Events.Error, (err) => log.error({ err, component: 'discord' }, 'Discord client error'));

  return {
    attach(ev) {
      events = ev;
    },
    // Available (not in an outage) and loaded since the last time discord.js emptied the caches.
    isReady: () => ready && guild?.available === true && loaded === wanted,
    getMember(discordId) {
      const m = guild?.members.cache.get(discordId);
      return m ? toGatewayMember(m) : null;
    },
    listRoles: () => (guild ? guildRoles(guild) : []),
    membersWithRole(roleId) {
      const role = guild?.roles.cache.get(roleId);
      return role ? [...role.members.keys()] : [];
    },
    async start() {
      await client.login(opts.token);
    },
    async stop() {
      ready = false;
      await client.destroy();
    },
  };
}
