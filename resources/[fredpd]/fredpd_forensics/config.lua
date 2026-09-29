-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics configuration (docs/modules/forensics.md). Shared by server and client (ox_lib `require 'config'`).
--
-- Coordinates: the defaults are for the vanilla Mission Row police station (MRPD) and are placeholders. Edit them for
-- the map the server runs (stand on the spot in game and read your position with any coords tool), then restart
-- the resource. Box zones: `coords` = centre, `size` = x/y/z extent in metres, `rotation` = heading in degrees.
-- vec3/vec4 are FiveM's vector constructors.

return {
    -- Station lab(s). Inside the box the laptop option "Analysera" is added to every evidences laptop
    -- (p_laptop_02_s), and FredPD spawns a local laptop prop at `laptop` (x, y, z, heading) for players inside the
    -- zone, so the lab needs no placed evidence_laptop item. Set `laptop = nil` to use a laptop placed with the
    -- evidence_laptop item instead. Analyses done inside a lab box get the lab id as custody location.
    labs = {
        {
            id = 'mrpd_lab',
            coords = vec3(474.6, -990.4, 26.3),
            size = vec3(6.0, 5.0, 3.0),
            rotation = 0.0,
            laptop = vec4(474.9, -990.1, 27.25, 180.0),
        },
    },

    -- Evidence lockers: ox_inventory stashes registered at start (label = locale key). Players open them with the
    -- ox_target box at `coords`; `groups` is ox_inventory's own job check for opening the stash (it knows nothing of
    -- duty or FredPD grants, see lockerGrant below).
    lockers = {
        {
            id = 'evidence_locker_mrpd',
            labelKey = 'evidence.locker',
            slots = 200,
            maxWeight = 200000,
            groups = { police = 0 },
            coords = vec3(475.0, -996.25, 26.27),
            size = vec3(1.6, 1.2, 2.2),
            rotation = 0.0,
        },
    },

    -- Inventories that count as evidence lockers for the custody chain (Lua patterns on the ox_inventory id):
    -- FredPD's stashes above ('evidence_…') and ox_inventory's own police evidence lockers ('evidence-<number>').
    lockerPatterns = { '^evidence_', '^evidence%-%d+$' },

    -- Opening any locker above (every inventory matching lockerPatterns, ox_inventory's own `evidence-<n>` included)
    -- also needs this FredPD grant and being on duty (ox_inventory openInventory hook). Everyone who hands in
    -- evidence needs it, patrol included. false = only the stash's `groups`.
    lockerGrant = { 'mdt_page', 'evidence' },

    -- Container items whose contents are tracked when the container itself is handed in or checked out.
    containerItems = { evidence_box = true },

    -- Unit that works the unlinked queue (canView record unit for evidence without a case; config/units.json code).
    labUnit = 'tekniker',

    -- Server timings.
    linkCooldownMs = 2000,    -- "Koppla till ärende" dialog: one link attempt per player per 2 s
    registerDelayMs = 250,    -- after a new evidence item is created, read its evidences metadata this much later
}
