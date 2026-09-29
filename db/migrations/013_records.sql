-- SPDX-License-Identifier: GPL-3.0-only
-- 013_records: additive columns for the Phase 5 writes of fredpd_records (docs/modules/records.md).
--   fredpd_cases.resolution          the closing note of closeCase (the level stays after close, §C14)
--   fredpd_shares.max_level          highest level a share link may show: the creator's tier when it was created, so a
--                                    link never shows more than its creator could read by tier (assignment-only
--                                    access does not travel with a link)
--   fredpd_release_requests.channel  where the request came in: 'station' (ox_target) or 'portal'
-- No ENUMs here (enum values need locale keys, packages/types/test/locales.test.ts). Obehörig sökning needs no table:
-- it counts fredpd_audit rows through idx (actor_citizenid, created_at) on each person lookup.

ALTER TABLE fredpd_cases
  ADD COLUMN IF NOT EXISTS resolution TEXT NULL COMMENT 'closing note (closeCase)' AFTER summary;

ALTER TABLE fredpd_shares
  ADD COLUMN IF NOT EXISTS max_level TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'highest level the link shows' AFTER target_id;

ALTER TABLE fredpd_release_requests
  ADD COLUMN IF NOT EXISTS channel VARCHAR(16) NULL COMMENT 'station | portal' AFTER requester_name;
