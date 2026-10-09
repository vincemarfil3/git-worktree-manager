// Architecture rules. Spread AFTER the Next/TypeScript presets in eslint.config.mjs:
//   import architecture from './eslint.architecture.mjs'
//   export default [...nextPresets, ...architecture]
//
// Flat config note: when several blocks match a file, the LAST block's options for a rule replace earlier ones.
// So each block below lists the complete set of restrictions for its folder (built by restrictImports()).

const noAxios = { name: 'axios', message: 'Use apiClient from "@/lib/api-client".' }
const noFeatures = { group: ['@/features/*', '@/features/**'], message: 'lib/ and components/shared/ stay generic: they must not import features.' }
const noDeepFeatureImports = {
  group: ['@/features/*/*', '!@/features/*/keys'],
  message: 'Features reach each other only through their index.ts (keys.ts is allowed for cache invalidation).',
}

const restrictImports = ({ paths = [], patterns = [] }) => ['error', { paths, patterns }]

export default [
  // 1. Everywhere
  {
    files: ['src/**/*.{ts,tsx}'],
    rules: {
      // Query keys only come from features/<n>/keys.ts: one place to read and invalidate them
      'no-restricted-syntax': [
        'error',
        {
          selector: "Property[key.name='queryKey'] > ArrayExpression",
          message: 'Use the feature key factory (features/<n>/keys.ts), not an inline queryKey array.',
        },
      ],
      // Env only through the validated src/env.ts
      'no-restricted-properties': ['error', { object: 'process', property: 'env', message: 'Import { env } from "@/env" instead.' }],
      'no-restricted-imports': restrictImports({ paths: [noAxios] }),
    },
  },
  // 2. Generic layers
  {
    files: ['src/lib/**/*.{ts,tsx}', 'src/components/**/*.{ts,tsx}'],
    rules: { 'no-restricted-imports': restrictImports({ paths: [noAxios], patterns: [noFeatures] }) },
  },
  // 3. Features: no deep imports into other features (own files use relative ./ imports)
  {
    files: ['src/features/**/*.{ts,tsx}'],
    rules: { 'no-restricted-imports': restrictImports({ paths: [noAxios], patterns: [noDeepFeatureImports] }) },
  },
  // 4. Exceptions
  { files: ['src/lib/api-client.ts'], rules: { 'no-restricted-imports': restrictImports({ patterns: [noFeatures] }) } },
  { files: ['src/features/*/keys.ts', 'src/**/*.test.{ts,tsx}'], rules: { 'no-restricted-syntax': 'off' } },
  { files: ['src/env.ts', 'src/lib/auth-constants.ts', 'src/instrumentation.ts'], rules: { 'no-restricted-properties': 'off' } },
]
