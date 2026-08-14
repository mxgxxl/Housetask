// ESLint 9 flat config (TD-012).
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import tsParser from '@typescript-eslint/parser';
import tsPlugin from '@typescript-eslint/eslint-plugin';
import prettierConfig from 'eslint-config-prettier';

// Absolute path required so @typescript-eslint/parser can resolve the
// relative `project` path below regardless of the caller's cwd.
const tsconfigRootDir = path.dirname(fileURLToPath(import.meta.url));

export default [
  { ignores: ['dist/**', 'node_modules/**'] },
  {
    files: ['**/*.ts'],
    languageOptions: {
      parser: tsParser,
      sourceType: 'module',
      parserOptions: {
        // tsconfig.test.json extends tsconfig.json and additionally
        // includes src/tests/ (excluded from the base config), so on its
        // own it already covers every file `npm run lint` (eslint src)
        // touches — no need to list tsconfig.json separately.
        project: './tsconfig.test.json',
        tsconfigRootDir,
      },
    },
    plugins: {
      '@typescript-eslint': tsPlugin,
    },
    rules: {
      // Base recommended (type-unaware) rather than recommended-type-checked:
      // the latter also pulls in the no-unsafe-* family (member-access,
      // assignment, return, argument), which flags ~235 pre-existing `any`
      // flows unrelated to TD-012's actual target — a much larger cleanup
      // than "fix floating promises". no-floating-promises/no-misused-promises
      // are the only type-aware rules this config needs, so they're added
      // explicitly below instead of pulling in the whole type-checked set.
      ...tsPlugin.configs['recommended'].rules,
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
    },
  },
  // Must be last: disables any ESLint stylistic rule that could conflict
  // with Prettier's own formatting.
  prettierConfig,
];
