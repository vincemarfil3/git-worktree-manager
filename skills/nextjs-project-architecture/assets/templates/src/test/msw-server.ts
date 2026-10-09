// One MSW server for all tests. Default handlers = the same mocks used in dev, so tests and dev agree on the API shape.
// Override per test with server.use(http.get(...)) for errors, delays, or to capture request bodies.
import { setupServer } from 'msw/node'
import { createOrdersHandlers } from '@/features/orders/mocks'
import { createAuthHandlers } from '@/mocks/auth'

export const TEST_ORIGIN = 'http://localhost:3000'
export const TEST_BACKEND = 'http://api.test' // matches BACKEND_URL in vitest.config.mts

export const server = setupServer(
  ...createOrdersHandlers(`${TEST_ORIGIN}/api`), // browser path: axios -> /api/*
  ...createAuthHandlers(TEST_BACKEND), // server path: proxy.ts -> backend
)
