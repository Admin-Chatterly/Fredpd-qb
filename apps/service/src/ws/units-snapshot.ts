// SPDX-License-Identifier: GPL-3.0-only
// The newest on-duty roster fredpd_dispatch sent as `unitsChanged` (UnitsPushSchema, docs/contracts.md §C13), kept
// in memory for GET /api/units, so a portal page that just opened has a roster before the next change arrives.
// Best effort: the service holds only what FXServer last posted. After a service restart it is empty until the
// roster changes again (fredpd_dispatch does not re-post an unchanged roster), and while FXServer is down it keeps
// the last roster it saw. `receivedAt` tells how old it is.
import type { z } from 'zod';
import type { UnitsPushSchema } from '@fredpd/types/dispatch';

export type UnitsPush = z.infer<typeof UnitsPushSchema>;

export class UnitsSnapshot {
  private last: UnitsPush | null = null;
  private at: Date | null = null;

  set(push: UnitsPush, receivedAt: Date): void {
    this.last = push;
    this.at = receivedAt;
  }

  /** The newest roster, or an empty one when none arrived since the service started. */
  get(): UnitsPush {
    return this.last ?? { units: [] };
  }

  get receivedAt(): Date | null {
    return this.at;
  }
}
