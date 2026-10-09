---
name: nextjs-project-architecture
description: Foundation architecture for starting any new Next.js App Router project from scratch, and for structuring features in an existing one. Covers feature folders, TanStack Query prefetch/dehydrate/hydrate, when to fetch directly vs hydrate, caching rules, Server Actions vs API routes, React 19 patterns, forms (RHF + Zod), shared form/table components, URL state (nuqs), httpOnly-cookie auth (BFF), env validation, testing and tooling. Three tiers (Starter, Standard, Hardened) so a side project and a payments app both start right. Works with any HTTP backend (FastAPI, Node/Express) or with Next.js as the backend. Use this skill whenever the user wants to start, scaffold, set up, or plan a new Next.js or React web app (including personal, side, portfolio, or learning projects), add a feature/page/form/table, asks "where should this go" or "how should I structure this", or asks about data fetching, hydration, caching, Server Actions, auth, forms, or tables in Next.js, even if they never name the architecture.
---

# Next.js Project Architecture

A reusable foundation for new Next.js projects. Decisions were made deliberately; follow them unless the user changes one, and when they do, say which other parts are affected.

## Step 0: settle three things before writing code

Ask (briefly, all at once; use sensible defaults if the user does not care):

1. **Profile** (how much architecture): Starter, Standard, or Hardened. Default **Starter**. See "Profiles".
2. **Backend mode**: **A** = separate HTTP API (FastAPI, Node/Express, .NET, ...) or **B** = Next.js is the backend (DB access in `src/server/`). See `references/backends.md`.
3. **Working style**: **Build-for-me** or **Learning mode** (user writes the code by hand). If the user says they are learning, want to do it by hand, or the project is a personal/portfolio project meant to build skill, use Learning mode.

State the chosen combination in one line, then proceed.

## Learning mode (rules)

The user's past attempts stalled because generated code ran ahead of their plan. In Learning mode:
- Agree the plan first (pages, tables/endpoints, data flow) in a short list. Build one small slice at a time.
- Explain the concept and the file layout before showing code. Give only the code for the current step, never the next step.
- Prefer templates in `assets/templates/` for boilerplate (env, query client, providers, api layers, shared form/table components) and let the user hand-write feature logic (types, keys, schemas, queries, columns, pages), following `assets/templates/GUIDE.md` section 3.
- After each slice, say what to run/check and what the next slice would be, then stop.
- Review their code when asked: point out real problems, do not rewrite everything.

## Stack (defaults)

| Concern | Choice |
|---|---|
| Framework | Next.js App Router, TypeScript strict |
| Server state | TanStack Query (prefetch + dehydrate + HydrationBoundary) where it pays off (see `references/decisions.md`) |
| HTTP (browser) | axios to same-origin `/api` only (Mode A) |
| HTTP (server) | native `fetch` via `lib/server-api.ts` (Mode A) |
| Auth | Next.js as BFF, tokens in httpOnly cookies (Mode A); Auth.js or Better Auth are fine alternatives, especially in Mode B |
| Forms | React Hook Form + Zod, shared field components (React 19 `useActionState` for simple forms) |
| Tables | TanStack Table **v9** (`useTable` + registered features), shared `DataTable` |
| URL state | nuqs |
| UI | shadcn/ui + Tailwind, Lucide icons, next-themes |
| API types | `openapi-typescript` when the backend exposes OpenAPI (FastAPI); Zod/DB-derived types in Mode B |
| Env | `@t3-oss/env-nextjs` |
| Mocks / testing | MSW (dev mocks + tests), Vitest 5 + React Testing Library + user-event, Playwright for a few critical flows, GitHub Actions CI (all shipped) |
| Lint/format | ESLint (flat, type-aware, boundaries) + Prettier + Tailwind plugin |
| Monitoring | Sentry (`@sentry/nextjs`) |

## Profiles

Each tier includes everything in the tier above it. Do not build a higher tier up front; upgrade when the need is real.

| | **Starter** (default) | **Standard** (real product) | **Hardened** (payments / sensitive data) |
|---|---|---|---|
| Base | Next app, TS strict, Tailwind + shadcn, folder skeleton, ESLint + Prettier | + boundaries lint rules, git hooks, CI | + full CI pipeline incl. E2E |
| Config | `env.ts` | + generated API types (if OpenAPI) | same |
| Data | `query-client.ts`, `providers.tsx`, key factories, hydration where useful | + `server-api`/`api-client` split, URL state (nuqs) | same |
| Auth | Cookie-based login/logout, guard on cookie presence (`references/auth-and-bff.md` sections 1-4), or an auth library | + silent refresh in `proxy.ts`, catch-all proxy | + CSRF checks, `__Host-` cookies, CSP nonce, `references/auth-checklist.md` |
| UI | Feature forms with RHF + Zod; build shared fields on demand | + full shared `form/` and `table/` component sets, status map, formatters, route-state files | + strict money and date rules, axe on key pages |
| Quality | Unit tests for schemas and mappers | + component tests, MSW, Playwright critical flows, Sentry | + PII scrubbing, security headers verified in E2E |

