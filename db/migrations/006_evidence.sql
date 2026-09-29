-- SPDX-License-Identifier: GPL-3.0-only
-- 006_evidence: evidence registered by fredpd_forensics (IMPLEMENTATION.md §5.7). A row can exist before it is
-- linked to a case (collected, handed in); case_id, n and tag are set by "Koppla till ärende".
-- tag = formats.json evidenceTag (B-{{case}}-{{n:3}}), n per case like fredpd_reports.n.
-- chain is a JSON array of custody entries appended on collect / hand-in / analysis / link.

CREATE TABLE IF NOT EXISTS fredpd_evidence (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  item_uid VARCHAR(64) NOT NULL COMMENT 'evidences item identifier',
  type VARCHAR(32) NOT NULL COMMENT 'fingerprint, dna, blood, casing, toolmark ...',
  case_id INT UNSIGNED NULL,
  n INT UNSIGNED NULL,
  tag VARCHAR(64) NULL COMMENT 'e.g. B-K-123-26-004',
  level TINYINT UNSIGNED NOT NULL DEFAULT 0 CHECK (level <= 2),
  result JSON NULL,
  collected_by VARCHAR(50) NULL,
  collected_at DATETIME NULL,
  chain JSON NOT NULL DEFAULT '[]',
  updated_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  UNIQUE KEY uq_item_uid (item_uid),
  UNIQUE KEY uq_tag (tag),
  UNIQUE KEY uq_case_n (case_id, n),
  CONSTRAINT fk_evidence_case FOREIGN KEY (case_id) REFERENCES fredpd_cases (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
