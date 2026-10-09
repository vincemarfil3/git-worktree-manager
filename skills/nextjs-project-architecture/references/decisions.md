# Decision rules

Read this before choosing how a page fetches data, how it caches, or how it mutates.

## Contents
1. Data path: direct fetch vs prefetch + hydrate vs client-only
2. Caching layers
3. Mutations: `useMutation` vs Server Actions
4. React 19 hooks: when to use which
5. Forms: which tool
6. Streaming and Suspense placement
7. Global client state (Zustand, optional)

## 1. Data path

| Situation | Use |
|---|---|
| Read-only data, no client interactivity afterward (profile page, static detail view) | **Direct fetch in the Server Component.** No TanStack Query. |
| Client keeps using the data: mutations with invalidation, polling/refetch, infinite scroll, optimistic updates, filters/sort/pagination driven from the URL | **Prefetch + dehydrate + `HydrationBoundary`**, leaf uses `useQuery` with the identical key. |
| Data is user-triggered or purely client-side (live search box, realtime widgets, data needed only after an interaction) | **`useQuery` only**, no prefetch. |
| Slow secondary section on an otherwise fast page | Prefetch **without `await`** and read with `useSuspenseQuery` inside `<Suspense>` (section 6). |

Rule of thumb: if nothing on the client will ever read the cache again, hydration is wasted work. If the client will refetch, invalidate, or paginate, hydrate.

Hydration checklist (all must hold or the prefetch is wasted):
- `staleTime` above 0 (30-60s), otherwise the client refetches immediately after hydration.
- Same query key from the shared factory (`features/<n>/keys.ts`) on server and client.
- Per-request `QueryClient` on the server, singleton in the browser.
- The server `queryFn` and client `queryFn` return the same shape.

## 2. Caching layers

There are two independent caches. Default to **TanStack Query only**.

| Layer | Lives | Shared across users | Purpose |
|---|---|---|---|
| TanStack Query | Server: one request. Browser: while the tab lives | No | Instant navigation, background refetch, invalidation after mutations |
| Next.js cache (`"use cache"`, Cache Components, `revalidateTag`) | Server, persists across requests | **Yes** | Avoid hitting the backend/DB repeatedly for the same data |

Rules:
- **Start with TanStack Query only.** Each page load calls the backend once for the prefetch; the client cache does the rest. This is right for dashboards and any user-specific data.
- **Add `"use cache"` only when** the data is identical for many users (catalogs, config, public pages) AND the backend call is slow or expensive.
- **Never use `"use cache"` for user-specific or auth-dependent data** unless cache keys include the user and you have tested isolation. Authenticated `fetch` calls use `cache: 'no-store'`.
- **If both layers cache the same data**, a mutation must invalidate both: `invalidateQueries` on the client and `revalidateTag` (or `updateTag` for read-your-writes in Server Actions) on the server. Otherwise users see stale data. This double bookkeeping is the main reason not to layer them without need.
- Caching is opt-in in Next.js 16. If nothing enables it, there is no Next.js cache to think about. Verify the config flag and the `revalidateTag` signature in the docs for the installed version.

## 3. Mutations

| | TanStack `useMutation` -> `/api` (default in Mode A) | Server Actions (default in Mode B) |
|---|---|---|
| Fits | Client-cache-driven UIs, optimistic updates, retries, external backend | Forms tightly coupled to server data, progressive enhancement, Next.js is the backend |
| Invalidation | `invalidateQueries` in `onSuccess` | `revalidatePath` / `revalidateTag` / `updateTag`, plus `invalidateQueries` if TanStack is also caching that data |
| Errors | Normalized `ApiError` -> `mapServerErrors` | Return a result object (`{ ok: false, fieldErrors }`); do not rely on thrown errors crossing the boundary |

Choose **one style per feature**. Do not mix both for the same resource.

If using Server Actions, treat each one as a **public HTTP endpoint**:
1. Authenticate and authorize inside the action (never trust that the UI hid the button).
2. Validate all input with Zod on the server.
3. Return typed results; never return secrets or raw DB rows.
4. Keep `allowedOrigins` tight if configured.
5. Idempotency for anything that moves money or creates side effects (disable submit while pending, plus a server-side idempotency key when it matters).

