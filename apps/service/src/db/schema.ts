// SPDX-License-Identifier: GPL-3.0-only
// drizzle-orm view of the fredpd_* tables the service uses. The SQL in db/migrations is the source of truth
// (001_core.sql, 009_service.sql); this file only mirrors it, and test/schema.test.ts compares every column here
// with information_schema. Never generate migrations from this file (drizzle-kit is not used for DDL).
import { sql } from 'drizzle-orm';
import {
  bigint, boolean, char, customType, datetime, index, int, mysqlEnum, mysqlTable, smallint, uniqueIndex, varchar,
} from 'drizzle-orm/mysql-core';
import { GRANT_TYPES } from '@fredpd/types/grants';

/**
 * MariaDB's JSON type is LONGTEXT + json_valid(), so mysql2 hands back a string (drizzle's json() does not parse
 * it). Writes JSON.stringify, reads JSON.parse.
 */
const jsonText = <T>(name: string) =>
  customType<{ data: T; driverData: string }>({
    dataType: () => 'json',
    toDriver: (value) => JSON.stringify(value),
    fromDriver: (value) => (typeof value === 'string' ? (JSON.parse(value) as T) : (value as T)),
  })(name);

/**
 * DATETIME holding UTC (docs/contracts.md §C7); drizzle writes a Date as its UTC "YYYY-MM-DD HH:MM:SS" text and
 * reads the text back + 'Z', so the MariaDB session zone never matters.
 */
const utc = (name: string) => datetime(name, { mode: 'date' });
/** DB-side default, as in the migrations: `(UTC_TIMESTAMP())`, never the session clock. */
const utcNow = sql`(UTC_TIMESTAMP())`;
const createdAt = () => utc('created_at').notNull().default(utcNow);
/**
 * The tables have no ON UPDATE clause (MariaDB has none in UTC), so every drizzle update() and
 * onDuplicateKeyUpdate() sets updated_at = UTC_TIMESTAMP() through $onUpdate. Raw SQL writers must set it themselves.
 */
const updatedAt = () =>
  utc('updated_at')
    .notNull()
    .default(utcNow)
    .$onUpdate(() => sql`UTC_TIMESTAMP()`);

// 001_core.sql -------------------------------------------------------------------------------------------------

export const roles = mysqlTable('fredpd_roles', {
  discordRoleId: varchar('discord_role_id', { length: 20 }).notNull().primaryKey(),
  name: varchar('name', { length: 100 }).notNull(),
  colour: int('colour', { unsigned: true }).notNull().default(0),
  position: int('position').notNull().default(0),
  deleted: boolean('deleted').notNull().default(false),
  updatedAt: updatedAt(),
  createdAt: createdAt(),
});

export const roleGrants = mysqlTable(
  'fredpd_role_grants',
  {
    id: int('id', { unsigned: true }).autoincrement().notNull().primaryKey(),
    discordRoleId: varchar('discord_role_id', { length: 20 }).notNull(),
    grantType: mysqlEnum('grant_type', GRANT_TYPES).notNull(),
    grantKey: varchar('grant_key', { length: 64 }).notNull(),
    effect: mysqlEnum('effect', ['allow', 'deny']).notNull().default('allow'),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex('uq_role_grant').on(t.discordRoleId, t.grantType, t.grantKey)],
);

export const identities = mysqlTable(
  'fredpd_identities',
  {
    discordId: varchar('discord_id', { length: 20 }).notNull().primaryKey(),
    license: varchar('license', { length: 64 }),
    lastCitizenid: varchar('last_citizenid', { length: 50 }),
    lastSeen: utc('last_seen'),
    createdAt: createdAt(),
  },
  (t) => [index('idx_license').on(t.license), index('idx_last_citizenid').on(t.lastCitizenid)],
);

export const grantCache = mysqlTable('fredpd_grant_cache', {
  discordId: varchar('discord_id', { length: 20 }).notNull().primaryKey(),
  grants: jsonText<unknown>('grants').notNull(),
  computedAt: utc('computed_at').notNull(),
  createdAt: createdAt(),
});

export const audit = mysqlTable('fredpd_audit', {
  id: bigint('id', { mode: 'number', unsigned: true }).autoincrement().notNull().primaryKey(),
  actorCitizenid: varchar('actor_citizenid', { length: 50 }),
  actorDiscord: varchar('actor_discord', { length: 20 }),
  action: varchar('action', { length: 64 }).notNull(),
  targetType: varchar('target_type', { length: 32 }),
  targetId: varchar('target_id', { length: 64 }),
  meta: jsonText<unknown>('meta'),
  createdAt: createdAt(),
});

export const units = mysqlTable('fredpd_units', {
  code: varchar('code', { length: 32 }).notNull().primaryKey(),
  callsignPrefix: varchar('callsign_prefix', { length: 8 }).notNull(),
  labelKey: varchar('label_key', { length: 64 }).notNull(),
  home: varchar('home', { length: 32 }),
  sortOrder: smallint('sort_order').notNull().default(0),
  active: boolean('active').notNull().default(true),
  updatedAt: updatedAt(),
  createdAt: createdAt(),
});

export const officers = mysqlTable(
  'fredpd_officers',
  {
    citizenid: varchar('citizenid', { length: 50 }).notNull().primaryKey(),
    discordId: varchar('discord_id', { length: 20 }).notNull(),
    displayName: varchar('display_name', { length: 100 }).notNull(),
    avatarUrl: varchar('avatar_url', { length: 255 }),
    callsign: varchar('callsign', { length: 16 }),
    unit: varchar('unit', { length: 32 }),
    rankRoleId: varchar('rank_role_id', { length: 20 }),
    updatedAt: updatedAt(),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex('uq_discord_citizen').on(t.discordId, t.citizenid), uniqueIndex('uq_unit_callsign').on(t.unit, t.callsign)],
);

// 009_service.sql ----------------------------------------------------------------------------------------------

export const sessions = mysqlTable(
  'fredpd_sessions',
  {
    id: char('id', { length: 64 }).notNull().primaryKey(),
    discordId: varchar('discord_id', { length: 20 }).notNull(),
    citizenid: varchar('citizenid', { length: 50 }),
    csrfToken: varchar('csrf_token', { length: 64 }).notNull(),
    expiresAt: utc('expires_at').notNull(),
    createdAt: createdAt(),
  },
  (t) => [index('idx_discord').on(t.discordId), index('idx_expires').on(t.expiresAt)],
);

export const uploads = mysqlTable(
  'fredpd_uploads',
  {
    id: char('id', { length: 32 }).notNull().primaryKey(),
    fileName: varchar('file_name', { length: 64 }).notNull(),
    mime: varchar('mime', { length: 32 }).notNull(),
    sizeBytes: int('size_bytes', { unsigned: true }).notNull(),
    sha256: char('sha256', { length: 64 }).notNull(),
    source: mysqlEnum('source', ['portal', 'game']).notNull(),
    uploaderDiscord: varchar('uploader_discord', { length: 20 }),
    uploaderCitizenid: varchar('uploader_citizenid', { length: 50 }),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex('uq_file_name').on(t.fileName),
    index('idx_uploader_discord').on(t.uploaderDiscord, t.createdAt),
    index('idx_uploader_citizenid').on(t.uploaderCitizenid, t.createdAt),
  ],
);

export const schema = { roles, roleGrants, identities, grantCache, audit, units, officers, sessions, uploads };
