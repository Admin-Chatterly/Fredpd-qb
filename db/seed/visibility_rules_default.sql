-- SPDX-License-Identifier: GPL-3.0-only
-- Default visibility rules for fredpd_visibility_rules (docs/contracts.md §C3; ASSUMED PLAN §5d):
-- permissive for IGV lookups, strict for sources and missions. See docs/modules/grants-canview.md.
--
-- Evaluation: enabled rules matching record_type ('*' = all) / level (NULL = any) / record_status ('any'),
-- by priority DESC then id ASC; the first rule whose viewer_condition holds wins; no match = 'none'.
-- The hard caps in canView (intel_source identity, level above tier) apply afterwards and are not
-- configurable here.
--
-- Priorities: 100 perm override · 95 BOLO level 0 · 90 assigned/handler · 80 unit · 70 tier_gte ·
--             60 intel.read · 50 disabled example · 10 fallback · -1000 id sentinel.
-- Ids are explicit and grouped per record type (case 10–19, report 20–29, evidence 30–39, poi 40–49,
-- bolo 50–59, mission 60–69, intel_report 70–79, intel_source 80–89). Ids 1–998 are reserved for defaults.
-- Rule 999 is a disabled sentinel: after this seed AUTO_INCREMENT is MAX(id) + 1 = 1000, so rules created by
-- admins get ids from 1000 up and never take an id a later default needs (ON DUPLICATE KEY UPDATE id = id
-- would skip such a default without an error). Keep 999 the highest seeded id.
--
-- Idempotent: re-running inserts missing rows and leaves existing ones (including admin edits) untouched.
-- The seed runners re-apply this file whenever its checksum changes (even a comment edit), and every
-- missing default id is then inserted again. So a default rule (ids 1-999) must be switched off with
-- enabled = 0, never deleted: a deleted default rule silently comes back on the next re-apply.
-- packages/types/test/canView.test.ts parses this file and asserts it equals the `rules` array of
-- packages/types/test/fixtures/canView.fixtures.json, so keep one tuple per line in this exact shape.

INSERT INTO fredpd_visibility_rules
  (id, record_type, level, record_status, viewer_condition, condition_value, result, priority, enabled)
VALUES
  -- Cases: open -> assigned/owner or case unit full, anyone else kontaktnotis;
  --        closed -> assigned/owner full, tier >= level masked, else kontaktnotis.
  (10, 'case', NULL, 'any', 'perm', 'records.admin', 'full', 100, 1),
  (11, 'case', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (12, 'case', NULL, 'open', 'unit', NULL, 'full', 80, 1),
  (13, 'case', NULL, 'closed', 'tier_gte', NULL, 'masked', 70, 1),
  (14, 'case', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- Disabled example: enable to let every officer read open cases masked instead of a kontaktnotis.
  (15, 'case', NULL, 'open', 'any', NULL, 'masked', 50, 0),
  -- Reports: as cases.
  (20, 'report', NULL, 'any', 'perm', 'records.admin', 'full', 100, 1),
  (21, 'report', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (22, 'report', NULL, 'open', 'unit', NULL, 'full', 80, 1),
  (23, 'report', NULL, 'closed', 'tier_gte', NULL, 'masked', 70, 1),
  (24, 'report', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- Evidence: as cases.
  (30, 'evidence', NULL, 'any', 'perm', 'records.admin', 'full', 100, 1),
  (31, 'evidence', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (32, 'evidence', NULL, 'open', 'unit', NULL, 'full', 80, 1),
  (33, 'evidence', NULL, 'closed', 'tier_gte', NULL, 'masked', 70, 1),
  (34, 'evidence', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- POI sheets: permissive lookups, anyone with tier >= level reads them in full.
  (40, 'poi', NULL, 'any', 'perm', 'records.admin', 'full', 100, 1),
  (41, 'poi', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (42, 'poi', NULL, 'any', 'unit', NULL, 'full', 80, 1),
  (43, 'poi', NULL, 'any', 'tier_gte', NULL, 'full', 70, 1),
  (44, 'poi', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- BOLO: level 0 full for everyone; higher levels for issuer, unit and tier >= level.
  (50, 'bolo', NULL, 'any', 'perm', 'records.admin', 'full', 100, 1),
  (51, 'bolo', 0, 'any', 'any', NULL, 'full', 95, 1),
  (52, 'bolo', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (53, 'bolo', NULL, 'any', 'unit', NULL, 'full', 80, 1),
  (54, 'bolo', NULL, 'any', 'tier_gte', NULL, 'full', 70, 1),
  (55, 'bolo', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- Missions (strict): members/lead and intel.command full, everyone else kontaktnotis.
  (60, 'mission', NULL, 'any', 'perm', 'intel.command', 'full', 100, 1),
  (61, 'mission', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (62, 'mission', NULL, 'any', 'any', NULL, 'notice', 10, 1),
  -- Intel reports (strict): author/assigned, intel.command, intel.read full (tier cap applies), else none.
  -- OPEN (review accepted option a; §C3 text to be amended): §C3 says intel.read below the report's level
  -- gets none, but one condition per rule cannot express intel.read AND tier_gte, so rule 72 plus the level
  -- cap gives notice (see the module doc).
  (70, 'intel_report', NULL, 'any', 'perm', 'intel.command', 'full', 100, 1),
  (71, 'intel_report', NULL, 'any', 'assigned', NULL, 'full', 90, 1),
  (72, 'intel_report', NULL, 'any', 'perm', 'intel.read', 'full', 60, 1),
  -- Intel sources (strict): handler and intel.command full (identity cap applies), intel.read masked; else none.
  (80, 'intel_source', NULL, 'any', 'perm', 'intel.command', 'full', 100, 1),
  (81, 'intel_source', NULL, 'any', 'handler', NULL, 'full', 90, 1),
  (82, 'intel_source', NULL, 'any', 'perm', 'intel.read', 'masked', 60, 1),
  -- Id sentinel (see the header): disabled, and harmless if enabled ('none' is also the no-match result).
  (999, '*', NULL, 'any', 'any', NULL, 'none', -1000, 0)
ON DUPLICATE KEY UPDATE id = id;
