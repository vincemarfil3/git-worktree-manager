# Guide: using this foundation by hand

For humans. Everything here works without AI. The `orders` feature is the reference: copy it, rename it, adapt it.

## Contents
1. Set up a new project
2. Run it before the API exists (mocks)
3. Add a feature (file-by-file order)
4. Query keys: reading and invalidating the cache
5. Forms
6. Tables
7. Testing
8. End-to-end tests and CI
9. Plugging in the real API
10. Optional: global client state (Zustand)
11. Troubleshooting

---

## 1. Set up a new project

```bash
npx create-next-app@latest my-app --ts --tailwind --app --src-dir --eslint
cd my-app
npx shadcn@latest init
npx shadcn@latest add button input textarea label checkbox switch select table skeleton alert badge dropdown-menu alert-dialog

npm i @tanstack/react-query @tanstack/react-table nuqs react-hook-form @hookform/resolvers zod axios \
      @t3-oss/env-nextjs next-themes lucide-react server-only
npm i -D msw vitest vite @vitejs/plugin-react jsdom \
      @testing-library/react @testing-library/dom @testing-library/user-event @testing-library/jest-dom \
      @playwright/test
npx playwright install chromium
```

Copy everything under `templates/src/` into your `src/` (keep shadcn's own `lib/utils.ts` if it already exists; they are the same). Copy `eslint.architecture.mjs`, `vitest.config.mts`, `playwright.config.ts`, `e2e/`, and `.github/` to the project root, and spread the lint rules into `eslint.config.mjs` after the Next presets.

Add scripts to `package.json`:

```json
"test": "vitest",
"test:run": "vitest run",
"test:e2e": "playwright test",
"typecheck": "tsc --noEmit"
```

Add to `.gitignore`: `/test-results`, `/playwright-report`, `/blob-report`.

Create `.env.local`:

```bash
BACKEND_URL=http://api.mock          # real API URL later
APP_ORIGIN=http://localhost:3000     # must match the browser origin exactly (CSRF check)
NEXT_PUBLIC_APP_URL=http://localhost:3000
API_MOCKING=enabled                  # remove when the real API is ready
# BACKEND_SERVICE_SECRET=...         # optional shared secret header
```

In `next.config.ts` add `import './src/env'` at the top so a bad config fails the build.

**Dark mode** works out of the box: `providers.tsx` follows the device setting, `components/shared/theme-toggle.tsx` (in the app header) lets users pick Light / Dark / System, and the choice is applied before the page paints (no flash). `shadcn init` writes light values under `:root` and dark values under `.dark` in `globals.css`. The one rule: style with tokens (`bg-background`, `text-muted-foreground`, `border`), never fixed colors like `bg-white`; if you add your own color, define it in both `:root` and `.dark`.

Tested with Next.js 16.3, React 19.3, TanStack Query 5, TanStack Table 9, nuqs 2.10, RHF 7.89 + resolvers 5, Zod 4, MSW 3, Vitest 5 + Vite 8, React Testing Library 16. If `npm i` gives you older or newer majors, check the "Troubleshooting" section.

## 2. Run it before the API exists

With `API_MOCKING=enabled`, `src/instrumentation.ts` starts MSW inside the Next.js server. Because every backend call leaves from the server (page prefetch and the `/api` proxy), this one interceptor stands in for the whole API.

- Login: any email, password `password`. Access tokens expire after 2 minutes, so you can watch silent refresh happen.
- `/orders`: 57 fake orders with paging, sorting, search. Customer name `error` triggers a 422 to test form error mapping.
- Add handlers for a new feature in `features/<n>/mocks.ts` and register them in `src/mocks/node.ts`.
- Write mocks in the API's real shape (snake_case, `Page` envelope, error body). Then switching to the real API changes nothing else.

Verified with `next build && next start`. If your Next.js version does not intercept in `next dev`, run the same handlers in a small standalone server (`@mswjs/http-middleware`) and point `BACKEND_URL` at it.

## 3. Add a feature

Copy `features/orders/` to `features/<name>/`, then go file by file in this order:

| # | File | What you write |
|---|---|---|
| 1 | `types.ts` | API shapes: item, `Page<T>`, request bodies, status union |
| 2 | `keys.ts` | Key factory + the key tree comment (section 4) |
| 3 | `api.server.ts` | Server calls via `serverApi` (used by `page.tsx`) |
| 4 | `api.client.ts` | Browser calls via `apiClient` (same paths) |
| 5 | `queries.ts` | `useQuery` hooks using the keys |
| 6 | `mutations.ts` | `useMutation` hooks, invalidate keys on success |
| 7 | `search-params.ts` | Table URL params (only for list pages) |
| 8 | `schemas.ts` + `mappers.ts` | Form schema (form shape) + `toPayload` (API shape) |
| 9 | `status.ts` | Status → label/badge/icon (if the item has a status) |
| 10 | `components/` | `<name>-columns.tsx`, `<name>-table.tsx`, `<name>-form.tsx` |
| 11 | `mocks.ts` | MSW handlers (dev before the API exists + tests); register in `src/test/msw-server.ts` |
| 12 | `*.test.ts(x)` | Tests next to the code (section 7) |
| 13 | `index.ts` | Public exports (never `api.server.ts`) |

Then add routes in `app/(app)/<name>/` (copy `orders/page.tsx` and `orders/new/page.tsx`) and one line in `src/query-keys.ts`.

**Should the page prefetch?** Only if the client keeps using the data: pagination, sorting, search, mutations, refetching. A read-only page (e.g. a receipt) just fetches in the Server Component and renders; no TanStack Query needed.

## 4. Query keys

A query key is the ID of a cache entry. TanStack Query matches `invalidateQueries` by **prefix**, so keys are built as a tree:

```ts
ordersKeys.all          // ['orders']                          -> everything about orders
ordersKeys.lists()      // ['orders', 'list']                  -> every page/sort/search of the list
ordersKeys.list(params) // ['orders', 'list', { page: 2, ... }] -> one exact page
ordersKeys.details()    // ['orders', 'detail']
ordersKeys.detail(id)   // ['orders', 'detail', 'ORD-1001']
```

Which to invalidate after a mutation:

| Mutation | Invalidate |
|---|---|
| Create | `lists()` |
| Update `id` | `detail(id)` and `lists()` |
| Delete `id` | `lists()`, plus `removeQueries(detail(id))` |
| Bulk / not sure | `all` |
| Affects another feature (e.g. refund changes a customer balance) | that feature's key too, imported from its `keys.ts` |

To see every key in the app, open `src/query-keys.ts`. To debug the cache live, add `@tanstack/react-query-devtools`.

Rules (lint-enforced): never write `queryKey: [...]` inline; always use the factory. The server prefetch and the client hook must call the same factory with the same params, or the prefetch is silently wasted.

## 5. Forms

A feature form is `<Form>` + shared fields. No `useForm` wiring, error rendering or loading logic in the feature:

```tsx
const form = useAppForm(customerSchema, customerDefaults) // types inferred from the Zod schema
const save = useCreateCustomer()

<Form
  form={form}
  onSubmit={async (values) => { await save.mutateAsync(toCustomerPayload(values)) }}
  serverErrors={{ fieldMap: { full_name: 'fullName' } }}   // API field name -> form field name
>
  <FormError />
  <FormGrid>
    <TextField control={form.control} name="fullName" label="Full name" required />
    <TextField control={form.control} name="email" label="Email" type="email" />
    <MoneyField control={form.control} name="creditLimit" label="Credit limit" currency="PHP" />
    <SelectField control={form.control} name="tier" label="Tier" options={tierOptions} />
    <CheckboxField control={form.control} name="active" label="Active" />
  </FormGrid>
  <SubmitButton pendingText="Saving…">Save</SubmitButton>
</Form>
```

What you get for free:
- A typo in `name` is a compile error.
- The submit button disables for the whole request (always `await mutateAsync`).
- API 422 errors land on the right field (use `fieldMap` when names differ). 409 codes can map to a field via `codeToField`. 5xx and unknown errors show at the top via `<FormError />`, never silently dropped.
- The first invalid field gets focus.
- `aria-invalid`, `aria-describedby`, and label wiring are handled.

Zod helpers in `lib/validation.ts`: `requiredText`, `optionalText` ('' becomes undefined), `moneyString` (string in, normalized decimal string out, never a float), `intFromText`.

Missing a field type (date, combobox, OTP, rich text)? Copy `text-field.tsx`, swap the control, keep the `FieldShell` and the `field.ref` line.

## 6. Tables

```tsx
const url = useTableUrlState(customersSearchParams)   // page/sort/search live in the URL
const query = useCustomers(url.params)                // same params as the server prefetch

<DataTable
  columns={columns}                                   // from createColumnHelper<DataTableFeatures, Customer>()
  data={query.data?.items}
  rowCount={query.data?.total}
  getRowId={(c) => c.id}
  pagination={url.pagination} onPaginationChange={url.onPaginationChange}
  sorting={url.sorting} onSortingChange={url.onSortingChange}
  isLoading={query.isPending} isFetching={query.isFetching} isError={query.isError}
  onRetry={() => void query.refetch()}
  empty={{ message: 'No customers yet.' }}
  toolbar={<TableToolbar search={url.params.search} onSearchChange={url.setSearch} />}
/>
```

- String `header` values get sort buttons automatically. Put `enableSorting: false` on columns the backend cannot sort, and list the sortable ones in `createTableSearchParams({ sortable: [...] })`. Anything else in the URL is ignored.
- `meta: { align: 'end' }` right-aligns numbers/money with tabular digits.
- Pass `bulkActions={(rows, clear) => ...}` to get a checkbox column and a selection bar. Selection resets when the page, sort, or search changes.
- Row menu: `<RowActions actions={[{ label: 'Delete', destructive: true, onSelect }]} />` asks for confirmation automatically.
- Extra filters (status, date range): keep them in the feature's own `useQueryStates`, add them to the query key params, and call `url.resetPage()` when they change.
- Build columns inside `useMemo` (or at module scope) so they are not recreated every render.

## 7. Testing

Stack: **Vitest** (runner) + **React Testing Library** (render, query the screen like a user) + **MSW** (fake API) + **user-event** (typing, clicking). Run `npm test` (watch mode) or `npm run test:run` (CI).

What ships (69 tests, all passing; each was checked to fail when the code it protects is broken):

| File | Kind | What it protects |
|---|---|---|
| `lib/errors.test.ts` | unit | 422 → field paths, message fallbacks, no retries on 4xx |
| `lib/validation.test.ts` | unit | Money stays a string, decimals per currency, blank → undefined |
| `lib/format/*.test.ts` | unit | Currency formatting without float loss, Manila time zone, date-only never shifts |
| `components/shared/form/map-server-errors.test.ts` | unit | Server errors land on fields (fieldMap, codes), unknown → top of form, 5xx → generic |
| `components/shared/table/table-search-params.test.ts` | unit | Tampered URLs fall back to safe defaults; same shape as the query key |
| `features/orders/components/create-order-form.test.tsx` | component | Validation + focus, payload mapping, 422 on the right field, 5xx message, no double submit |
| `features/orders/components/orders-table.test.tsx` | component | First page, URL → page/sort, next page → URL, debounced search + reset, sort click, error + retry |
| `proxy.test.ts` | unit (Node) | Guard redirect vs API 401, CSRF, silent refresh + same-request forwarding, logout vs backend-down |
| `features/auth/redirect.test.ts` | unit | `?from=` can only redirect inside the app |
| `components/shared/theme-toggle.test.tsx` | component | Switching theme, saving the choice, menu shows the current choice |
| `lib/query-client.test.ts` | unit | staleTime > 0, pending queries dehydrate, one client in the browser, a NEW client per server request |
| `features/orders/hydration.test.tsx` | integration | Full prefetch → dehydrate → JSON → hydrate cycle: first render has data with no fetch; URL params give the same key; a key mismatch wastes the prefetch |

Helpers in `src/test/`:
- `setup.ts`: jest-dom matchers, MSW lifecycle (unknown requests FAIL the test), jsdom polyfills Radix needs.
- `msw-server.ts`: the same handlers as dev mocks. Override per test with `server.use(...)`.
- `render.tsx`: `renderWithProviders(ui, { searchParams })` gives a fresh QueryClient (no retries) and an in-memory URL, and returns `user` and `lastUrl()`.

Patterns to copy for a new feature:

```tsx
// Component test: real hooks + real axios; only the network is fake
const { user } = renderWithProviders(<CustomersTable />, { searchParams: '?page=2' })
expect(await screen.findByRole('link', { name: 'CUS-1' })).toBeInTheDocument()   // find* waits for data

// Force an error for one test
server.use(http.get(`${TEST_ORIGIN}/api/customers`, () => HttpResponse.json({}, { status: 503 }), { once: true }))

// Capture what the form sent
let body: unknown
server.use(http.post(`${TEST_ORIGIN}/api/customers`, async ({ request }) => { body = await request.json(); return HttpResponse.json(created, { status: 201 }) }))

// Mock the router when the component navigates
const push = vi.hoisted(() => vi.fn())
vi.mock('next/navigation', () => ({ useRouter: () => ({ push }) }))
```

Rules of thumb:
- Query by what users see: `getByRole`, `getByLabelText`, `getByText`. Avoid test IDs and class names.
- Use `findBy...` / `waitFor` for anything that depends on the network.
- Test behavior, not implementation: assert the URL, the request body, the text on screen, focus, and disabled state. Do not assert hook calls or internal state.
- Unit-test pure logic heavily (cheap and fast); keep component tests to the states a user can see (loading, empty, error, success, validation).
- Async Server Components (`page.tsx` prefetch) are not supported by RTL; they are covered by the end-to-end tests (section 8).
- Test files may name the API path directly; app code never does (it goes through `api.client.ts`).
- `renderWithProviders` uses the app's real `makeQueryClient()` settings (only retries are turned off). A test client with different settings would hide caching bugs.
- To test invalidation in E2E, mutate and check **on the same page**. Navigating to another page re-runs the server prefetch and refreshes the cache anyway, so it would pass even without invalidation.
- E2E tests that create data use `uniqueName()`, so reruns against a still-running mock server do not collide.

## 8. End-to-end tests and CI

**Playwright** runs the real app in a real browser. `npm run test:e2e` builds the app, starts it on port 3100 with the mock API, and runs `e2e/`. Keep these few: they are slow, so they only cover what the other tests cannot.

| Test | Proves |
|---|---|
| `auth.spec.ts` | Redirect to sign in and back; tokens are httpOnly (JS cannot read them); wrong password error; sign out |
| `hydration.spec.ts` | List is in the server HTML with no browser refetch; URL params prefetch the exact page; rows render before JS loads; later pages are fetched client-side and cached; a delete on the same page refreshes the list (invalidation) |
| `orders.spec.ts` | Create → detail → found in list (real Select); 422 shown on the field |
| `theme.spec.ts` | Follows the device's dark setting; a saved choice survives reload and is applied before React loads (no flash) |

Add one E2E test per critical flow (sign in, the main create flow, payment). Everything else belongs in Vitest.

Useful commands: `npx playwright test --ui` (watch tests run), `npx playwright show-report` (see failures with screenshots and traces).

**CI** (`.github/workflows/ci.yml`) runs on every push to `main` and every pull request:

1. `checks`: typecheck → lint → unit/component tests → build
2. `e2e` (only if checks pass): Playwright; on failure the HTML report is uploaded as an artifact

To block broken code from merging: GitHub → Settings → Branches → add a rule for `main` that requires the `checks` and `e2e` jobs.

## 9. Plugging in the real API

When the API is ready:

1. **Contract check** with the backend team:
   - Login returns `access_token`, `refresh_token`, `expires_in` (seconds).
   - Refresh takes the refresh token and returns the same shape.
   - Lists return one pagination envelope everywhere.
   - Errors use one body shape.
2. **Adapt these spots** (search the templates for `ADAPT`):

   | What | File |
   |---|---|
   | Token field names | `lib/auth-constants.ts` (`TokenResponse`) |
   | Login path/body | `app/api/auth/login/route.ts` |
   | Refresh path/body, public paths | `proxy.ts` (`refreshTokens`, `PUBLIC_PATHS`) |
   | Logout path | `app/api/auth/logout/route.ts` |
   | Error body → field errors | `lib/errors.ts` (`extractFieldErrors`) |
   | Pagination envelope and item types | `features/<n>/types.ts` |
   | Service secret header name | `lib/server-api.ts`, catch-all route, login route |

3. **Types**: if the API has OpenAPI (FastAPI does), add `"gen:api": "openapi-typescript $BACKEND_URL/openapi.json -o src/lib/api-types.ts"` and alias the generated types in each `features/<n>/types.ts`. TypeScript then shows everywhere the real API differs from your mocks.
4. Set `BACKEND_URL` to the real API, remove `API_MOCKING`, and log in for real.
5. Keep the mocks for component tests and demos.

## 10. Optional: global client state (Zustand)

Most apps never need it: API data, URL state, forms, and theme already have homes. Add it when components far apart (or on different pages) share client-only state, like a workout timer, a multi-step flow, or pinned items. The full rules are in `references/decisions.md` section 7.

To add it:

```bash
npm i zustand
```

1. Copy `optional/zustand/src/` into your `src/` and `optional/zustand/e2e/` into `e2e/`.
2. Wrap the segment that uses it, e.g. in `app/(app)/layout.tsx`:

```tsx
<PinnedOrdersProvider initialState={{ pinned: [] }}>
  <header>… <PinnedCount /> …</header>
  {children}
</PinnedOrdersProvider>
```

3. Use it anywhere inside: `<PinOrderButton id={order.id} />`.

For your own store, copy `pinned-orders-store.ts`: define the state and actions, then `export const [XProvider, useX] = createStoreContext(createXStore, 'useX')`.

Why the Provider and not a plain `create()`: on the server, a module-level store is shared by every request, so one user could see another's state. `createStoreContext` makes one store per Provider. The test `pinned-orders-store.test.tsx` fails if that ever breaks.

## 11. Troubleshooting

- **Page shows data then refetches immediately:** `staleTime` is 0 somewhere, or the server and client keys differ (compare the params objects).
- **Mutations return 403 in the browser:** `APP_ORIGIN` does not exactly match the address in the browser bar (port, `localhost` vs `127.0.0.1`), or a custom client is missing the `X-Requested-With` header.
- **Logged out on every page load when running a production build locally:** `next dev` uses plain cookie names, but `next start` uses `__Host-` + `Secure`. Chrome and Firefox accept that on `http://localhost`; Safari and LAN IPs may not. Test production builds on `localhost` in Chrome, or over HTTPS.
- **"You're importing a component that needs server-only":** a client file imported `api.server.ts`, `server-api.ts`, or `auth.ts`. Import from `api.client.ts` or the feature's `index.ts` instead.
- **Server error shows at the top instead of on the field:** the API field name differs from the form name. Add it to `serverErrors.fieldMap`.
- **Table/state APIs missing (`getIsSorted` undefined):** TanStack Table v9 needs features registered in `components/shared/table/features.ts`. v8 examples (`useReactTable`, `getCoreRowModel`) do not apply.
- **ESLint crashes with "does not support TS 7":** typescript-eslint may lag behind TypeScript majors. Pin `typescript@6` for lint, or follow the typescript-eslint release notes.
- **Tests fail with "Cannot find package '@testing-library/dom'":** it is a required peer of React Testing Library 16; install it.
- **Test fails with "unhandled request":** the component called a URL no handler covers (often a typo, or a missing `server.use`). This is intentional.
- **`@/` imports not found in tests:** Vite 8 uses `resolve.tsconfigPaths: true` (in `vitest.config.mts`); on Vite 6/7 add the `vite-tsconfig-paths` plugin instead.
- **A Radix component (Select, DropdownMenu) misbehaves in tests:** check the polyfills in `src/test/setup.ts`; Radix menus open on pointer events, so use `user.click`, not `fireEvent`.
- **"usePinnedOrders is missing its Provider" (or similar):** the component is rendered outside the store's Provider. Move the Provider up to a layout that wraps both.
- **E2E: "Executable doesn't exist":** run `npx playwright install chromium` (CI does this with `--with-deps`).
- **E2E: port 3100 in use:** stop the other server, or change `PORT` in `playwright.config.ts` (and `APP_ORIGIN`/`NEXT_PUBLIC_APP_URL` in `ci.yml`).
- **E2E finds an empty `role="alert"`:** that is Next.js's route announcer. Locate messages by text instead of by role.
- **A form test passes but the real Select does not change value:** the shadcn Select is a Radix popover; in tests open it with `user.click(trigger)` then `user.click(await screen.findByRole('option', { name }))`.
