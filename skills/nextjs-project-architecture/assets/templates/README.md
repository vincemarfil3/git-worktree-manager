# Starter templates

Files mirror a project's `src/`. **Humans: read `GUIDE.md` first** (setup, adding features, keys, forms, tables, plugging in the real API).
Claude: copy these instead of regenerating them from memory; adapt the spots marked `ADAPT`.

Verified together: `tsc` (strict, `noUncheckedIndexedAccess`), ESLint with `eslint.architecture.mjs`, `next build`, the shipped test suite (69 Vitest tests), the Playwright suite (13 tests, real Chromium, shadcn-style components on real Radix UI), and an end-to-end run against the MSW mocks (guard, CSRF, login, prefetch + hydration, URL params, catch-all proxy, 422, silent refresh with same-request cookie forwarding, logout). Versions: Next.js 16.3, React 19.3, TanStack Query 5, TanStack Table 9, nuqs 2.10, RHF 7.89 + @hookform/resolvers 5, Zod 4, MSW 3, axios 1. shadcn primitives were stand-ins during verification: run `npx shadcn@latest add ...` from GUIDE.md.

| Path | Profile | Mode | Notes / ADAPT |
|---|---|---|---|
| `GUIDE.md` | all | all | Human quick start |
| `eslint.architecture.mjs` | Starter | all | Key factory rule, env rule, axios rule, import boundaries |
| `vitest.config.mts` | Starter | all | Vitest 5 + Vite 8, jsdom, `@/` paths, `server-only` stub, test env values |
| `src/test/*` | Starter | all | setup (jest-dom, MSW lifecycle, Radix polyfills), msw-server, renderWithProviders, server-only stub |
| `**/*.test.ts(x)` | Starter | all | Unit, component, and `proxy.ts` tests (GUIDE.md section 7) |
| `playwright.config.ts`, `e2e/*` | Standard | all | Builds + starts the app with mocks on port 3100; auth, hydration, orders, and theme flows (GUIDE.md section 8) |
| `.github/workflows/ci.yml` | Standard | all | checks (typecheck, lint, tests, build) → e2e; report artifact on failure |
| `src/features/auth/*`, `src/app/(auth)/login/page.tsx` | Starter | A | Sign in/out, safe `?from=` redirect |
| `src/app/(app)/layout.tsx`, `(app)/page.tsx` | Starter | all | App shell with theme toggle and sign out; `/` → `/orders` |
| `src/components/shared/theme-toggle.tsx` | Starter | all | Light / Dark / System; needs shadcn `dropdown-menu` |
| `src/app/(app)/orders/[id]/page.tsx` | Starter | all | Read-only page: direct server fetch, `notFound()` on 404 |
| `src/env.ts` | Starter | A/B | Remove backend vars in Mode B |
| `src/instrumentation.ts` | Starter | A | `API_MOCKING=enabled` swaps the backend for MSW |
| `src/proxy.ts` | Starter guard / Standard refresh / Hardened CSRF | A | Refresh endpoint + body, `PUBLIC_PATHS`. Next 15: rename to `middleware.ts`, swap `Buffer` for `atob` |
| `src/query-keys.ts` | Starter | all | Index of every feature's key factory |
| `src/app/layout.tsx`, `providers.tsx` | Starter | all | nuqs adapter is Standard; remove if unused |
| `src/app/api/auth/{login,logout}/route.ts` | Starter | A | Backend auth paths and token shape |
| `src/app/api/[...path]/route.ts` | Standard | A | Catch-all BFF proxy |
| `src/app/(app)/orders/page.tsx`, `new/page.tsx` | Starter | all | Prefetch + hydrate list page; create page |
| `src/lib/errors.ts` | Starter | A | `extractFieldErrors` for your error body |
| `src/lib/query-client.ts` | Starter | all | Standard+: `onError` toasts/Sentry |
| `src/lib/auth-constants.ts`, `auth.ts` | Starter | A | `TokenResponse` shape |
| `src/lib/server-api.ts`, `api-client.ts` | Starter | A | Service-secret header name |
| `src/lib/utils.ts`, `validation.ts` | Starter | all | `cn()`; Zod helpers (money as string) |
| `src/lib/format/{money,date}.ts` | Standard | all | Locale and display time zone |
| `src/components/shared/form/*` | Starter (on demand) / Standard | all | Form, useAppForm, fields, submit, errors, layout |
| `src/components/shared/table/*` | Standard | all | DataTable (TanStack Table v9, server mode), URL state, toolbar, pagination, row actions, confirm dialog |
| `src/features/orders/*` | reference | A (B: swap `api.*`) | The feature to copy and rename |
| `src/mocks/*` | Standard | A | MSW auth + node server |
| `optional/zustand/*` | optional | all | NOT part of the default app. `create-store-context.tsx` (store per Provider), pinned-orders example store + components, 4 unit tests, 1 E2E test. Requires `npm i zustand`; setup in GUIDE.md section 10 |
