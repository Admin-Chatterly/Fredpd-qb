// SPDX-License-Identifier: GPL-3.0-only
// Environment configuration of fredpd_service (apps/service/.env, see .env.example). Validated once at start;
// a bad value stops the process with a list of the offending variable names (values are never echoed).
import { z } from 'zod';
import { HMAC_MIN_SECRET_LENGTH } from '@fredpd/types/hmac';

/**
 * Placeholders from examples and docs. They pass a length check but are public, so a service started with one would
 * accept pushes signed by anyone who read the repository. Same list as fredpd_core/server/http.js, which refuses the
 * same values on the FXServer side.
 */
const PLACEHOLDER_SECRET_RE = /change[_\s-]?me|placeholder|your[_\s-]?secret|^(.)\1+$/i;

const PLACEHOLDER = 'is still a placeholder value';
const notPlaceholder = (s: string) => !PLACEHOLDER_SECRET_RE.test(s);

const secret = (min: number) => z.string().min(min, `must be at least ${min} characters`).refine(notPlaceholder, PLACEHOLDER);

/** Discord credentials: any non-empty string, but not the .env.example placeholder. */
const credential = z.string().min(1).refine(notPlaceholder, PLACEHOLDER);

const snowflake = z
  .string()
  .regex(/^\d{17,20}$/, 'must be a Discord id (17–20 digits)')
  // 000000000000000000 in .env.example; no real id repeats one digit.
  .refine((s) => !/^(\d)\1+$/.test(s), PLACEHOLDER);

/** The password part of a mysql:// URL, decoded ('' when there is none). */
function urlPassword(url: string): string {
  const raw = new URL(url).password;
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

/** `true/false/1/0/yes/no`, case-insensitive; anything else is an error rather than a silent false. */
const bool = (fallback: boolean) =>
  z
    .string()
    .optional()
    .transform((v, ctx) => {
      if (v === undefined || v.trim() === '') return fallback;
      const s = v.trim().toLowerCase();
      if (['true', '1', 'yes'].includes(s)) return true;
      if (['false', '0', 'no'].includes(s)) return false;
      ctx.issues.push({ code: 'custom', message: 'must be true or false', input: v });
      return z.NEVER;
    });

const httpUrl = z
  .url({ protocol: /^https?$/ })
  .transform((u) => u.replace(/\/+$/, ''));

export const OFFICER_NAME_SOURCES = ['discord_nick', 'discord_global', 'character'] as const;
export type OfficerNameSource = (typeof OFFICER_NAME_SOURCES)[number];

export const ConfigSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  HOST: z.string().min(1).default('127.0.0.1'),
  FREDPD_DB_URL: z.url({ protocol: /^mysql$/ }).refine((u) => notPlaceholder(urlPassword(u)), `password ${PLACEHOLDER}`),
  FREDPD_HMAC_SECRET: secret(HMAC_MIN_SECRET_LENGTH),
  FXSERVER_URL: httpUrl.default('http://127.0.0.1:30120'),
  DISCORD_CLIENT_ID: snowflake,
  DISCORD_CLIENT_SECRET: credential,
  DISCORD_BOT_TOKEN: credential,
  DISCORD_GUILD_ID: snowflake,
  /** Public base URL of this service (OAuth callback, avatar URLs, allowed WebSocket origin). */
  PUBLIC_URL: httpUrl,
  /** Signs the session cookie (@fastify/cookie). Must differ from FREDPD_HMAC_SECRET (checked below). */
  SESSION_SECRET: secret(32),
  /** Relative paths resolve against the service's working directory (apps/service). */
  UPLOAD_DIR: z.string().min(1).default('data/uploads'),
  /** The built portal SPA (pnpm build → apps/portal/dist), served at / (relative to apps/service). */
  PORTAL_DIR: z.string().min(1).default('../portal/dist'),
  OFFICER_NAME_SOURCE: z.enum(OFFICER_NAME_SOURCES).default('discord_nick'),
  /** Only false for plain-http development; the portal runs behind HTTPS (Cloudflare Tunnel or Caddy). */
  COOKIE_SECURE: bool(true),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']).default('info'),
}).superRefine((c, ctx) => {
  // One leaked value must not give both FXServer's push rights and forged session cookies.
  if (c.SESSION_SECRET === c.FREDPD_HMAC_SECRET) {
    ctx.addIssue({ code: 'custom', path: ['SESSION_SECRET'], message: 'must differ from FREDPD_HMAC_SECRET' });
  }
});
export type Config = z.infer<typeof ConfigSchema>;

export class ConfigError extends Error {
  override name = 'ConfigError';
}

/** Parses the environment. Throws ConfigError naming each bad variable and why (never its value). */
export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  // Treat empty strings as unset so `KEY=` in .env falls back to the default instead of failing validation.
  const cleaned = Object.fromEntries(Object.entries(env).filter(([, v]) => v !== undefined && v !== ''));
  const result = ConfigSchema.safeParse(cleaned);
  if (result.success) return result.data;
  const lines = result.error.issues.map((i) => `  ${i.path.join('.') || '(root)'}: ${i.message}`);
  throw new ConfigError(`invalid fredpd_service configuration (apps/service/.env):\n${lines.join('\n')}`);
}
