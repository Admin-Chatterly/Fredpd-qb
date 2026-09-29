-- SPDX-License-Identifier: GPL-3.0-only
-- Scene evidence per crime kind (IMPLEMENTATION.md §5.6; keys = SceneKind in packages/types/src/evidence.ts).
-- Crime scripts call exports.fredpd_breach:sceneEvidence(kind, coords, suspectSrc) (server-only); each entry below
-- is rolled once (chance in percent) and spawned with the suspect as owner through
-- exports.evidences:syncEvidence(type, suspectSrc, 'atCoords', coords) (evidences server/evidences/api.lua:50-60).
--
-- type: an evidences type — fingerprint, blood, saliva, magazine, casing, bullet, gunshot_residue
--       (evidences server/evidences/api.lua:7-15). Other types (e.g. 'toolmark') are kept for when a toolmark type
--       exists, but skipped with one warning at start: evidences cannot spawn them.
-- at:   'scene' = at the coords the script passed (a door, a till, a car door). Pieces of one scene are spaced
--       config.sceneSpacing apart so evidences does not drop a second piece at the same coordinate.
-- shooting: casings, bullets and gunshot residue come from evidences itself when a weapon is fired; nothing extra.
return {
    burglary = {
        { type = 'fingerprint', at = 'scene', chance = 80 },
        { type = 'toolmark', at = 'scene', chance = 100 },
    },
    shooting = {},
    assault = {
        { type = 'blood', at = 'scene', chance = 60 },
    },
    robbery = {
        { type = 'fingerprint', at = 'scene', chance = 60 },
    },
    vehicle_theft = {
        { type = 'fingerprint', at = 'scene', chance = 70 },
    },
}
