// SPDX-License-Identifier: GPL-3.0-only
// NUI -> Lua calls (IMPLEMENTATION.md §4.3): POST https://<resource>/<action> with a JSON body, answered by the
// matching RegisterNUICallback in fredpd_mdt. Written for FredPD after the pattern bub-mdt uses (GPL-3.0).
//
// Outside FiveM (isEnvBrowser) nothing is posted: the call resolves with `mockData`, else with the mock registered
// for the action (registerNuiMock), else with undefined. Mocks are registered by src/mock (dev) and by tests.
import { isEnvBrowser, resourceName } from './env';

export class NuiRequestError extends Error {
  constructor(
    readonly action: string,
    readonly status: number,
  ) {
    super(`NUI callback "${action}" failed with HTTP ${status}`);
    this.name = 'NuiRequestError';
  }
}

export type NuiMockHandler = (data: unknown) => unknown;

const mocks = new Map<string, NuiMockHandler>();

/** Registers the browser-mode answer for an action. Returns a function that removes it. */
export function registerNuiMock(action: string, handler: NuiMockHandler): () => void {
  mocks.set(action, handler);
  return () => {
    if (mocks.get(action) === handler) mocks.delete(action);
  };
}

export function clearNuiMocks(): void {
  mocks.clear();
}

export async function fetchNui<T = unknown>(action: string, data?: unknown, mockData?: T): Promise<T> {
  if (isEnvBrowser()) {
    if (mockData !== undefined) return mockData;
    const mock = mocks.get(action);
    return (mock ? await mock(data) : undefined) as T;
  }

  const response = await fetch(`https://${resourceName()}/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data ?? {}),
  });
  if (!response.ok) throw new NuiRequestError(action, response.status);
  // A callback that answers cb() or cb('') has an empty body.
  const text = await response.text();
  return (text === '' ? undefined : JSON.parse(text)) as T;
}
