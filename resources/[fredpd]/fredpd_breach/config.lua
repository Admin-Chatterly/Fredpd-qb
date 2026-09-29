-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach configuration (docs/modules/breach.md). Shared by server and client (ox_lib `require 'config'`).
-- Server-side checks read only the server's copy; the client uses the item/prop/anim/timing keys for display.

return {
    -- ox_inventory item (patches/ox_inventory.30-breach-items.patch). Without it in ox_inventory the resource still
    -- starts, logs one warning, and nobody can breach.
    ramItem = 'pd_ram',

    -- FredPD grant needed to breach (docs/contracts.md §C2 / §C16).
    grant = { 'tool', 'ram' },

    -- Prop held during the progress bar only (lib.progressBar attaches it and deletes it afterwards).
    -- GTA V has no battering ram model: 'prop_tool_shovel' is a placeholder (IMPLEMENTATION.md §5.6). Swap the model
    -- name for a streamed ram once one is chosen (docs/modules/breach.md "Ram model"), and adjust pos/rot for it.
    ramModel = 'prop_tool_shovel',
    ramBone = 57005,                        -- SKEL_R_Hand
    ramPos = vec3(0.10, 0.02, -0.02),
    ramRot = vec3(-80.0, 0.0, 0.0),

    -- Animation during the progress bar. The first entry whose dict and clip exist on the client is used
    -- (checked at run time with DoesAnimDictExist + GetAnimDuration); none → no animation, the breach still works.
    anims = {
        { dict = 'missheistfbi3b_ig7', clip = 'lift_fibagent_loop', flag = 49 }, -- IMPLEMENTATION.md §5.6 (VERIFY)
        { dict = 'melee@large_wpn@streamed_core', clip = 'ground_attack_on_spot', flag = 49 }, -- fallback (VERIFY)
    },

    -- Timings (milliseconds). The server rejects a finish sooner than progressMs - finishSlackMs after the start
    -- (the progress bar cannot be skipped) or later than tokenTtlMs after it.
    progressMs = 4000,
    finishSlackMs = 500,
    tokenTtlMs = 8000,
    startRateMs = 1000,                     -- one start attempt per player per second
    cooldownMs = 10000,                     -- after a successful breach, per player
    finishRateMs = 250,                     -- finish attempts per player: at most 4 per second

    -- ox_doorlock doors that can never be breached (checked on the server at start and finish). An entry is a door
    -- id (number), an exact door name (string) or a Lua pattern on the name ({ pattern = '^mrpd_' }). Empty = every
    -- ox_doorlock door can be breached, including the station's own cell/armory/evidence doors; list those here.
    -- Example: denyDoors = { 'mrpd_armory', { pattern = '^mrpd_evidence' }, 57 },
    denyDoors = {},

    -- Max distance (metres) between the player's ped (server-side position) and the door's ox_doorlock coords, at
    -- start and again at finish. ox_target shows the option within targetDistance.
    maxDistance = 3.0,
    targetDistance = 2.0,

    -- Evidence left at the door by a breach (optional). A list like a config/scene_evidence.lua entry, spawned with
    -- the breaching officer as owner, or false. evidences has no 'toolmark' type (docs/deps-verification.md
    -- "Mismatches"), so a toolmark cannot be produced yet; entries of types evidences lacks are skipped with one
    -- warning. Example: { { type = 'fingerprint', chance = 100 } }.
    breachEvidence = false,

    -- Scene evidence (export sceneEvidence): a scene of the same kind within sceneRadius metres of one accepted less
    -- than sceneCooldownMs ago is refused (spam guard); coords must fall inside mapBounds (GTA V map with margin).
    sceneCooldownMs = 60000,
    sceneRadius = 5.0,
    mapBounds = { minX = -4500.0, maxX = 4500.0, minY = -4500.0, maxY = 8500.0, minZ = -200.0, maxZ = 1500.0 },
    -- Spacing between the evidence pieces of one scene (evidences keeps one piece per exact coordinate).
    sceneSpacing = 0.25,
}
