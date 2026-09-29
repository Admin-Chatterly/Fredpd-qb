// SPDX-License-Identifier: GPL-3.0-only
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      { test: { name: 'types', root: './packages/types', include: ['test/**/*.test.ts'], environment: 'node' } },
      { test: { name: 'ui', root: './packages/ui', include: ['test/**/*.test.{ts,tsx}'], environment: 'jsdom' } },
      { test: { name: 'service', root: './apps/service', include: ['test/**/*.test.ts'], environment: 'node' } },
      { test: { name: 'nui', root: './apps/nui', include: ['test/**/*.test.{ts,tsx}'], environment: 'jsdom' } },
      { test: { name: 'portal', root: './apps/portal', include: ['test/**/*.test.{ts,tsx}'], environment: 'jsdom' } },
      { test: { name: 'resources', root: './resources', include: ['**/test/**/*.test.{js,ts}'], environment: 'node' } },
    ],
  },
});
