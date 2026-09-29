-- SPDX-License-Identifier: GPL-3.0-only
-- 010_plate_checks: skyltkontroller (docs/contracts.md §C12, IMPLEMENTATION.md §5.4; owner fredpd_bolo, task 2.6).
-- One row per plate check: the ox_target option "Kontrollera registreringsskylt" (source 'target'), the tablet
-- action checkPlate ('tablet') and ANPR radar hits reported by the qbx_police patch ('radar', no officer). The
-- vehicle page lists the last 20 checks of a plate through idx_plate_created. plate is normalised like
-- fredpd_vehicles_idx.plate (upper case, no whitespace). The table is a log itself, so its rows are not audited
-- (docs/contracts.md §C7); the lookup is audited separately as bolo.check.
-- source is an addition to the §C12 column list (id, plate, officer_citizenid, hit, bolo_id, created_at).

CREATE TABLE IF NOT EXISTS fredpd_plate_checks (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  plate VARCHAR(16) NOT NULL,
  officer_citizenid VARCHAR(50) NULL,
  hit TINYINT(1) NOT NULL DEFAULT 0,
  bolo_id INT UNSIGNED NULL,
  source VARCHAR(16) NOT NULL DEFAULT 'tablet',
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_plate_created (plate, created_at),
  KEY idx_officer_created (officer_citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- BoloResolveInputSchema (packages/types/src/mdt.ts) allows a 500-character note; 004_bolo.sql made the column
-- VARCHAR(255). Widening is idempotent (the same MODIFY on every run is a no-op).
ALTER TABLE fredpd_bolos MODIFY COLUMN resolve_note VARCHAR(500) NULL;
