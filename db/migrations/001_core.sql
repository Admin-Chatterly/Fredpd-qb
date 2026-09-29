-- SPDX-License-Identifier: GPL-3.0-only
-- 001_core: migration bookkeeping, permissions (IMPLEMENTATION.md §4.1), audit (§4.5), units and officers (§4.9),
-- visibility rules (docs/contracts.md §C3) and the per-type-per-year counters behind {{seq}} (§4.8).
--
-- File rules (docs/contracts.md §C7, docs/modules/db.md): statements end with `;` at end of line, every table is
-- CREATE TABLE IF NOT EXISTS, InnoDB, utf8mb4 / utf8mb4_swedish_ci, with created_at. No procedures, triggers or
-- DELIMITER. Never edit this file once it has been applied anywhere (the runners reject a changed checksum); add a
-- new NNN_*.sql instead. Times are UTC DATETIME whatever the server/session time zone: defaults are
-- (UTC_TIMESTAMP()), never CURRENT_TIMESTAMP/NOW(), and there is no ON UPDATE: every writer sets
-- updated_at = UTC_TIMESTAMP() itself. Identifier conventions: citizenid VARCHAR(50) (as qbx_core players.citizenid), Discord
-- snowflakes VARCHAR(20), unit codes VARCHAR(32) (config/units.json), levels 0 standard / 1 begränsad / 2 hemlig.

