// SPDX-License-Identifier: GPL-3.0-only
// Minimal structured logger for the parts outside a request (Discord bot, FXServer client, start-up). Requests log
// through Fastify's own pino logger; both write one JSON object per line to stdout, so NSSM captures one stream.

export type LogLevel = 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace' | 'silent';

/** The subset of pino's interface the service uses; Fastify's `app.log` satisfies it too. */
export interface Logger {
  error(obj: unknown, msg?: string): void;
  warn(obj: unknown, msg?: string): void;
  info(obj: unknown, msg?: string): void;
  debug(obj: unknown, msg?: string): void;
}

const RANK: Record<LogLevel, number> = { trace: 10, debug: 20, info: 30, warn: 40, error: 50, fatal: 60, silent: Infinity };

function serialise(value: unknown): unknown {
  if (value instanceof Error) return { type: value.name, message: value.message, stack: value.stack };
  return value;
}

/** pino-compatible JSON lines: `{ level, time, name, msg, ...fields }`; `err` fields are serialised. */
export function createLogger(name: string, level: LogLevel = 'info', write: (line: string) => void = (l) => process.stdout.write(`${l}\n`)): Logger {
  const min = RANK[level];
  const emit = (lvl: Exclude<LogLevel, 'silent'>, obj: unknown, msg?: string) => {
    if (RANK[lvl] < min) return;
    const base: Record<string, unknown> = { level: RANK[lvl], time: Date.now(), name };
    if (typeof obj === 'string') {
      base.msg = obj;
    } else if (obj instanceof Error) {
      base.err = serialise(obj);
      base.msg = msg ?? obj.message;
    } else if (obj && typeof obj === 'object') {
      for (const [k, v] of Object.entries(obj)) base[k] = serialise(v);
      if (msg !== undefined) base.msg = msg;
    } else if (msg !== undefined) {
      base.msg = msg;
    }
    write(JSON.stringify(base));
  };
  return {
    error: (o, m) => emit('error', o, m),
    warn: (o, m) => emit('warn', o, m),
    info: (o, m) => emit('info', o, m),
    debug: (o, m) => emit('debug', o, m),
  };
}

/** Logger that drops everything (tests). */
export const silentLogger: Logger = { error() {}, warn() {}, info() {}, debug() {} };
