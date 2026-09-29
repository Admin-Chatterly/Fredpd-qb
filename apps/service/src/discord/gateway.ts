// SPDX-License-Identifier: GPL-3.0-only
// What the service needs from the Discord gateway. src/discord/bot.ts implements it with discord.js; tests use an
// in-memory fake (test/fakes.ts), so nothing but bot.ts touches discord.js.

/** A guild member, flattened to the fields grants and officer identity use. */
export interface GatewayMember {
  id: string;
  username: string;
  /** Global display name (user-level), null when unset. */
  globalName: string | null;
  /** Server nickname, null when unset. */
  nick: string | null;
  /** User avatar hash, null for the default avatar. */
  avatar: string | null;
  /** Guild-specific avatar hash, null when unset. */
  guildAvatar: string | null;
  /** Every role the member holds, including @everyone (id = guild id). */
  roleIds: string[];
}

export interface GatewayRole {
  id: string;
  name: string;
  /** 0xRRGGBB (primary colour). */
  colour: number;
  position: number;
}

export interface DiscordGateway {
  /**
   * True once the guild, its roles and its members are cached. False again during a guild outage and whenever
   * discord.js has emptied the caches (the guild became available again after a new gateway session or an outage)
   * until they are reloaded. While false, answers would be incomplete: callers answer 503 instead.
   */
  isReady(): boolean;
  /** Member from the cache (complete after ready, kept current by gateway events), or null if not in the guild. */
  getMember(discordId: string): GatewayMember | null;
  /** Current guild roles. */
  listRoles(): GatewayRole[];
  /** Ids of the members holding a role (every member for @everyone). */
  membersWithRole(roleId: string): string[];
}

/** Events the bot forwards; implemented by the Sync orchestrator (src/discord/sync.ts). */
export interface GatewayEvents {
  /**
   * First load of the guild after the service started: import roles and have FXServer re-fetch every online player.
   * Role changes made while the service was down (crash, update, restart after onFatal) were never delivered, and
   * players who joined meanwhile only got their fredpd_grant_cache fallback.
   */
  ready(roles: GatewayRole[]): Promise<void>;
  /**
   * The guild became available again (new gateway session, or the end of a guild outage) and its member and role
   * caches were reloaded: import roles and have FXServer re-fetch every online player, since changes made meanwhile
   * were never delivered as events.
   */
  resynced(roles: GatewayRole[]): Promise<void>;
  roleUpserted(role: GatewayRole, before: GatewayRole | null): Promise<void>;
  roleDeleted(roleId: string): Promise<void>;
  memberUpdated(before: GatewayMember | null, after: GatewayMember): Promise<unknown>;
  memberRemoved(discordId: string): Promise<unknown>;
}
