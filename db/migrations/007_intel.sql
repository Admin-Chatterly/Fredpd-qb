-- SPDX-License-Identifier: GPL-3.0-only
-- 007_intel: sources, reports, entity graph and missions (IMPLEMENTATION.md §5.8). Everything here is filtered by
-- canView before it leaves the server; real_citizenid is returned only under the intel_source identity cap.
-- status uses the canView record status values (open = active, closed = avslutad).

CREATE TABLE IF NOT EXISTS fredpd_intel_sources (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  codename VARCHAR(64) NOT NULL,
  handler_citizenid VARCHAR(50) NOT NULL,
  reliability ENUM('A','B','C','D') NOT NULL DEFAULT 'C',
  status ENUM('open','closed') NOT NULL DEFAULT 'open',
  notes TEXT NULL,
  real_citizenid VARCHAR(50) NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 2 CHECK (level <= 2),
  unit VARCHAR(32) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_codename (codename),
  KEY idx_handler (handler_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Missions (spaningsuppdrag). lead_citizenid is the plan's `lead` (renamed: LEAD is reserved in MySQL 8).
CREATE TABLE IF NOT EXISTS fredpd_missions (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  title VARCHAR(160) NOT NULL,
  description TEXT NULL,
  unit VARCHAR(32) NULL,
  status ENUM('open','closed') NOT NULL DEFAULT 'open',
  level TINYINT UNSIGNED NOT NULL DEFAULT 2 CHECK (level <= 2),
  lead_citizenid VARCHAR(50) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_status_unit (status, unit),
  KEY idx_lead (lead_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

CREATE TABLE IF NOT EXISTS fredpd_mission_members (
  mission_id INT UNSIGNED NOT NULL,
  citizenid VARCHAR(50) NOT NULL,
  role VARCHAR(32) NULL,
  added_by VARCHAR(50) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (mission_id, citizenid),
  KEY idx_citizenid (citizenid),
  CONSTRAINT fk_mission_members_mission FOREIGN KEY (mission_id) REFERENCES fredpd_missions (id)
    ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Intel reports (author = citizenid). reliability grades the information, sources carry their own grade.
CREATE TABLE IF NOT EXISTS fredpd_intel_reports (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  source_id INT UNSIGNED NULL,
  mission_id INT UNSIGNED NULL,
  author VARCHAR(50) NOT NULL,
  body MEDIUMTEXT NOT NULL,
  reliability ENUM('A','B','C','D') NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 1 CHECK (level <= 2),
  status ENUM('open','closed') NOT NULL DEFAULT 'open',
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_source_created (source_id, created_at),
  KEY idx_mission_created (mission_id, created_at),
  KEY idx_author_created (author, created_at),
  CONSTRAINT fk_intel_reports_source FOREIGN KEY (source_id) REFERENCES fredpd_intel_sources (id),
  CONSTRAINT fk_intel_reports_mission FOREIGN KEY (mission_id) REFERENCES fredpd_missions (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Graph nodes. ref points at the real record (citizenid, normalised plate, case number ...); one node per
-- (type, ref). Locations and groups may have ref NULL (then only the label identifies them).
CREATE TABLE IF NOT EXISTS fredpd_intel_entities (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  type ENUM('person','vehicle','location','group','case') NOT NULL,
  ref VARCHAR(64) NULL,
  label VARCHAR(128) NOT NULL,
  created_by VARCHAR(50) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_type_ref (type, ref),
  KEY idx_label (label)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Graph edges, walked in both directions by getGraph (idx_from_to, idx_to). confidence 0-100.
CREATE TABLE IF NOT EXISTS fredpd_intel_links (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  from_id INT UNSIGNED NOT NULL,
  to_id INT UNSIGNED NOT NULL,
  type VARCHAR(32) NOT NULL COMMENT 'associate, owns, member_of, seen_at ...',
  confidence TINYINT UNSIGNED NOT NULL DEFAULT 50 CHECK (confidence <= 100),
  report_id INT UNSIGNED NULL,
  created_by VARCHAR(50) NOT NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 1 CHECK (level <= 2),
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_from_to (from_id, to_id),
  KEY idx_to (to_id),
  KEY idx_report (report_id),
  CONSTRAINT fk_intel_links_from FOREIGN KEY (from_id) REFERENCES fredpd_intel_entities (id) ON DELETE CASCADE,
  CONSTRAINT fk_intel_links_to FOREIGN KEY (to_id) REFERENCES fredpd_intel_entities (id) ON DELETE CASCADE,
  CONSTRAINT fk_intel_links_report FOREIGN KEY (report_id) REFERENCES fredpd_intel_reports (id)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