The reusable components (shared form fields, data-table, pagination, toolbar, URL-state hook, status map, formatters, theme toggle, rich-text) are defined in `references/forms.md`, `references/tables.md`, and `references/ui-and-formatting.md`. In Starter, create them lazily the first time a feature needs them; in Standard they are the expected home for that logic.

## Core principles

1. **Push `'use client'` down to leaves.** `page.tsx` is always a Server Component.
2. **Choose the data path deliberately.** Direct server fetch for read-only pages; prefetch + hydrate only when the client keeps using the cache. See the decision table in `references/decisions.md`.
3. **Tokens never reach JavaScript** (httpOnly cookies). The browser calls `/api/*`; route handlers attach the Bearer token server-side.
4. **Refresh happens once, in `proxy.ts`.** Server Components cannot set cookies, so `server-api.ts` never refreshes; it throws.
5. **Query keys are defined once per feature** in `keys.ts` as a tree (`all` > `lists()` > `list(params)`, `all` > `details()` > `detail(id)`) with a comment listing what to invalidate per mutation. Server prefetch and client hooks share it; `src/query-keys.ts` indexes every factory; inline `queryKey: [...]` is a lint error.
6. **Feature folders own domain logic; `components/shared/` stays generic.** Shared never imports features.
7. **Server-only code stays server-only** (`import 'server-only'`): `server-api`, `auth`, DB access, anything reading secrets.
8. **Separate form shape from API shape** via a typed `toPayload` mapper.
9. **Money is never a float** (Standard+): decimal strings or minor units end to end.
10. **One mutation style per feature** (TanStack `useMutation` or Server Actions), not both.
11. **Dark mode via tokens only.** Never fixed colors (`bg-white`, hex); custom colors get a variable in both `:root` and `.dark`. The theme toggle ships in `components/shared/theme-toggle.tsx`.

## Intentional non-goals (do not add unless asked)

- No `"use cache"` / Cache Components for authenticated or user-specific data. Default caching layer is TanStack Query only.
- No Server Actions in Mode A by default (mutations go through `useMutation` to `/api`). Server Actions are the default mutation path in Mode B. Rules in `references/decisions.md`.
- No heavy OpenAPI hook generators (Orval, Hey API): their generated hooks compete with hand-written key factories.
- No global client state library by default; server state lives in TanStack Query, UI state in components, shareable state in the URL (nuqs). Zustand is the optional exception for client state shared across pages: add it only when `references/decisions.md` section 7 says it fits, using `assets/templates/optional/zustand/` (store per Provider, never a module-level store).

## Folder structure

