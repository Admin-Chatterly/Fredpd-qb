// SPDX-License-Identifier: GPL-3.0-only
// fredpd_service entry point: `pnpm --filter @fredpd/service start` (tsx). Reads apps/service/.env, checks the
// database schema, starts HTTP, then the Discord bot; SIGINT/SIGTERM (NSSM stop) shut down in reverse order.
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { sql } from 'drizzle-orm';
import { buildApp } from './app';
import { systemClock } from './clock';
import { ConfigError, loadConfig } from './config';
import { createDatabase } from './db/client';
import { createDiscordBot } from './discord/bot';
import { createFxClient } from './fx';
import { createLogger } from './log';

async function main(): Promise<void> {
  dotenv.config({ path: fileURLToPath(new URL('../.env', import.meta.url)), quiet: true });
  const config = loadConfig();
  const log = createLogger('fredpd_service', config.LOG_LEVEL);

  const database = createDatabase(config.FREDPD_DB_URL);
  try {
    // 009_service.sql is applied by fredpd_core on FXServer start or by `node scripts/migrate.mjs`.
    await database.db.execute(sql`SELECT 1 FROM fredpd_sessions LIMIT 0`);
  } catch (err) {
    log.error({ err }, 'database not reachable or not migrated (run `node scripts/migrate.mjs` or start FXServer once)');
    await database.close();
    process.exitCode = 1;
    return;
  }

  const fx = createFxClient({ baseUrl: config.FXSERVER_URL, secret: config.FREDPD_HMAC_SECRET, log });
  // Set below; the bot only calls onFatal after login, when it is.
  let shutdown: (signal: string) => Promise<void> = async () => {};
  const bot = createDiscordBot({
    token: config.DISCORD_BOT_TOKEN,
    guildId: config.DISCORD_GUILD_ID,
    log,
    // The guild or its members could not be (re)loaded: grants cannot be resolved. Exit so NSSM restarts us
    // instead of answering 503 forever.
    onFatal: () => {
      process.exitCode = 1;
      void shutdown('discord-failed');
    },
  });
  const app = await buildApp({ config, db: database.db, gateway: bot, fx, clock: systemClock, log });
  bot.attach(app.fredpd.sync);
  if (config.OFFICER_NAME_SOURCE === 'character') {
    log.warn({}, 'OFFICER_NAME_SOURCE=character: officer names are not synced from Discord');
  }

  let stopping = false;
  shutdown = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    log.info({ signal }, 'shutting down');
    try {
      await bot.stop();
      await app.close();
      await database.close();
    } catch (err) {
      log.error({ err }, 'error during shutdown');
      process.exitCode = 1;
    }
  };
  process.once('SIGINT', () => void shutdown('SIGINT'));
  process.once('SIGTERM', () => void shutdown('SIGTERM'));

  await app.listen({ port: config.PORT, host: config.HOST });
  const ping = await fx.ping();
  log.info({ fxserver: ping.ok ? 'reachable' : ping.error }, 'FXServer bridge check');
  try {
    await bot.start();
  } catch (err) {
    // Without the gateway no grants can be resolved; stop so the service manager (NSSM) restarts us.
    log.error({ err }, 'Discord login failed (check DISCORD_BOT_TOKEN)');
    await shutdown('discord-login-failed');
    process.exitCode = 1;
  }
}

main().catch((err: unknown) => {
  if (err instanceof ConfigError) {
    process.stderr.write(`${err.message}\n`);
  } else {
    process.stderr.write(`fredpd_service failed to start: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`);
  }
  process.exitCode = 1;
});
