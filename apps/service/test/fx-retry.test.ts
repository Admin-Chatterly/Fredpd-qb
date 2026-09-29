// SPDX-License-Identifier: GPL-3.0-only
// src/fx-retry.ts: grant pushes/recomputes that did not reach FXServer are redelivered as one /recompute of the
// pending ids after 2 s, 10 s and 30 s (one-shot timers, armed only while something is pending), then with the next
// successful FX call; 4xx answers are not retried. No database.
import { describe, expect, it } from 'vitest';
import type { FxResult } from '../src/fx';
import { FX_RETRY_DELAYS_MS, FxRetry } from '../src/fx-retry';
import { silentLogger } from '../src/log';
import { FakeFx } from './helpers';

const OK: FxResult = { ok: true, status: 200, body: { ok: true } };
const DOWN: FxResult = { ok: false, status: 0, error: 'timeout' };
const REFUSED: FxResult = { ok: false, status: 400, error: 'invalid_body' };
const SERVER_ERROR: FxResult = { ok: false, status: 500, error: 'internal' };

/** Manual timers: `due` lists the armed delays; fire() runs the armed one. */
function timers() {
  const armed = new Map<number, { fn: () => void; ms: number }>();
  let next = 1;
  return {
    setTimer: (fn: () => void, ms: number) => {
      const id = next++;
      armed.set(id, { fn, ms });
      return id;
    },
    clearTimer: (h: unknown) => {
      armed.delete(h as number);
    },
    get due(): number[] {
      return [...armed.values()].map((t) => t.ms);
    },
    async fire(): Promise<void> {
      const [id, t] = [...armed.entries()][0] ?? [];
      if (id === undefined || !t) throw new Error('no timer armed');
      armed.delete(id);
      t.fn();
      await new Promise((r) => setTimeout(r, 0));
    },
  };
}

function setup() {
  const fx = new FakeFx();
  const clock = timers();
  const retry = new FxRetry({ fx, log: silentLogger, setTimer: clock.setTimer, clearTimer: clock.clearTimer });
  return { fx, clock, retry };
}

describe('FxRetry', () => {
  it('a failed push arms one timer; the retry sends /recompute for the pending ids and clears them', async () => {
    const { fx, clock, retry } = setup();
    retry.track(DOWN, ['1']);
    retry.track(DOWN, ['2', '1']);
    expect(clock.due).toEqual([FX_RETRY_DELAYS_MS[0]]);
    expect(retry.pending).toEqual({ all: false, discordIds: ['1', '2'] });
    await clock.fire();
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: ['1', '2'] }]);
    expect(retry.hasPending).toBe(false);
    expect(clock.due).toEqual([]);
  });

  it('backs off 2 s, 10 s, 30 s, then waits for the next successful FX call', async () => {
    const { fx, clock, retry } = setup();
    fx.ok = false;
    retry.track(SERVER_ERROR, ['1']);
    for (const ms of FX_RETRY_DELAYS_MS) {
      expect(clock.due).toEqual([ms]);
      await clock.fire();
    }
    expect(clock.due).toEqual([]); // no timer left: nothing polls while FXServer stays down
    expect(retry.pending.discordIds).toEqual(['1']);
    expect(fx.of('recompute')).toHaveLength(3);
    fx.ok = true;
    retry.track(OK, ['9']); // some other push got through
    await new Promise((r) => setTimeout(r, 0));
    expect(fx.of('recompute').at(-1)).toEqual({ kind: 'recompute', discordIds: ['1'] });
    expect(retry.hasPending).toBe(false);
  });

  it('"everyone online" absorbs single ids; a recompute of all goes out as {}', async () => {
    const { fx, clock, retry } = setup();
    retry.track(DOWN, ['1']);
    retry.track(DOWN, undefined);
    retry.track(DOWN, ['2']);
    expect(retry.pending).toEqual({ all: true, discordIds: [] });
    await clock.fire();
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: undefined }]);
  });

  it('4xx answers are not retried; successes with nothing pending do nothing', async () => {
    const { fx, clock, retry } = setup();
    retry.track(REFUSED, ['1']);
    retry.track(OK, ['2']);
    expect(clock.due).toEqual([]);
    expect(fx.calls).toEqual([]);
    expect(retry.hasPending).toBe(false);
  });

  it('a success while a retry is armed redelivers at once and disarms the timer', async () => {
    const { fx, clock, retry } = setup();
    retry.track(DOWN, ['1']);
    expect(clock.due).toHaveLength(1);
    retry.succeeded();
    await new Promise((r) => setTimeout(r, 0));
    expect(clock.due).toEqual([]);
    expect(fx.of('recompute')).toEqual([{ kind: 'recompute', discordIds: ['1'] }]);
  });

  it('close() disarms and stops redelivery', async () => {
    const { fx, clock, retry } = setup();
    retry.track(DOWN, ['1']);
    retry.close();
    expect(clock.due).toEqual([]);
    retry.succeeded();
    await new Promise((r) => setTimeout(r, 0));
    expect(fx.calls).toEqual([]);
  });
});
