// SPDX-License-Identifier: GPL-3.0-only
// Tablet NUI: index.html plus hashed chunks under assets/, with relative paths, so FiveM serves them from
// fredpd_mdt/web/build (scripts/build.mjs copies dist/ there; fredpd_mdt's fxmanifest lists `web/build/**/*`).
// Real code splitting (no single-file inlining since Phase 3–5b): every section page is a React.lazy chunk and
// Cytoscape lives only in the Nätverk graph chunk, so the main chunk that the first paint after `open` needs stays
// small (docs/modules/ui.md "Bundle").
//
// No @vitejs/plugin-react: 6.x needs Vite 8 while this app pins Vite 7 (docs/modules/ui.md, open questions).
// esbuild compiles JSX with the automatic runtime; the only loss is React Fast Refresh in dev.
import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  base: './',
  plugins: [tailwindcss()],
  esbuild: { jsx: 'automatic' },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    assetsDir: 'assets',
    // FiveM's CEF is Chromium based; ES2022 keeps the output small without relying on the newest syntax.
    target: 'es2022',
    // CEF supports <link rel="modulepreload">; the polyfill would only add code to the main chunk.
    modulePreload: { polyfill: false },
    reportCompressedSize: true,
    // Cytoscape (~445 kB) is its own lazy chunk. The eager third-party code (react, react-dom, react-router, TanStack
    // Query, zod) goes into a separate `vendor` chunk: it changes far less often than the app code, so CEF's cache
    // keeps it across FredPD releases, and the app's own main chunk stays small. Only packages the entry imports
    // statically are listed, so nothing lazy (cytoscape, @tanstack/virtual) is pulled into the eager vendor chunk.
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
    // The vendor chunk is ~400 kB (react-dom and zod dominate); 600 kB keeps the warning for real growth.
    chunkSizeWarningLimit: 600,
  },
  server: { port: 5174, strictPort: true },
});
