// Starter. Validated env. The ONLY file that reads process.env (lint-enforced), plus NODE_ENV in auth-constants.ts.
// Zod v4: z.url(). On Zod v3 use z.string().url().
import { createEnv } from '@t3-oss/env-nextjs'
import { z } from 'zod'

export const env = createEnv({
  server: {
    // Mode A only: private URL of the backend API (never NEXT_PUBLIC)
    BACKEND_URL: z.url(),
    // This app's public origin, used for the CSRF Origin check (Hardened)
    APP_ORIGIN: z.url(),
    // Optional shared secret so the backend only accepts traffic from this server
    BACKEND_SERVICE_SECRET: z.string().min(1).optional(),
    APP_ENV: z.enum(['development', 'staging', 'production']).default('development'),
  },
  client: {
    NEXT_PUBLIC_APP_URL: z.url(),
  },
  // Client values are inlined at build time: reference each one literally here.
  runtimeEnv: {
    BACKEND_URL: process.env.BACKEND_URL,
    APP_ORIGIN: process.env.APP_ORIGIN,
    BACKEND_SERVICE_SECRET: process.env.BACKEND_SERVICE_SECRET,
    APP_ENV: process.env.APP_ENV,
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
  },
  // Set SKIP_ENV_VALIDATION=1 only for lint/typecheck CI steps. Import this file in next.config so `next build` fails on bad config.
  skipValidation: !!process.env.SKIP_ENV_VALIDATION,
  emptyStringAsUndefined: true,
})
