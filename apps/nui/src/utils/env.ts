// SPDX-License-Identifier: GPL-3.0-only
// FiveM's NUI (CEF) defines window.GetParentResourceName(); a normal browser does not. Its absence switches the
// tablet into mock mode (fetchNui answers from registered mocks, debugData can simulate Lua messages).

declare global {
  interface Window {
    /** Present only inside FiveM NUI: the name of the resource hosting this page (fredpd_mdt). */
    GetParentResourceName?: () => string;
  }
}

export function isEnvBrowser(): boolean {
  return typeof window.GetParentResourceName !== 'function';
}

/** Resource name for NUI callback URLs; `fredpd_mdt` in a browser. */
export function resourceName(): string {
  return window.GetParentResourceName?.() ?? 'fredpd_mdt';
}

/**
 * Development build: `vite` (dev server) or `pnpm --filter @fredpd/nui build:dev` (`vite build --mode development`,
 * which keeps NODE_ENV=production, so import.meta.env.DEV alone would be false there). Enables the open -> first
 * paint log and missing-key warnings.
 */
export const IS_DEV_BUILD: boolean = import.meta.env.DEV || import.meta.env.MODE === 'development';
