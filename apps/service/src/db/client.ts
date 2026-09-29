// SPDX-License-Identifier: GPL-3.0-only
// mysql2 pool + drizzle. DATETIME columns hold UTC (docs/contracts.md §C7) whatever the MariaDB server or session
// time zone is: defaults are (UTC_TIMESTAMP()) and SQL never reads the session clock, so sessions keep the server's
// zone. `timezone: 'Z'` makes mysql2 write JS Dates as UTC text and read DATETIME into Dates as UTC (raw pool
// queries); drizzle reads DATETIME as text and appends 'Z' itself (schema.ts `utc()`). test/utc.test.ts proves the
// round trip with the session at +02:00.
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
  const db = drizzle({ client: pool, schema, mode: 'default' });
  return { db, pool, close: () => pool.end() };
}
