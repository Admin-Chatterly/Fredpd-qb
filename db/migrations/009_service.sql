-- SPDX-License-Identifier: GPL-3.0-only
-- 009_service: tables owned by apps/service (docs/contracts.md §C7, docs/modules/service.md): portal sessions and
-- uploaded images. Only fredpd_service reads or writes them; FXServer applies this file like every other migration.
-- Same file rules as 001 (docs/modules/db.md): IF NOT EXISTS, InnoDB, utf8mb4_swedish_ci, created_at, no question
-- marks anywhere (oxmysql would bind them).

-- Portal sessions (IMPLEMENTATION.md §4.6). The cookie fredpd_sid carries a random token; only its sha256 hex is
-- stored, so a leaked table does not hand out sessions. csrf_token is echoed by GET /api/session and required as the
-- x-csrf-token header on every write (docs/contracts.md §C10). citizenid is the character picked after login (NULL
-- until then). Expired rows are deleted on login and logout; there is no timer.
CREATE TABLE IF NOT EXISTS fredpd_sessions (
  id CHAR(64) NOT NULL COMMENT 'sha256 hex of the session token',
  discord_id VARCHAR(20) NOT NULL,
  citizenid VARCHAR(50) NULL,
  csrf_token VARCHAR(64) NOT NULL,
  expires_at DATETIME NOT NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_discord (discord_id),
  KEY idx_expires (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;

-- Uploaded images (POST /upload): png, jpeg or webp, at most 5 MB, type sniffed from the bytes. The file lives in
-- UPLOAD_DIR under file_name (random, never the client's name). source = portal (session) or game (HMAC from
-- FXServer). Records that use an image reference it by id.
CREATE TABLE IF NOT EXISTS fredpd_uploads (
  id CHAR(32) NOT NULL COMMENT 'random hex, also the file name stem',
  file_name VARCHAR(64) NOT NULL,
  mime VARCHAR(32) NOT NULL,
  size_bytes INT UNSIGNED NOT NULL,
  sha256 CHAR(64) NOT NULL,
  source ENUM('portal','game') NOT NULL,
  uploader_discord VARCHAR(20) NULL,
  uploader_citizenid VARCHAR(50) NULL,
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  UNIQUE KEY uq_file_name (file_name),
  KEY idx_uploader_discord (uploader_discord, created_at),
  KEY idx_uploader_citizenid (uploader_citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
