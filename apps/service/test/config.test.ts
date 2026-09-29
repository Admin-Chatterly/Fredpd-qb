// SPDX-License-Identifier: GPL-3.0-only
// src/config.ts: defaults, validation, placeholders (secrets, Discord credentials and ids, database password) and a
// reused secret refused, errors name variables but never values.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import dotenv from 'dotenv';
import { describe, expect, it } from 'vitest';
import { ConfigError, ConfigSchema, loadConfig } from '../src/config';
import { ROOT } from './helpers';

const valid = {
  FREDPD_DB_URL: 'mysql://fredpd:pw@127.0.0.1:3306/fredpd',
  FREDPD_HMAC_SECRET: 'k2Jf9sL0qPz8xW3vT7yB1nM4cR6dG5hA',
  DISCORD_CLIENT_ID: '200000000000000000',
  DISCORD_CLIENT_SECRET: 'secret',
  DISCORD_BOT_TOKEN: 'token',
  DISCORD_GUILD_ID: '100000000000000000',
  PUBLIC_URL: 'https://polis.example.se/',
  SESSION_SECRET: 'Zx8Qw2Er4Ty6Ui8Op0As2Df4Gh6Jk8Lz',
};

describe('loadConfig', () => {
  it('applies the defaults', () => {
    const c = loadConfig(valid);
    expect(c).toMatchObject({
      PORT: 3000,
      HOST: '127.0.0.1',
      FXSERVER_URL: 'http://127.0.0.1:30120',
      UPLOAD_DIR: 'data/uploads',
      OFFICER_NAME_SOURCE: 'discord_nick',
      COOKIE_SECURE: true,
      PUBLIC_URL: 'https://polis.example.se',
    });
  });

  it('parses overrides and treats empty values as unset', () => {
    const c = loadConfig({ ...valid, PORT: '8080', COOKIE_SECURE: 'false', OFFICER_NAME_SOURCE: 'discord_global', HOST: '' });
    expect(c).toMatchObject({ PORT: 8080, COOKIE_SECURE: false, OFFICER_NAME_SOURCE: 'discord_global', HOST: '127.0.0.1' });
  });

  it('refuses short or placeholder secrets and bad values, naming the variables but not the values', () => {
    const bad = { ...valid, FREDPD_HMAC_SECRET: 'CHANGE_ME_to_a_long_random_string_please', SESSION_SECRET: 'short', COOKIE_SECURE: 'maybe', DISCORD_GUILD_ID: 'abc', OFFICER_NAME_SOURCE: 'nick' };
    let err: unknown;
    try {
      loadConfig(bad);
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(ConfigError);
    const msg = (err as Error).message;
    for (const key of ['FREDPD_HMAC_SECRET', 'SESSION_SECRET', 'COOKIE_SECURE', 'DISCORD_GUILD_ID', 'OFFICER_NAME_SOURCE']) expect(msg).toContain(key);
    expect(msg).not.toContain('CHANGE_ME_to_a_long');
    expect(() => loadConfig({ ...valid, FREDPD_DB_URL: 'postgres://x' })).toThrow(ConfigError);
    expect(() => loadConfig({})).toThrow(/FREDPD_DB_URL/);
  });

  it('refuses every placeholder of .env.example (Discord credentials, all-zero ids, database password)', () => {
    const example = dotenv.parse(readFileSync(join(ROOT, 'apps', 'service', '.env.example'), 'utf8'));
    let msg = '';
    try {
      loadConfig(example);
    } catch (e) {
      msg = (e as Error).message;
    }
    const named = new Set([...msg.matchAll(/^ {2}([A-Z_]+):/gm)].map((m) => m[1]));
    expect(named).toEqual(
      new Set(['FREDPD_DB_URL', 'FREDPD_HMAC_SECRET', 'DISCORD_CLIENT_ID', 'DISCORD_CLIENT_SECRET', 'DISCORD_BOT_TOKEN', 'DISCORD_GUILD_ID', 'SESSION_SECRET']),
    );
    expect(msg).not.toContain('CHANGE_ME');
    // One at a time, on an otherwise valid configuration.
    for (const [key, value] of [
      ['DISCORD_CLIENT_SECRET', 'CHANGE_ME'],
      ['DISCORD_BOT_TOKEN', 'change-me'],
      ['DISCORD_CLIENT_ID', '000000000000000000'],
      ['FREDPD_DB_URL', 'mysql://fredpd:CHANGE_ME@127.0.0.1:3306/fredpd'],
      ['FREDPD_DB_URL', 'mysql://fredpd:%43hange%4De@127.0.0.1:3306/fredpd'],
    ] as const) {
      expect(() => loadConfig({ ...valid, [key]: value }), `${key}=${value}`).toThrow(new RegExp(`${key}: .*placeholder`));
    }
    // A database URL without a password is not a placeholder.
    expect(loadConfig({ ...valid, FREDPD_DB_URL: 'mysql://fredpd@127.0.0.1:3306/fredpd' }).FREDPD_DB_URL).toContain('fredpd@');
  });

  it('refuses a SESSION_SECRET equal to FREDPD_HMAC_SECRET', () => {
    expect(() => loadConfig({ ...valid, SESSION_SECRET: valid.FREDPD_HMAC_SECRET })).toThrow(/SESSION_SECRET: must differ from FREDPD_HMAC_SECRET/);
  });

  it('.env.example lists every variable of the schema', () => {
    const example = readFileSync(join(ROOT, 'apps', 'service', '.env.example'), 'utf8');
    const listed = new Set([...example.matchAll(/^#?\s*([A-Z][A-Z0-9_]+)=/gm)].map((m) => m[1]));
    for (const key of Object.keys(ConfigSchema.shape)) expect(listed, key).toContain(key);
  });
});