```
src/
├── env.ts                     # validated env
├── query-keys.ts              # index of every feature's key factory
├── test/                      # setup.ts, msw-server.ts, render.tsx (renderWithProviders), server-only-stub.ts
├── mocks/                     # MSW auth + node server (API_MOCKING=enabled)
├── proxy.ts                   # guard + refresh (+ CSRF, CSP nonce in Hardened). Named middleware.ts on Next.js 15 and earlier
├── instrumentation.ts         # starts MSW when API_MOCKING=enabled; Sentry (Standard+)
├── instrumentation-client.ts  # Sentry browser (Standard+)
├── app/
│   ├── layout.tsx, providers.tsx, globals.css, global-error.tsx, not-found.tsx
│   ├── (auth)/                # login etc., no app shell
│   ├── (app)/                 # protected shell: layout.tsx, loading.tsx, error.tsx
│   │   └── orders/page.tsx, orders/new/page.tsx, orders/[id]/{page,not-found}.tsx
│   └── api/
│       ├── auth/login/route.ts, auth/logout/route.ts
│       └── [...path]/route.ts # catch-all proxy to the backend (Mode A)
├── server/                    # Mode B only: db, repositories, services (server-only)
├── components/
│   ├── ui/                    # shadcn primitives (minimal edits)
│   ├── icons/                 # brand/payment logos
│   └── shared/
│       ├── form/              # form, use-app-form, field-shell, text/money/textarea/select/checkbox/switch fields, submit-button, form-error, map-server-errors, form-layout, index
│       ├── table/             # features (v9 registry), data-table, table-search-params, use-table-url-state, table-toolbar, table-pagination, column-header, row-actions, confirm-dialog, table-states, index
│       ├── rich-text-viewer.tsx
│       └── theme-toggle.tsx
├── features/<n>/
│   ├── index.ts               # public exports
│   ├── keys.ts                # <n>Keys tree + invalidation comment (pure, server and client)
│   ├── api.server.ts          # server-only endpoint calls (server-api) or Mode B service calls
│   ├── api.client.ts          # client endpoint calls (apiClient)
│   ├── queries.ts             # 'use client' useQuery hooks
│   ├── mutations.ts           # 'use client' useMutation + invalidation (or actions.ts for Server Actions)
│   ├── types.ts               # aliases of generated types
│   ├── schemas.ts             # Zod form schemas
│   ├── mappers.ts             # toPayload
│   ├── search-params.ts       # createTableSearchParams + createLoader (pure)
│   ├── status.ts              # status -> label, badge, icon (per feature)
│   ├── mocks.ts               # MSW handlers in the API's real shape
│   └── components/            # 'use client' leaves, columns, forms
├── lib/
│   ├── auth-constants.ts, auth.ts, server-api.ts, api-client.ts, query-client.ts, errors.ts
│   ├── api-types.ts           # GENERATED, never edit
│   ├── utils.ts               # cn()
│   ├── validation.ts          # Zod helpers: requiredText, optionalText, moneyString, intFromText
│   └── format/                # money.ts, date.ts
└── test/                      # setup.ts, render-with-providers.tsx, msw/server.ts
vitest.config.mts, playwright.config.ts   # project root
e2e/                           # Playwright: auth.spec.ts, orders.spec.ts, helpers.ts
.github/workflows/ci.yml       # checks -> e2e
```

Import direction: `app/` -> `features/` -> `components/shared/` -> `components/ui/`; everything may use `lib/`; `lib/` and `components/` never import `features/`. Features reach each other only through `index.ts` (or `keys.ts` for cross-feature invalidation). All of this is enforced by `eslint.architecture.mjs`. `api.server.ts` and `server/` are never imported by client files (a client file importing them fails the build because of `server-only`; this is intended).

## Workflow: starting a new project

Do Step 0 first. Then build in phases; the biggest risk is over-building before shipping.

**Phase 1: day one (hard to retrofit).**
1. Create the app (TypeScript, Tailwind, App Router, `src/`), init shadcn, set theme tokens in `globals.css`.
2. Folder skeleton, strict tsconfig (`strict`, `noUncheckedIndexedAccess`), ESLint + Prettier. Standard+: boundaries rules and git hooks. See `references/tooling-and-quality.md`.
3. Copy templates from `assets/templates/` (index: `assets/templates/README.md`; human setup: `GUIDE.md` section 1): `env.ts`, `errors.ts`, `query-client.ts`, `providers.tsx`, `layout.tsx`, `query-keys.ts`, `eslint.architecture.mjs`, `vitest.config.mts` + `src/test/` + the tests next to each copied file, then the auth and API files for the chosen backend mode. Copy the shared `form/` and `table/` folders when the profile or the first feature needs them.
4. Standard+ with OpenAPI: `gen:api` script.
5. Auth per profile. See `references/auth-and-bff.md`.
6. No API yet? Set `API_MOCKING=enabled` and write `features/<n>/mocks.ts` in the API's real shape (GUIDE.md section 2). When the API is ready, follow GUIDE.md section 7.

**Phase 2: as the first features need them.** Shared form fields (start with text, number/money, select, submit), data table + URL state, formatters, status map, route-level `loading.tsx`/`error.tsx`. See `references/forms.md`, `references/tables.md`, `references/ui-and-formatting.md`.

**Phase 3: before production.** Sentry, security headers (CSP report-only first). Playwright + CI ship with the templates from Phase 1; add one E2E test per new critical flow. Hardened: run `references/auth-checklist.md`.

**Only on real need:** rich-text editor, Suspense streaming, Storybook, visual regression.

Then build ONE feature end to end (list + detail + create form) to validate the patterns before copying them.

Mode A, before Phase 1: confirm the backend contract this architecture depends on: login/refresh/logout endpoints, a standard pagination envelope (`Page[T]`: items, total, page, page_size), typed responses on all endpoints, and a service secret or private network. Flag which parts must adapt if any is missing. FastAPI specifics are in `references/backends.md`.

## Workflow: adding a new feature

