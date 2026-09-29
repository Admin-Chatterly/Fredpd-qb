// SPDX-License-Identifier: GPL-3.0-only
// Tablet NUI: one self-contained index.html (JS and CSS inlined) with relative paths, so FiveM can serve it from
// fredpd_mdt/web/build (scripts/build.mjs copies dist/ there).
//
// No @vitejs/plugin-react: 6.x needs Vite 8 while this app pins Vite 7 (docs/modules/ui.md, open questions).
// esbuild compiles JSX with the automatic runtime; the only loss is React Fast Refresh in dev.
import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';
import { viteSingleFile } from 'vite-plugin-singlefile';

export default defineConfig({
  base: './',
  plugins: [tailwindcss(), viteSingleFile()],
  esbuild: { jsx: 'automatic' },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // FiveM's CEF is Chromium based; ES2022 keeps the output small without relying on the newest syntax.
    target: 'es2022',
    reportCompressedSize: false,
  },
  server: { port: 5174, strictPort: true },
});
