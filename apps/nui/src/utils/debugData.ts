// SPDX-License-Identifier: GPL-3.0-only
// Browser-only stand-in for SendNUIMessage: dispatches the given messages as window "message" events, the way CEF
// delivers them from Lua. No-op inside FiveM. Delivered after `delayMs` (a single timeout, not a timer loop) so
// the React listeners are attached first.
import { isEnvBrowser } from './env';
import type { NuiMessage } from '../tablet/messages';

export function debugData(messages: readonly NuiMessage[], delayMs = 0): void {
  if (!isEnvBrowser()) return;
  window.setTimeout(() => {
    for (const data of messages) window.dispatchEvent(new MessageEvent('message', { data }));
  }, delayMs);
}