-- Bookkeeping: one row per applied migration (id = file name) and per applied seed (id = 'seed/<file name>').
-- The runners create this table before reading it; keep this statement identical to MIGRATIONS_TABLE_DDL in
-- scripts/migrate.mjs and resources/[fredpd]/fredpd_core/server/db.lua (packages/types/test/migrations.test.ts
-- compares all three).
CREATE TABLE IF NOT EXISTS fredpd_migrations (
  id VARCHAR(64) NOT NULL,
  checksum CHAR(64) NOT NULL,
  applied_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Discord guild roles, upserted by the bot (IMPLEMENTATION.md §5.9). Deleted roles are kept with deleted = 1 so
-- their grant rows and audit history survive; grant resolution ignores them (docs/contracts.md §C2).
-- Upsert only with INSERT ... ON DUPLICATE KEY UPDATE (drizzle onDuplicateKeyUpdate), never REPLACE INTO:
-- REPLACE deletes the old row first and the ON DELETE CASCADE below then wipes every grant of that role.
CREATE TABLE IF NOT EXISTS fredpd_roles (
  discord_role_id VARCHAR(20) NOT NULL,
  name VARCHAR(100) NOT NULL,
  colour INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Discord role colour as 0xRRGGBB',
  position INT NOT NULL DEFAULT 0,
  deleted TINYINT(1) NOT NULL DEFAULT 0,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (discord_role_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Role -> grant rows ("<type>:<key>", allow or deny). A role holds a key once: the unique key makes the admin
-- matrix an upsert and rules out a row that both allows and denies the same key.
CREATE TABLE IF NOT EXISTS fredpd_role_grants (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  discord_role_id VARCHAR(20) NOT NULL,
  grant_type ENUM('weapon','vehicle','armory','tool','mdt_page','intel_tier','unit','perm') NOT NULL,
  grant_key VARCHAR(64) NOT NULL,
  effect ENUM('allow','deny') NOT NULL DEFAULT 'allow',
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  UNIQUE KEY uq_role_grant (discord_role_id, grant_type, grant_key),
  CONSTRAINT fk_role_grants_role FOREIGN KEY (discord_role_id) REFERENCES fredpd_roles (discord_role_id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Discord user <-> game account. license is the FiveM/Rockstar identifier as stored in qbx_core players.license;
-- the portal lists a user's characters from players by it (IMPLEMENTATION.md §5.9). players is utf8mb4_unicode_ci:
-- compare with `p.license = i.license COLLATE utf8mb4_unicode_ci` or use two queries ("Joining qbx tables" in
-- docs/modules/db.md); a plain join fails with ERROR 1267.
CREATE TABLE IF NOT EXISTS fredpd_identities (
  discord_id VARCHAR(20) NOT NULL,
  license VARCHAR(64) NULL,
  last_citizenid VARCHAR(50) NULL,
  last_seen DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (discord_id),
  KEY idx_license (license),
  KEY idx_last_citizenid (last_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Last GrantSet per Discord user (docs/contracts.md §C2 wire shape), used when the service is unreachable.
CREATE TABLE IF NOT EXISTS fredpd_grant_cache (
  discord_id VARCHAR(20) NOT NULL,
  grants JSON NOT NULL,
  computed_at DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (discord_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Audit log (IMPLEMENTATION.md §4.5), written only by fredpd_core audit(). Indexes: record history
-- (target_type, target_id); per-officer activity and the obehörig-sökning count (actor_citizenid, created_at);
-- portal-only actors without a character (actor_discord, created_at); the monthly archive move (created_at).
CREATE TABLE IF NOT EXISTS fredpd_audit (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  actor_citizenid VARCHAR(50) NULL,
  actor_discord VARCHAR(20) NULL,
  action VARCHAR(64) NOT NULL,
  target_type VARCHAR(32) NULL,
  target_id VARCHAR(64) NULL,
  meta JSON NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_target (target_type, target_id),
  KEY idx_actor_created (actor_citizenid, created_at),
  KEY idx_actor_discord_created (actor_discord, created_at),
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Rows older than 90 days, moved by the monthly archive command (INSERT ... SELECT then DELETE, same ids).
-- Same shape as fredpd_audit plus archived_at; id is copied, so it is not AUTO_INCREMENT here.
CREATE TABLE IF NOT EXISTS fredpd_audit_archive (
  id BIGINT UNSIGNED NOT NULL,
  actor_citizenid VARCHAR(50) NULL,
  actor_discord VARCHAR(20) NULL,
  action VARCHAR(64) NOT NULL,
  target_type VARCHAR(32) NULL,
  target_id VARCHAR(64) NULL,
  meta JSON NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  archived_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_target (target_type, target_id),
  KEY idx_actor_created (actor_citizenid, created_at),
  KEY idx_actor_discord_created (actor_discord, created_at),
  KEY idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Unit catalogue, a SQL-side mirror of config/units.json (the config file stays the source of truth; fredpd_core
-- upserts it at start) so the service and reports can join unit labels and order without reading the file.
CREATE TABLE IF NOT EXISTS fredpd_units (
  code VARCHAR(32) NOT NULL,
  callsign_prefix VARCHAR(8) NOT NULL,
  label_key VARCHAR(64) NOT NULL COMMENT 'locale key, e.g. unit.igv',
  home VARCHAR(32) NULL COMMENT 'Hem page variant',
  sort_order SMALLINT NOT NULL DEFAULT 0 COMMENT 'primary-unit order (IMPLEMENTATION.md §4.9)',
  active TINYINT(1) NOT NULL DEFAULT 1,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Officer identity (IMPLEMENTATION.md §4.9): one row per police character. Records follow the character
-- (citizenid PK); names and ranks follow the Discord user, so one Discord user with two characters has two rows
-- with the same discord_id. uq_discord_citizen is implied by the PK but is kept on purpose: it documents the pair
-- and is the index the bot uses to refresh every row of a Discord user (WHERE discord_id = ?). discord_id alone is
-- deliberately NOT unique. Callsigns are unique within a unit; NULL (no duty yet) may repeat.
CREATE TABLE IF NOT EXISTS fredpd_officers (
  citizenid VARCHAR(50) NOT NULL,
  discord_id VARCHAR(20) NOT NULL,
  display_name VARCHAR(100) NOT NULL,
  avatar_url VARCHAR(255) NULL,
  callsign VARCHAR(16) NULL COMMENT 'formats.json callsign, e.g. IGV-07',
  unit VARCHAR(32) NULL COMMENT 'primary unit code',
  rank_role_id VARCHAR(20) NULL COMMENT 'Discord role holding perm:rank:<key>',
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (citizenid),
  UNIQUE KEY uq_discord_citizen (discord_id, citizenid),
  UNIQUE KEY uq_unit_callsign (unit, callsign)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Visibility rules (docs/contracts.md §C3), loaded by fredpd_core/server/canview.lua at start and on
-- fredpd:rulesChanged; defaults in db/seed/visibility_rules_default.sql. record_type '*' = every type,
-- level NULL = any level.
CREATE TABLE IF NOT EXISTS fredpd_visibility_rules (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  record_type VARCHAR(32) NOT NULL,
  level TINYINT UNSIGNED NULL CHECK (level <= 2),
  record_status ENUM('open','closed','any') NOT NULL DEFAULT 'any',
  viewer_condition ENUM('any','assigned','handler','unit','tier_gte','perm') NOT NULL,
  condition_value VARCHAR(64) NULL,
  result ENUM('full','masked','notice','none') NOT NULL,
  priority INT NOT NULL DEFAULT 0,
  enabled TINYINT(1) NOT NULL DEFAULT 1,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- {{seq}} counters, one per identifier type per year (year in Europe/Stockholm; 0 for a never-resetting counter).
-- Allocate atomically with fredpd_core db.nextSeq(), i.e.
--   INSERT INTO fredpd_sequences (seq_type, year, value) VALUES (?, ?, LAST_INSERT_ID(1))
--   ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + 1)
-- whose insert id is the allocated number.
CREATE TABLE IF NOT EXISTS fredpd_sequences (
  seq_type VARCHAR(32) NOT NULL,
  year SMALLINT UNSIGNED NOT NULL,
  value INT UNSIGNED NOT NULL DEFAULT 0,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (seq_type, year)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
