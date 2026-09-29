-- SPDX-License-Identifier: GPL-3.0-only
-- 005_dispatch: alerts mirrored from ps-dispatch (IMPLEMENTATION.md §5.5). The Larm page and the portal list
-- open/assigned alerts newest first: idx_status_created.

CREATE TABLE IF NOT EXISTS fredpd_alerts (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  code VARCHAR(16) NOT NULL COMMENT 'dispatch code, e.g. 10-71',
  title VARCHAR(160) NOT NULL,
  description TEXT NULL,
  coords JSON NULL COMMENT '{"x":0,"y":0,"z":0}',
  street VARCHAR(128) NULL,
  priority TINYINT UNSIGNED NOT NULL DEFAULT 2 COMMENT '1 highest',
  source VARCHAR(32) NOT NULL DEFAULT 'ps-dispatch',
  meta JSON NULL COMMENT 'generator payload (vehicle, weapon, gender ...)',
  status ENUM('open','assigned','closed') NOT NULL DEFAULT 'open',
  closed_by VARCHAR(50) NULL,
  closed_at DATETIME NULL,
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_status_created (status, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Officers assigned to an alert ("Ta larm"). callsign is a snapshot for the history view.
CREATE TABLE IF NOT EXISTS fredpd_alert_units (
  alert_id INT UNSIGNED NOT NULL,
  citizenid VARCHAR(50) NOT NULL,
  callsign VARCHAR(16) NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (alert_id, citizenid),
  KEY idx_citizenid (citizenid),
  CONSTRAINT fk_alert_units_alert FOREIGN KEY (alert_id) REFERENCES fredpd_alerts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
