-- SPDX-License-Identifier: GPL-3.0-only
-- DEV/TEST ONLY. Minimal stand-ins for the qbx_core `players` and qbx_vehicles `player_vehicles` tables so FredPD
-- migrations, mirrors and joins can be tested without a Qbox install. Column names, types and collations follow the
-- upstream qbx_core (qbx_core.sql) and qbx_vehicles (vehicles.sql) schemas, with fewer columns. Never apply this to
-- a server database: the real tables come from qbx_core / qbx_vehicles.
--
-- Collation matters: upstream tables are utf8mb4_unicode_ci (player_vehicles.mods utf8mb4_bin), FredPD tables
-- utf8mb4_swedish_ci, so comparing a FredPD string column with a qbx one fails with ERROR 1267 "Illegal mix of
-- collations" exactly as on a server (see "Joining qbx tables" in docs/modules/db.md).
--
-- Deliberate difference: player_vehicles has no index on plate here (upstream: UNIQUE KEY plate), so tests see
-- 002_index.sql add it. players.last_updated keeps upstream's TIMESTAMP ... ON UPDATE CURRENT_TIMESTAMP on purpose:
-- it mirrors qbx_core, and the UTC rules of docs/contracts.md §C7 cover fredpd_* tables only (TIMESTAMP is stored
-- as UTC by MariaDB anyway).

CREATE TABLE IF NOT EXISTS players (
  id INT(11) NOT NULL AUTO_INCREMENT,
  citizenid VARCHAR(50) NOT NULL,
  cid INT(11) DEFAULT NULL,
  license VARCHAR(255) NOT NULL,
  name VARCHAR(255) NOT NULL,
  money TEXT NOT NULL,
  charinfo TEXT DEFAULT NULL,
  job TEXT NOT NULL,
  gang TEXT DEFAULT NULL,
  position TEXT NOT NULL,
  metadata TEXT NOT NULL,
  phone_number VARCHAR(20) DEFAULT NULL,
  last_updated TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  last_logged_out TIMESTAMP NULL DEFAULT NULL,
  PRIMARY KEY (citizenid),
  KEY id (id),
  KEY license (license)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS player_vehicles (
  id INT(11) NOT NULL AUTO_INCREMENT,
  license VARCHAR(50) DEFAULT NULL,
  citizenid VARCHAR(50) DEFAULT NULL,
  vehicle VARCHAR(50) DEFAULT NULL,
  hash VARCHAR(50) DEFAULT NULL,
  mods LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
  plate VARCHAR(15) NOT NULL,
  garage VARCHAR(50) DEFAULT NULL,
  fuel INT(11) DEFAULT 100,
  engine FLOAT DEFAULT 1000,
  body FLOAT DEFAULT 1000,
  state INT(11) DEFAULT 1,
  PRIMARY KEY (id),
  KEY citizenid (citizenid),
  CONSTRAINT player_vehicles_ibfk_1 FOREIGN KEY (citizenid) REFERENCES players (citizenid)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- A few characters and vehicles for manual testing (idempotent).
INSERT IGNORE INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, phone_number) VALUES
  ('FPD10001', 1, 'license:0000000000000000000000000000000000000001', 'Anna Berg', '{"cash":500,"bank":12000}',
   '{"firstname":"Anna","lastname":"Berg","birthdate":"1994-03-12","gender":1,"nationality":"Svensk","phone":"0701234567"}',
   '{"name":"police","label":"Polis","grade":{"level":2,"name":"Inspektör"},"onduty":true}', '{"name":"none"}',
   '{"x":0,"y":0,"z":0}', '{}', '0701234567'),
  ('FPD10002', 1, 'license:0000000000000000000000000000000000000002', 'Erik Lindqvist', '{"cash":80,"bank":3100}',
   '{"firstname":"Erik","lastname":"Lindqvist","birthdate":"1988-11-02","gender":0,"nationality":"Svensk","phone":"0739876543"}',
   '{"name":"unemployed","label":"Arbetslös","grade":{"level":0,"name":"Arbetslös"},"onduty":false}', '{"name":"none"}',
   '{"x":0,"y":0,"z":0}', '{}', '0739876543'),
  ('FPD10003', 2, 'license:0000000000000000000000000000000000000002', 'Sara Öberg', '{"cash":0,"bank":450}',
   '{"firstname":"Sara","lastname":"Öberg","birthdate":"2001-07-30","gender":1,"nationality":"Svensk","phone":"0761112233"}',
   '{"name":"unemployed","label":"Arbetslös","grade":{"level":0,"name":"Arbetslös"},"onduty":false}', '{"name":"none"}',
   '{"x":0,"y":0,"z":0}', '{}', '0761112233');

INSERT IGNORE INTO player_vehicles (id, license, citizenid, vehicle, hash, mods, plate, garage, state) VALUES
  (1, 'license:0000000000000000000000000000000000000002', 'FPD10002', 'sultan', '970598228', '{}', 'ABC 12D', 'pillboxgarage', 1),
  (2, 'license:0000000000000000000000000000000000000002', 'FPD10003', 'blista', '1039032026', '{}', 'KLM 34E', 'pillboxgarage', 0);
