-- SPDX-License-Identifier: GPL-3.0-only
-- 008_tablets: issued pd_tablet items (IMPLEMENTATION.md §5.2). serial = ox_inventory metadata.serial. Opening a
-- tablet requires the item and revoked = 0; Ledning manages this on the "Surfplattor" page.

CREATE TABLE IF NOT EXISTS fredpd_tablets (
  serial VARCHAR(32) NOT NULL,
  owner_citizenid VARCHAR(50) NULL,
  revoked TINYINT(1) NOT NULL DEFAULT 0,
  revoked_by VARCHAR(50) NULL,
  revoked_at DATETIME NULL,
  revoke_reason VARCHAR(255) NULL,
  issued_by VARCHAR(50) NULL,
  issued_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (serial),
  KEY idx_owner (owner_citizenid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci;
