// SPDX-License-Identifier: GPL-3.0-only
// mysql2 pool + drizzle. Every connection runs in UTC (docs/contracts.md §C7): DATETIME values are UTC, and the
// CURRENT_TIMESTAMP defaults must be UTC too, whatever the server's default zone is.
import { drizzle } from 'drizzle-orm/mysql2';
import type { MySql2Database } from 'drizzle-orm/mysql2';
import mysql from 'mysql2/promise';
import type { Pool } from 'mysql2/promise';
import { schema } from './schema';

export type Db = MySql2Database<typeof schema>;

export interface Database {
  db: Db;
  pool: Pool;
  close(): Promise<void>;
}

export function createDatabase(url: string, opts: { connectionLimit?: number } = {}): Database {
  const pool = mysql.createPool({
    uri: url,
    charset: 'utf8mb4',
    timezone: 'Z',
    connectionLimit: opts.connectionLimit ?? 10,
    // Pool connections are opened lazily, so a test that never queries never connects.
    waitForConnections: true,
    enableKeepAlive: true,
  });
  // 'connection' hands over the callback-style core connection of each new pooled connection.
  pool.on('connection', (conn) => {
    conn.query("SET time_zone = '+00:00'");
  });
  const db = drizzle({ client: pool, schema, mode: 'default' });
  return { db, pool, close: () => pool.end() };
}
