// SPDX-License-Identifier: GPL-3.0-only
// Injected time source, so tests can pin session expiry, HMAC skew and computedAt.

export interface Clock {
  now(): Date;
}

export const systemClock: Clock = { now: () => new Date() };

export function unixSeconds(clock: Clock): number {
  return Math.floor(clock.now().getTime() / 1000);
}
