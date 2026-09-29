-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt settings (client and server; loaded with ox_lib `require 'config'`). Nothing secret: every client can
-- read this file. Changing it needs a resource restart.
return {
    --- ox_inventory item name (patches/ox_inventory.10-fredpd-items.patch).
    item = 'pd_tablet',

    --- Tablet prop and animation (IMPLEMENTATION.md §5.2). The clip is a seated bus-passenger idle; that it looks
    --- right standing is UNVERIFIED (docs/test-phase-2.md step 1). Offsets/rotation in the hand bone's space.
    prop = {
        model = 'prop_cs_tablet',
        bone = 28422, -- SKEL_R_Hand PH_R_Hand
        offset = { 0.0, -0.03, 0.0 },
        rotation = { 20.0, -90.0, 0.0 },
        networked = true, -- visible to others; set false if sv_entityLockdown blocks client-created objects
    },
    anim = {
        dict = 'amb@code_human_in_bus_passenger_idles@female@tablet@base',
        clip = 'base',
        flag = 49, -- upper body, loop, controllable
    },

    --- Vehicle terminal ("Fordonsdator"): an ox_target option on these models, usable from the driver or front
    --- passenger seat. The server checks the model and the seat again.
    terminal = {
        enabled = true,
        requireItem = false, -- true: the terminal also needs a registered pd_tablet in the inventory
        distance = 2.5,
        seats = { -1, 0 },
        models = {
            'police', 'police2', 'police3', 'police4', 'policeb', 'policet', 'polmav', 'pranger', 'sheriff',
            'sheriff2', 'fbi', 'fbi2', 'riot', 'riot2',
        },
    },

    --- Refuse a tablet whose registered owner is another character (the item can be handed over otherwise).
    requireOwner = false,

    --- Serial numbers: prefix + two groups of 4 from an alphabet without look-alikes (I/1, O/0).
    serial = { prefix = 'SP', alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789', groups = 2, groupLength = 4 },

    --- Rate limits in ms per player per action (docs/contracts.md §C12 step 4: lookups 1 per 500 ms, writes 1 per
    --- 2 s). Reads (list/get) 500 ms and the report autosave (saveReportDraft, debounced ≥ 10 s by the NUI) 5 s are
    --- ours.
    limits = { lookup = 500, write = 2000, read = 500, draft = 5000, open = 750, issue = 2000 },

    --- Page size of listTablets (IMPLEMENTATION.md §4.7).
    pageSize = 50,
}
