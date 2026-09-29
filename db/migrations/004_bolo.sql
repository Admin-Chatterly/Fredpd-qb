-- SPDX-License-Identifier: GPL-3.0-only
-- 004_bolo: efterlysningar (IMPLEMENTATION.md §5.4). fredpd_bolo keeps in-memory maps activeByPlate /
-- activeByCitizen, rebuilt from idx_active_expires at start; the plate and citizen indexes serve lookups on a miss
-- and the vehicle/person pages. plate is normalised like fredpd_vehicles_idx.plate. A BOLO for an unknown person
-- or an unplated vehicle leaves citizenid/plate NULL and relies on reason.

CREATE TABLE IF NOT EXISTS fredpd_bolos (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  kind ENUM('person','vehicle') NOT NULL,
  citizenid VARCHAR(50) NULL,
  plate VARCHAR(16) NULL,
  reason TEXT NOT NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 0 CHECK (level <= 2),
  unit VARCHAR(32) NULL,
  issued_by VARCHAR(50) NOT NULL,
  expires_at DATETIME NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  resolved_by VARCHAR(50) NULL,
  resolved_at DATETIME NULL,
  resolve_note VARCHAR(255) NULL,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_plate_active (plate, active),
  KEY idx_citizen_active (citizenid, active),
  KEY idx_active_expires (active, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
