# Data fetching and hydration

Tested in three places: `lib/query-client.test.ts` (the settings), `features/orders/hydration.test.tsx` (the full cycle, including a wasted prefetch from a key mismatch), and `e2e/hydration.spec.ts` (real browser). Copy these when a feature adds a new prefetched page.

Mechanics only. **Whether** to hydrate at all (vs fetching directly in the Server Component) and how caching layers interact is decided in `decisions.md`; read that first.

## Rendering split

- Server Components never hydrate; they don't exist as JS in the browser.
- `'use client'` marks a component that ships JS and hydrates. It is contagious downward for imports, but Server Components passed as `children`/props (slot pattern) stay server-rendered.
- `page.tsx` never has `'use client'`. It fetches, prefetches, and composes.
- Hooks (`useQuery`, `useForm`) only work in client components → those are the hydration leaves.

## QueryClient factory — `lib/query-client.ts`

One `getQueryClient()`:
- **Server:** new client per request, wrapped in React `cache()` so all Server Components in one request share it. NEVER a module-level singleton on the server (cross-user data leak).
- **Browser:** module singleton. `providers.tsx` uses `getQueryClient()`, not `useState(() => new QueryClient())` (React may discard state if it suspends on initial render). `api-client.ts` and `useLogout` import the same singleton to `.clear()` it.

Defaults:
- `staleTime` 30–60s (0 causes an immediate refetch after hydration, wasting the prefetch).
- `retry`: never for 4xx (esp. 401/403); up to 2 for network/5xx.
- `dehydrate.shouldDehydrateQuery`: include pending queries (enables un-awaited prefetch + streaming).
- `refetchOnWindowFocus`: default true; disable per-query on form/payment screens.
- `QueryCache`/`MutationCache` `onError`: toasts (Sonner) and Sentry reporting for 5xx/unknown only.

Sketch:

```ts
import { QueryClient, defaultShouldDehydrateQuery, isServer } from '@tanstack/react-query'
import { cache } from 'react'

function makeQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 60_000,
        retry: (count, error) => !isClientError(error) && count < 2,
      },
      dehydrate: {
        shouldDehydrateQuery: (q) =>
          defaultShouldDehydrateQuery(q) || q.state.status === 'pending',
      },
    },
  })
}

const getServerQueryClient = cache(makeQueryClient)
let browserQueryClient: QueryClient | undefined

export function getQueryClient() {
  if (isServer) return getServerQueryClient()
  return (browserQueryClient ??= makeQueryClient())
}
```

## Prefetch at page level

```tsx
// app/(app)/orders/page.tsx — Server Component
export default async function OrdersPage({ searchParams }) {
  const params = await loadOrdersSearchParams(searchParams) // nuqs createLoader, same parsers as the client leaf
  const queryClient = getQueryClient()
  await queryClient.prefetchQuery({
    queryKey: ordersKeys.list(params),
    queryFn: () => ordersApiServer.list(params), // from features/orders/api.server.ts
  })
  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <OrdersTable />
    </HydrationBoundary>
  )
}
```

- Multiple prefetches: `Promise.all` to avoid waterfalls; one client, one dehydrate, one boundary.
- Split prefetch into nested Server Components when a section is conditional, below the fold, needs independent streaming, or is reused across routes.
- Streaming: start slow prefetches without `await`; leaf uses `useSuspenseQuery` inside `<Suspense>`.
- `HydrationBoundary` is not a client boundary; it just carries serialized cache.
- Prefer this over the `initialData` prop pattern (which only scales to single queries).

## Query keys and hooks

Keys live in `features/<n>/keys.ts` (pure, no imports from axios or hooks) so `page.tsx` (server) and hooks (client) can both import them:

```ts
// features/orders/keys.ts
export const ordersKeys = {
  all: ['orders'] as const,
  lists: () => [...ordersKeys.all, 'list'] as const,
  list: (params: OrdersListParams) => [...ordersKeys.lists(), params] as const,
  details: () => [...ordersKeys.all, 'detail'] as const,
  detail: (id: string) => [...ordersKeys.details(), id] as const,
}
```

`invalidateQueries` matches by prefix, so the tree levels are what make targeted invalidation possible (flat string constants cannot do this). Each `keys.ts` carries a comment with the tree and what to invalidate per mutation (create -> `lists()`; update -> `detail(id)` + `lists()`; delete -> `lists()` + `removeQueries(detail(id))`). `src/query-keys.ts` re-exports every factory so a human can see all keys in one file.

Hooks live in `features/<n>/queries.ts` (`'use client'`) and import the keys.

- Server prefetch and client `useQuery` MUST use the same factory; a typo'd key silently misses the cache.
- Lists: `placeholderData: keepPreviousData` to avoid flicker between pages.
- Mutations invalidate the narrowest level that covers the change (see the comment in `keys.ts`); `all` when unsure.

## Two API call paths per feature (Mode A)

- Server: `features/<n>/api.server.ts` (starts with `import 'server-only'`) calls `server-api.ts` (-> backend directly, no `/api` hop).
- Client: `features/<n>/api.client.ts` calls `apiClient` (-> `/api/...` -> BFF -> backend).
- They are separate files on purpose: a single file importing both would pull the server-only module into the client bundle and fail the build.
- With the catch-all proxy, client paths mirror backend paths, so both files share endpoint path constants and types from `types.ts`.
- Pass TanStack's `signal` into axios for cancellation.
- In Mode B, `api.server.ts` wraps a `server/services` call and `api.client.ts` calls a Route Handler (see `backends.md`).

## Split files when they grow

Start with single `api.server.ts` / `api.client.ts` / `queries.ts` / `mutations.ts`. Split into folders (`queries/list.ts`, `queries/detail.ts`) only past a few hundred lines or several sub-resources.