## 4. React 19 hooks

| Hook | Use for | Do not use for |
|---|---|---|
| `useActionState` | Simple forms bound to a Server Action; pending state and returned errors | Complex multi-field/dynamic forms (use RHF) |
| `useFormStatus` | Submit button reading pending state inside a `<form>` | Anything outside a form |
| `useOptimistic` | Instant UI for a Server Action mutation (toggle, add to list) | Mutations already handled by TanStack; use `onMutate` optimistic updates there instead. Never both for the same data |
| `useTransition` | Non-urgent state updates, wrapping Server Action calls to get `isPending` | Replacing loading states of `useQuery` |
| `use(promise)` | Unwrapping a promise created in a Server Component and passed to a Client Component, inside `<Suspense>` | Promises created during client render (recreated each render) |
| `useDeferredValue` | Keeping typing responsive while a heavy list re-renders | Debouncing network calls (throttle the URL/query instead) |

React Compiler (opt-in in Next.js 16): removes most manual `useMemo`/`useCallback`. Do not add them by habit; add only where profiling shows a need or the compiler is off.

## 5. Forms: which tool

- Multi-field, dynamic arrays, conditional fields, rich validation, server error mapping -> **RHF + Zod + shared fields** (`references/forms.md`).
- One or two fields, Server Action available, progressive enhancement wanted -> **`<form action>` + `useActionState` + Zod on the server**.
- Never validate only on the client. The server (backend or Server Action) validates again.

## 6. Streaming and Suspense placement

- Put `<Suspense>` around the slowest independent section, not around the whole page.
- Route-level `loading.tsx` inside the `(app)` group shows a skeleton that matches the real layout.
- Streaming a prefetch: start it without `await`, dehydrate pending queries (`shouldDehydrateQuery` includes `pending`), read with `useSuspenseQuery` under `<Suspense>`.
- Error boundaries retry reads only, never re-run mutations.
- Do not stream what the page cannot render without (primary data the layout depends on).

## 7. Global client state (Zustand, optional)

Not installed by default. Template: `assets/templates/optional/zustand/` (setup steps in GUIDE.md section 10).

**First check where the state belongs. Zustand is the last option:**

| State | Home |
|---|---|
| Data from the API | TanStack Query |
| Filters, page, sort, search, selected tab worth sharing as a link | URL (nuqs) |
| Form values and errors | React Hook Form |
| Theme | next-themes |
| Used by one component or a parent and its children | `useState` / props |
| Shared by components far apart or across pages, not from the API, not worth a URL | **Zustand** |

Good fits: a running workout timer, a multi-step flow that survives navigation, pinned/compare items, an offline queue. Bad fits: the current user (API → TanStack Query), list filters (URL), one modal's open state (`useState`).

**Rules:**
1. **Never a module-level store for anything rendered on the server.** `create()` at module scope is one store shared by every request on the server, so users can see each other's state. Use `createStoreContext()` from the template: one store per `<Provider>`, so one per request.
2. **Put the Provider as low as possible**, in the layout of the segment that uses it, not the root, unless the whole app needs it. Initial values come from the server through `initialState`.
3. **Store IDs, not API data.** Keep `pinned: string[]` and read the orders through TanStack Query. Copying API data into a store creates a second cache that goes stale.
4. **Select the smallest piece**: `usePinnedOrders((s) => s.pinned.length)`. For several values in one call, wrap the selector with `useShallow`. Selecting the whole state re-renders on every change.
5. **Actions live in the store** (`toggle`, `clear`), so components never build new state themselves.
6. **Persistence is opt-in.** The template is in-memory (resets on reload). For a preference that must survive reloads, add the `persist` middleware and render persisted values after mount (or use `skipHydration`), otherwise server and browser HTML differ.
7. **Test** with the real Provider: one test that two Providers do not share state (the template's `pinned-orders-store.test.tsx` covers this and fails if a shared store is introduced).
