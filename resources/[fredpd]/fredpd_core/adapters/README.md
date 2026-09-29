<!-- SPDX-License-Identifier: GPL-3.0-only -->
# fredpd_core adapters

FredPD talks to third-party housing, garage and prison scripts only through these adapters (IMPLEMENTATION.md §9,
task 0.6). The active adapter per kind comes from `config/integrations.json`:

```json
{ "housing": "ps-housing", "garage": "qbx_garages", "prison": "none" }
```

Other resources get the active one with `exports.fredpd_core:getAdapter(kind)` and call its methods with a dot
(`housing.unlock(propertyId, src)`); the methods take no `self`.

## Interfaces

Every method has a no-op fallback (in `base.lua`). It is used when the adapter does not implement the method, when
its resource is not started, and when the implementation raises (the error is logged). Callers therefore never
need to check which script is installed.

| Kind | Method | Returns | No-op |
|---|---|---|---|
| housing | `getDoorForProperty(propertyId)` | ox_doorlock door ids of the property, or `nil` | `nil` |
| housing | `unlock(propertyId, src)` | `true` when the entrance was unlocked (breach, task 6.1) | `false` |
| housing | `getAddresses(citizenid)` | `{ { propertyId, label }, ... }` for the person page | `{}` |
| garage | `onParked(cb)` | `true` when `cb(plate, src, garageName)` is hooked to "vehicle parked" | `false` |
| garage | `onTakenOut(cb)` | `true` when `cb(plate, src, garageName)` is hooked to "vehicle taken out" | `false` |
| prison | `jail(src, minutes, charges)` | `true` when the prison script accepted it; `charges = { { code, label } }` | `false` |

Each adapter also has `kind`, `name`, `resource`, `stub`, `state()` (GetResourceState of its resource) and
`available()` (`state() == 'started'`).

## Adapters

| Kind | Config value | File | Resource | Status |
|---|---|---|---|---|
| housing | `none` | `housing/none.lua` | – | done |
| housing | `ps-housing` (default) | `housing/ps_housing.lua` | ps-housing | stub, task 6.2 |
| housing | `qbx_properties` | `housing/qbx_properties.lua` | qbx_properties | stub, task 6.2 |
| housing | `ox_doorlock-only` | `housing/ox_doorlock_only.lua` | ox_doorlock | stub, task 6.2 |
| garage | `none` | `garage/none.lua` | – | done |
| garage | `qbx_garages` (default) | `garage/qbx_garages.lua` | qbx_garages | stub, task 3.4 |
| garage | `qb-garages` (QBCore) | `garage/qb_garages.lua` | qb-garages + `patches/qb-garages.10-fredpd-events.patch` | done (docs/modules/adapters-qb.md) |
| prison | `none` (default until task 4.1) | `prison/none.lua` | – | done |
| prison | `xt-prison` (default per Decision 2) | `prison/xt_prison.lua` | xt-prison (qb-core or qbx_core bridge) | done (docs/modules/adapters-qb.md) |
| prison | `qbx_prison` (**opt-in, insecure unpatched**) | `prison/qbx_prison.lua` | qbx_prison | stub, task 4.1 |
| prison | `qbx_police-jail` (metadata only, no confinement) | `prison/qbx_police_jail.lua` | qbx_policejob | stub, task 4.1 |

**qbx_prison must not run on a FredPD server as shipped**: its net event `qbx_prison:server:onGateHackDone` lets any
client unlock any ox_doorlock door (station doors, fredpd_breach targets), and clients can clear or set their own
sentence (docs/deps-verification.md §2a). The adapter stays only for servers that already run it with those events
patched, and logs a warning at every start when selected. qbx_police has no jail of its own (§2): the
`qbx_police-jail` adapter can at most set metadata and also warns when selected; the old alias `qbx_police` was
removed (it now counts as an unknown name and falls back to `none`).

An adapter may carry a `caution` (see `base.lua`), logged once whenever it is selected. The loader logs **one**
warning per configured adapter whose resource is not available: at once when the resource
is not installed (`missing`); otherwise once after a deferred re-check (15 s after fredpd_core starts, so a resource
ensured later in server.cfg is not reported), or at the first call made while it is down, whichever comes first.
An unknown config value gets one warning and falls back to `none`. Start the integrated resources before
fredpd_core in server.cfg anyway (see `server.cfg.example`).

## Adding a script

1. Add `adapters/<kind>/<name_with_underscores>.lua` returning
   `require('adapters.base').define({ kind = '<kind>', name = '<config value>', resource = '<resource>', methods = { ... } })`.
2. Implement the methods you can; leave the rest out (they stay no-ops).
3. Put the config value in `config/integrations.json`. No other code changes.

Never copy code from the integrated script; call its exports/events. Record verified export and event names in
`docs/deps-verification.md`.