1. (Mode A + OpenAPI) regenerate API types; add aliases in `features/<n>/types.ts`.
2. `types.ts` -> `keys.ts` (tree + invalidation comment, add to `src/query-keys.ts`) -> `api.server.ts` / `api.client.ts` -> `queries.ts` -> `mutations.ts` (invalidate per the keys comment). Copy `features/orders/` as the starting point.
3. Decide the data path with `references/decisions.md` (direct fetch or prefetch + hydrate).
4. Lists: `search-params.ts` (`createTableSearchParams` + `createLoader`), `<n>-columns.tsx` (`createColumnHelper<DataTableFeatures, T>()`), `<n>-table.tsx` leaf: `useTableUrlState` -> query hook -> `DataTable`.
5. Forms: `schemas.ts` (form shape, Zod helpers from `lib/validation.ts`), `mappers.ts` `toPayload` (API shape), form component = `<Form>` + shared fields; pass `serverErrors.fieldMap` when API and form field names differ.
6. Routes in `app/(app)/<n>/`: `page.tsx` prefetches with the same keys and parsers; add `not-found.tsx` for detail routes.
7. `mocks.ts` MSW handlers (register in `src/test/msw-server.ts`), then tests next to the code following `features/orders/components/*.test.tsx`: unit tests for schemas/mappers, component tests for the form (validation, payload, 422 mapping, 5xx, no double submit) and table (URL state, search, error/retry). See GUIDE.md section 7.
8. Export the public surface from `index.ts`.

## Reference files: read the one matching the task

- `references/decisions.md`: when to prefetch vs fetch directly, caching layers, mutations (`useMutation` vs Server Actions), React 19 hooks, streaming, and when (and how safely) to add Zustand. **Read this first for any data or mutation question.**
- `references/backends.md`: Mode A adapter (FastAPI and Node notes) and Mode B (Next.js as backend).
- `references/data-and-hydration.md`: rendering split, QueryClient factory, prefetch/hydration mechanics, query keys, axios + Query pairing.
- `references/auth-and-bff.md`: cookies, login/logout, catch-all proxy, server-api, api-client, `proxy.ts` refresh, CSRF.
- `references/forms.md`: shared field contract, `useAppForm`, server error mapping, Tiptap rich-text field.
- `references/tables.md`: data-table contract, server mode, nuqs URL state.
- `references/ui-and-formatting.md`: shadcn layering, tokens/dark mode, icons, status map, money/date formatters, route-state files.
- `references/tooling-and-quality.md`: env validation, generated types, lint/format, testing, Sentry, security headers, CI.
- `references/auth-checklist.md`: auth edge cases to test before launch (Hardened).

## Templates

`assets/templates/` holds verified starter files that mirror `src/` (typechecked, linted, `next build`, and run end-to-end against the mocks). Copy them instead of regenerating from memory; adapt the `ADAPT` spots. `README.md` lists each file, its profile, and what to change. `GUIDE.md` is the human manual (setup, adding a feature, keys, forms, tables, swapping to the real API, troubleshooting): point the user to it when they want to work without AI, and follow its conventions when generating code.

## Version notes

Library APIs move. Before writing code against a specific API, check the installed version or current docs rather than assuming. Known moving parts:
- Next.js 16 renamed `middleware.ts` to `proxy.ts` (export `proxy`); it runs on the Node.js runtime only. On Next.js 15 and earlier use `middleware.ts` (Edge by default).
- `params`, `searchParams`, `cookies()`, `headers()` are async; always `await` them.
- Caching is opt-in in Next.js 16 (Cache Components, `"use cache"`); confirm the flag and the `revalidateTag` / `updateTag` signatures in the docs for the installed version.
- TanStack Table v9 replaced `useReactTable` + `getCoreRowModel()` with `useTable({ features, ... })`; feature APIs (sorting, pagination, selection) exist only when registered. Do not copy v8 examples. The installed package ships its own guides under `node_modules/@tanstack/react-table/skills/`.
- Verified with Playwright 1.64 and GitHub Actions `checkout`/`setup-node`/`upload-artifact` v7. Optional Zustand template verified with Zustand 5 (`createStore` from `zustand/vanilla`, `useStore` from `zustand`).
- Vitest 5 needs `vite` installed as a peer; Vite 8 resolves tsconfig paths natively (`resolve.tsconfigPaths: true`), older Vite needs `vite-tsconfig-paths`. React Testing Library 16 needs `@testing-library/dom` installed explicitly; jest-dom matchers load from `@testing-library/jest-dom/vitest`.
- typescript-eslint can lag behind TypeScript majors (it rejected TS 7 when these templates were verified); pin TypeScript 6 for linting if needed.
- nuqs server loaders, shadcn components, t3-env, Zod major version (`z.url()` vs `z.string().url()`), and Tiptap options change between releases.
