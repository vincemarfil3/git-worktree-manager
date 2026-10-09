// Vitest 5 + Vite 8. Unit + component tests (jsdom). Files that need Node (proxy.ts, route handlers)
// opt in with a `// @vitest-environment node` comment at the top.
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  plugins: [react()],
  resolve: {
    tsconfigPaths: true, // "@/..." imports (Vite 8 native; on Vite 6/7 use the vite-tsconfig-paths plugin)
    alias: {
      // `import 'server-only'` throws outside the Next.js server build; tests import server modules directly
      'server-only': fileURLToPath(new URL('./src/test/server-only-stub.ts', import.meta.url)),
    },
  },
  test: {
    environment: 'jsdom',
    environmentOptions: { jsdom: { url: 'http://localhost:3000' } }, // relative /api calls resolve here
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    restoreMocks: true,
    // Test values for src/env.ts (never real secrets)
    env: {
      BACKEND_URL: 'http://api.test',
      APP_ORIGIN: 'http://localhost:3000',
      NEXT_PUBLIC_APP_URL: 'http://localhost:3000',
    },
  },
})
