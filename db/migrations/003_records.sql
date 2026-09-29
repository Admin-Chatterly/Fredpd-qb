-- SPDX-License-Identifier: GPL-3.0-only
-- 003_records: cases, reports, charges, POI sheets, shares and release requests (IMPLEMENTATION.md §5.3).
-- Records are kept, not deleted: child rows reference their case with ON DELETE RESTRICT (the default) unless
-- they are pure attachments (assignees, subjects, drafts), which cascade.
-- Numbering: case_number from formats.json caseNumber ({{seq}} via fredpd_sequences); per-case counters {{n}}
-- (reports.n, evidence.n) are allocated as MAX(n) + 1 inside the transaction that inserts the row, and the
-- (case_id, n) unique key turns a race into a retryable duplicate-key error.

CREATE TABLE IF NOT EXISTS fredpd_cases (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_number VARCHAR(32) NOT NULL COMMENT 'e.g. K-123-26',
  title VARCHAR(160) NOT NULL,
  summary TEXT NULL,
  status ENUM('open','closed') NOT NULL DEFAULT 'open',
  level TINYINT UNSIGNED NOT NULL DEFAULT 0 CHECK (level <= 2),
  unit VARCHAR(32) NULL COMMENT 'owning unit code',
  owner_citizenid VARCHAR(50) NULL COMMENT 'handläggare (canView ownerCitizenid)',
  created_by VARCHAR(50) NULL,
  closed_by VARCHAR(50) NULL,
  closed_at DATETIME NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_case_number (case_number),
  KEY idx_status_updated (status, updated_at),
  KEY idx_unit_status (unit, status),
  KEY idx_owner (owner_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- canView assignees. idx_citizenid serves "my cases".
CREATE TABLE IF NOT EXISTS fredpd_case_assignees (
  case_id INT UNSIGNED NOT NULL,
  citizenid VARCHAR(50) NOT NULL,
  role ENUM('lead','member') NOT NULL DEFAULT 'member',
  added_by VARCHAR(50) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (case_id, citizenid),
  KEY idx_citizenid (citizenid),
  CONSTRAINT fk_case_assignees_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Persons (citizenid) and vehicles (normalised plate) linked to a case. idx_subject answers "cases for this
-- person/vehicle" on the person and vehicle pages (getPersonSummary).
CREATE TABLE IF NOT EXISTS fredpd_case_subjects (
  case_id INT UNSIGNED NOT NULL,
  subject_type ENUM('person','vehicle') NOT NULL,
  subject_id VARCHAR(50) NOT NULL,
  role ENUM('suspect','victim','witness','other') NOT NULL DEFAULT 'other',
  added_by VARCHAR(50) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (case_id, subject_type, subject_id),
  KEY idx_subject (subject_type, subject_id),
  CONSTRAINT fk_case_subjects_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Report templates (markdown). unit NULL = offered to every unit.
CREATE TABLE IF NOT EXISTS fredpd_report_templates (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name VARCHAR(100) NOT NULL,
  unit VARCHAR(32) NULL,
  body MEDIUMTEXT NOT NULL,
  active TINYINT(1) NOT NULL DEFAULT 1,
  created_by VARCHAR(50) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_unit_name (unit, name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Reports always belong to a case: report_number = formats.json reportNumber ({{case}}/{{n}}), n per case.
CREATE TABLE IF NOT EXISTS fredpd_reports (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  case_id INT UNSIGNED NOT NULL,
  n INT UNSIGNED NOT NULL,
  report_number VARCHAR(48) NOT NULL COMMENT 'e.g. K-123-26/2',
  title VARCHAR(160) NOT NULL,
  body MEDIUMTEXT NOT NULL COMMENT 'markdown-lite',
  template_id INT UNSIGNED NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 0 CHECK (level <= 2),
  author_citizenid VARCHAR(50) NOT NULL,
  updated_by VARCHAR(50) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_report_number (report_number),
  UNIQUE KEY uq_case_n (case_id, n),
  KEY idx_author_created (author_citizenid, created_at),
  CONSTRAINT fk_reports_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id),
  CONSTRAINT fk_reports_template FOREIGN KEY (template_id) REFERENCES fredpd_report_templates (id)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Editor autosave (debounced, only while focused and dirty). report_id NULL = draft of a new report; one draft
-- per author and existing report.
CREATE TABLE IF NOT EXISTS fredpd_report_drafts (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  author_citizenid VARCHAR(50) NOT NULL,
  report_id INT UNSIGNED NULL,
  case_id INT UNSIGNED NULL,
  template_id INT UNSIGNED NULL,
  title VARCHAR(160) NULL,
  body MEDIUMTEXT NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_author_report (author_citizenid, report_id),
  KEY idx_author_updated (author_citizenid, updated_at),
  CONSTRAINT fk_report_drafts_report FOREIGN KEY (report_id) REFERENCES fredpd_reports (id) ON DELETE CASCADE,
  CONSTRAINT fk_report_drafts_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id) ON DELETE CASCADE,
  CONSTRAINT fk_report_drafts_template FOREIGN KEY (template_id) REFERENCES fredpd_report_templates (id)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Charge catalogue (Brottskatalog), seeded by db/seed/charges_sv.sql. fine in SEK, jail_min in game minutes.
-- category is an English key (penal, traffic, narcotics, weapons, public_order, other); the UI label comes from
-- the locale. Retire a charge with active = 0 instead of deleting it (records reference it).
CREATE TABLE IF NOT EXISTS fredpd_charges (
  code VARCHAR(16) NOT NULL,
  category VARCHAR(32) NOT NULL,
  title_sv VARCHAR(160) NOT NULL,
  law_ref VARCHAR(96) NOT NULL,
  class ENUM('ordningsbot','bot','fängelse') NOT NULL,
  fine INT UNSIGNED NOT NULL DEFAULT 0,
  jail_min SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  active TINYINT(1) NOT NULL DEFAULT 1,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Charges applied to a person. title_sv/class/fine/jail_min are snapshots taken when the charge is applied, so
-- later catalogue edits never rewrite history. fine and jail_min are totals for quantity.
CREATE TABLE IF NOT EXISTS fredpd_records (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  citizenid VARCHAR(50) NOT NULL,
  case_id INT UNSIGNED NULL,
  report_id INT UNSIGNED NULL,
  charge_code VARCHAR(16) NOT NULL,
  title_sv VARCHAR(160) NOT NULL,
  class ENUM('ordningsbot','bot','fängelse') NOT NULL,
  quantity SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  fine INT UNSIGNED NOT NULL DEFAULT 0,
  jail_min INT UNSIGNED NOT NULL DEFAULT 0,
  status ENUM('issued','paid','served','revoked') NOT NULL DEFAULT 'issued',
  issued_by VARCHAR(50) NOT NULL,
  note VARCHAR(255) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_citizen_created (citizenid, created_at),
  KEY idx_case (case_id),
  KEY idx_report (report_id),
  KEY idx_charge (charge_code),
  CONSTRAINT fk_records_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id),
  CONSTRAINT fk_records_report FOREIGN KEY (report_id) REFERENCES fredpd_reports (id),
  CONSTRAINT fk_records_charge FOREIGN KEY (charge_code) REFERENCES fredpd_charges (code) ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- POI sheet (person of interest). warnings is a JSON array of warning keys (e.g. ["armed","violent"]).
CREATE TABLE IF NOT EXISTS fredpd_poi (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  citizenid VARCHAR(50) NOT NULL,
  level TINYINT UNSIGNED NOT NULL DEFAULT 0 CHECK (level <= 2),
  status ENUM('open','closed') NOT NULL DEFAULT 'open',
  unit VARCHAR(32) NULL,
  owner_citizenid VARCHAR(50) NULL,
  summary TEXT NULL,
  warnings JSON NULL,
  photo_url VARCHAR(255) NULL,
  updated_by VARCHAR(50) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_citizenid (citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Share links (IMPLEMENTATION.md §4.6): the 32-byte base64url token lives only in the URL; the table keeps its
-- sha256 hex so a database leak does not leak working links. Expiry is mandatory; every view is audited.
CREATE TABLE IF NOT EXISTS fredpd_shares (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  token_hash CHAR(64) NOT NULL,
  target_type VARCHAR(32) NOT NULL,
  target_id VARCHAR(64) NOT NULL,
  created_by VARCHAR(50) NULL COMMENT 'citizenid',
  created_by_discord VARCHAR(20) NULL,
  expires_at DATETIME NOT NULL,
  revoked_at DATETIME NULL,
  view_count INT UNSIGNED NOT NULL DEFAULT 0,
  last_viewed_at DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_token_hash (token_hash),
  KEY idx_target (target_type, target_id),
  KEY idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- "Begär ut allmän handling". The requester may not know a record id, so target_* is optional and description is
-- the request text. released_body is the masked content exactly as released.
CREATE TABLE IF NOT EXISTS fredpd_release_requests (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  requester_citizenid VARCHAR(50) NULL,
  requester_discord VARCHAR(20) NULL,
  requester_name VARCHAR(100) NULL,
  target_type VARCHAR(32) NULL,
  target_id VARCHAR(64) NULL,
  description TEXT NOT NULL,
  status ENUM('pending','approved','partial','denied') NOT NULL DEFAULT 'pending',
  decided_by VARCHAR(50) NULL,
  decided_at DATETIME NULL,
  decision_note TEXT NULL,
  released_body MEDIUMTEXT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_status_created (status, created_at),
  KEY idx_target (target_type, target_id),
  KEY idx_requester (requester_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
