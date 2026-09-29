// SPDX-License-Identifier: GPL-3.0-only
// Portal SPA. In dev, the service's routes are proxied so the session cookie and CSRF token stay same-origin
// (set PUBLIC_URL=http://localhost:5173 in apps/service/.env so the OAuth callback and the /ws Origin check match).
//
// No @vitejs/plugin-react: 6.x needs Vite 8 while this app pins Vite 7 (docs/modules/ui.md, open questions).
// esbuild compiles JSX with the automatic runtime; the only loss is React Fast Refresh in dev.
import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';

const SERVICE = 'http://127.0.0.1:3000';

export default defineConfig({
  plugins: [tailwindcss()],
  esbuild: { jsx: 'automatic' },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2022',
    reportCompressedSize: true,
    // Same split as the tablet (apps/nui/vite.config.ts): the shared MDT pages are lazy chunks (src/mdt/pages.tsx),
    // Cytoscape stays in the graph chunk, and the eager third-party code gets its own long-cached vendor chunk.
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (/[\\/]node_modules[\\/](react|react-dom|scheduler|react-router|@tanstack[\\/](query-core|react-query)|zod)[\\/]/.test(id)) {
            return 'vendor';
          }
          return undefined;
        },
      },
    },
    chunkSizeWarningLimit: 600,
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': SERVICE,
      '/auth': SERVICE,
      '/avatar': SERVICE,
      '/ws': { target: SERVICE, ws: true },
    },
  },
});
