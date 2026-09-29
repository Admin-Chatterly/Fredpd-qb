// SPDX-License-Identifier: GPL-3.0-only
// src/db/schema.ts mirrors the SQL of db/migrations: every drizzle column exists in the migrated database with the
// same nullability. Skips when MariaDB is unreachable.
import { getTableConfig } from 'drizzle-orm/mysql-core';
import { afterAll, describe, expect, it } from 'vitest';
import { schema } from '../src/db/schema';
import { rows, setupTestDb, TEST_DB } from './helpers';

const database = await setupTestDb('schema.test');

describe.skipIf(!database)('drizzle schema vs migrations (DB)', () => {
  afterAll(async () => {
    await database?.close();
  });

  for (const table of Object.values(schema)) {
    const cfg = getTableConfig(table);
    it(`${cfg.name} matches information_schema`, async () => {
      const cols = await rows<{ COLUMN_NAME: string; IS_NULLABLE: string }>(
        database!,
        'SELECT COLUMN_NAME, IS_NULLABLE FROM information_schema.columns WHERE table_schema = ? AND table_name = ?',
        [TEST_DB, cfg.name],
      );
      const actual = new Map(cols.map((c) => [c.COLUMN_NAME, c.IS_NULLABLE === 'YES']));
      expect(actual.size, `${cfg.name} exists`).toBeGreaterThan(0);
      for (const col of cfg.columns) {
        expect(actual.has(col.name), `${cfg.name}.${col.name} exists`).toBe(true);
        expect(actual.get(col.name), `${cfg.name}.${col.name} nullable`).toBe(!col.notNull);
      }
      // Every SQL column is known to drizzle (a new column must be mirrored here or deliberately left out).
      expect([...actual.keys()].sort()).toEqual(cfg.columns.map((c) => c.name).sort());
    });
  }
});
