// Starter. One factory for server and browser.
// Server: new client per request, shared within the request via React cache(). NEVER a module-level singleton on the server (cross-user data leak).
// Browser: module singleton (do not use useState(() => new QueryClient()) in providers).
import { QueryClient, defaultShouldDehydrateQuery, isServer } from '@tanstack/react-query'
import { cache } from 'react'
import { isClientError } from '@/lib/errors'

// Exported for tests, which must use the same settings as the app
export function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // > 0, otherwise the client refetches immediately after hydration and wastes the prefetch
        staleTime: 60_000,
        retry: (count, error) => !isClientError(error) && count < 2,
      },
      dehydrate: {
        // include pending queries so un-awaited prefetches can stream
        shouldDehydrateQuery: (q) => defaultShouldDehydrateQuery(q) || q.state.status === 'pending',
      },
    },
    // Standard+: add QueryCache/MutationCache onError -> toast (Sonner) + Sentry for 5xx/unknown only
  })
}

const getServerQueryClient = cache(makeQueryClient)
let browserQueryClient: QueryClient | undefined

export function getQueryClient() {
  if (isServer) return getServerQueryClient()
  return (browserQueryClient ??= makeQueryClient())
}
