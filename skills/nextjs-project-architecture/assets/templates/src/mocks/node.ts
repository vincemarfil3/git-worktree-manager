// Standard (optional). Node-side MSW server that stands in for the backend during local dev.
// Because of the BFF, ALL backend traffic leaves from the Next.js server (page prefetch + /api proxy),
// so one Node interceptor covers everything; no browser service worker needed.
import 'server-only'
import { setupServer } from 'msw/node'
import { env } from '@/env'
import { createOrdersHandlers } from '@/features/orders/mocks'
import { createAuthHandlers } from './auth'

export const server = setupServer(...createAuthHandlers(env.BACKEND_URL), ...createOrdersHandlers(env.BACKEND_URL))
