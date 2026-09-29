import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';

export default tseslint.config(
  {
    ignores: [
      '**/node_modules/**', '**/dist/**', '**/build/**', '**/coverage/**',
      'resources/[[]upstream[]]/**', 'resources/**/web/build/**', 'playwright-report/**', 'test-results/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: { globals: { ...globals.browser, ...globals.node } },
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      '@typescript-eslint/consistent-type-imports': 'error',
    },
  },
  {
    files: ['apps/nui/**/*.{ts,tsx}', 'apps/portal/**/*.{ts,tsx}', 'packages/ui/**/*.{ts,tsx}'],
    plugins: { 'react-hooks': reactHooks },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // IMPLEMENTATION.md §4.7: no timers that run while the tablet is idle.
      'no-restricted-globals': ['error', { name: 'setInterval', message: 'No polling (§4.7). Use events, TanStack Query refetch-on-focus or a debounce.' }],
      'no-restricted-properties': ['error', { object: 'window', property: 'setInterval', message: 'No polling (§4.7).' }],
    },
  },
  {
    files: ['**/*.{js,mjs,cjs}'],
    languageOptions: { globals: { ...globals.node } },
  },
  {
    // FiveM server JS runtime (fredpd_core/server/http.js)
    files: ['resources/**/*.js'],
    languageOptions: {
      sourceType: 'commonjs',
      globals: {
        ...globals.node, SetHttpHandler: 'readonly', GetConvar: 'readonly', exports: 'writable',
        on: 'readonly', emit: 'readonly', onNet: 'readonly', GetCurrentResourceName: 'readonly', setImmediate: 'readonly',
      },
    },
    rules: { '@typescript-eslint/no-require-imports': 'off' },
  },
);
