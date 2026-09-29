-- SPDX-License-Identifier: GPL-3.0-only
-- 002_index: search mirror tables (IMPLEMENTATION.md §4.2). players.charinfo is JSON and cannot be indexed, so
-- searches never touch it; fredpd_core keeps these mirrors current (backfill + qbx_core events, task 1.4).

-- One row per character. Name search: MATCH (firstname, lastname) AGAINST (... IN BOOLEAN MODE) uses ft_name;
-- prefix / sorted lists use idx_name. personnummer backs the personId search type (docs/contracts.md §C4) and is
-- stored normalised as digits with a dash before the last four (YYMMDD-XXXX or YYYYMMDD-XXXX). gender follows
-- qbx charinfo (0 man, 1 kvinna). license = players.license (links characters of one account).
-- InnoDB FULLTEXT skips words shorter than innodb_ft_min_token_size (default 3): see docs/modules/db.md.
CREATE TABLE IF NOT EXISTS fredpd_persons (
  citizenid VARCHAR(50) NOT NULL,
  firstname VARCHAR(64) NOT NULL DEFAULT '',
  lastname VARCHAR(64) NOT NULL DEFAULT '',
  birthdate DATE NULL,
  personnummer VARCHAR(13) NULL,
  gender TINYINT UNSIGNED NULL,
  phone VARCHAR(20) NULL,
  license VARCHAR(64) NULL,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (citizenid),
  KEY idx_name (lastname, firstname),
  KEY idx_personnummer (personnummer),
  FULLTEXT KEY ft_name (firstname, lastname)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- One row per owned vehicle. plate is stored normalised the same way detectSearchType() normalises a query
-- (trimmed, upper case, spaces removed), so a lookup is a primary-key hit.
CREATE TABLE IF NOT EXISTS fredpd_vehicles_idx (
  plate VARCHAR(16) NOT NULL,
  citizenid VARCHAR(50) NULL,
  model VARCHAR(64) NULL,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (plate),
  KEY idx_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- qbx_vehicles' player_vehicles is looked up by plate on a mirror miss. Upstream schemas name a plate key `plate`
-- (MariaDB's default name for a single-column key), so IF NOT EXISTS turns this into a no-op there; it only adds
-- the index on installs that lack it. Skipped when player_vehicles does not exist (docs/contracts.md §C7).
-- @if-table-exists player_vehicles
CREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate);
