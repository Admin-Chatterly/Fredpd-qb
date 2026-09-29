-- SPDX-License-Identifier: GPL-3.0-only
-- 011_evidence: the evidence item behind a fredpd_evidence row, recorded when fredpd_forensics first sees it
-- (docs/modules/forensics.md "Uid registry", docs/deps-verification.md Decision 5.2). evidences lets a client rewrite
-- item metadata (item_uid included) until its security patch is applied, so every later collect / hand-in / analysis
-- event for the uid is compared with these two columns and refused (audited evidence.mismatch) when they differ.
--   item_name  ox_inventory item name (collected_fingerprint, collected_casing ...), set when the row is created
--   ident      evidence identity, set once: 'fingerprint:<string>', 'dna:<string>' or
--              'ballistics:<owner>|<serial>|<weapon type>|<kind>' (NULL until the item carries evidence)
-- Both stay NULL on rows created before this migration and are filled at the next sighting of the item.

ALTER TABLE fredpd_evidence
  ADD COLUMN IF NOT EXISTS item_name VARCHAR(64) NULL COMMENT 'ox_inventory item name first seen for item_uid' AFTER item_uid,
  ADD COLUMN IF NOT EXISTS ident VARCHAR(191) NULL COMMENT 'evidence identity first seen for item_uid' AFTER item_name;
