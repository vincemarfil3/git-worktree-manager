# Tooling and quality

By profile: Starter = env validation, ESLint + Prettier, strict tsconfig, Vitest + RTL + MSW with the shipped tests. Standard = adds boundaries lint, generated types, MSW/component/E2E tests, Sentry, base security headers, CI. Hardened = adds CSP nonce, PII scrubbing rules, axe, and full CI with E2E.

## Contents
1. Env validation
2. Generated API types
3. Lint and format
4. Testing
5. Error monitoring (Sentry)
6. Security headers
7. CI pipeline

## 1. Env validation — `src/env.ts`

- `@t3-oss/env-nextjs` (Zod). Server vs client split; throws if server vars are read on the client.
- Only `env.ts` reads `process.env` (lint-enforced).
- Server: `BACKEND_URL`, `APP_ORIGIN`, `BACKEND_SERVICE_SECRET`, Sentry auth token, optional refresh TTL, `APP_ENV` enum (development | staging | production — separate from `NODE_ENV`).
- Client: `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_SENTRY_DSN`. No `NEXT_PUBLIC_API_URL` (browser only calls `/api`).
- Coerce explicitly (`"false"` is truthy). Client values are inlined at build time; reference each literally in the runtime mapping.
- Import `env.ts` in `next.config` so `next build` fails on bad config. Skip-validation flag only for lint/typecheck CI steps.
- Keep `env.ts` free of Node-only imports (`proxy.ts` imports it, and on Next.js 15 `middleware.ts` runs on the Edge runtime).
- `.env.example` committed; `.env.local` gitignored; secrets in the host's secret manager.

## 2. Generated API types

- `openapi-typescript` → `src/lib/api-types.ts` via `gen:api` script from the backend's `/openapi.json` (FastAPI and other OpenAPI backends; in Mode B derive types from the DB schema + Zod instead). Types only, zero runtime. Generated, committed, never edited.
- CI: regenerate and fail on diff.
- `features/<name>/types.ts` re-exports clean aliases; nothing else imports `api-types.ts` directly.
- Backend requirements (FastAPI): Pydantic `response_model` on every endpoint (untyped dicts become `unknown`), clean model names and `operation_id`s, `Decimal` for money (serializes as string).
- Heavier generators (Orval, Hey API) are avoided because their generated hooks compete with the hand-written query key factories.

## 3. Lint and format

- ESLint flat config extending Next (core-web-vitals + typescript) + React Hooks + jsx-a11y. Run ESLint CLI directly (`next lint` is deprecated in newer Next.js).
- Type-aware typescript-eslint: `no-floating-promises`, `no-misused-promises`.
- Architecture boundaries: shipped as `assets/templates/eslint.architecture.mjs` (verified; uses core rules only, no plugin). In flat config the last matching block's options for a rule replace earlier ones, so each folder block lists its complete restriction set. Covers:
  - no inline `queryKey: [...]` arrays outside `features/*/keys.ts`
  - `lib/` and `components/` cannot import `features/`
  - no `process.env` outside `env.ts` (plus `auth-constants.ts` for `NODE_ENV`, `instrumentation.ts`)
  - no `axios` import outside `lib/api-client.ts`
  - features import each other only via `index.ts` (or `keys.ts`)
  - client files importing server code: enforced at build time by `import 'server-only'`, not by lint
  - optional additions: `api-types.ts` only from `features/*/types.ts`
- Prettier + `eslint-config-prettier` + `prettier-plugin-tailwindcss` (point at main stylesheet for Tailwind v4; register `cn`). One import sorter.
- tsconfig: `strict`, `noUncheckedIndexedAccess`; skip `exactOptionalPropertyTypes`. `typecheck` script: `tsc --noEmit`.
- Ignore `api-types.ts`; relax rules for `components/ui/`.
- lefthook/husky + lint-staged on staged files only.

## 4. Testing

Shipped: `vitest.config.mts`, `src/test/` (setup, MSW server, `renderWithProviders` in `test/render.tsx`), 69 Vitest tests (unit, component, hydration cycle, `proxy.ts`), `playwright.config.ts` + `e2e/` (13 tests), and `.github/workflows/ci.yml`. Usage: `assets/templates/GUIDE.md` sections 7-8. axe is not shipped yet (add `@axe-core/playwright` to the E2E tests).

| Layer | Tool | Scope |
|---|---|---|
| Unit | Vitest | formatters (fixed TZ + locale), money parser, Zod schemas, `toPayload`, server error mapper, search-param parsers, status map completeness |
| Component | Vitest + RTL + user-event | shared fields (label, errors, aria, focus via ref), Form (submit disable, server errors, reset), data-table (states, aria-sort, clamping) |
| Network mocks | MSW | per-feature `mocks.ts`, typed with generated types; reusable in dev |
| Handlers / `proxy.ts` | Vitest | build `Request`, assert responses, redirects, `Set-Cookie` |
| E2E | Playwright | login/logout, guard redirect with `from`, refresh (short TTL), list pagination/filters via URL, create/edit forms incl. server errors, payment-critical flows |
| A11y | axe | key pages, both themes |

- `test/render.tsx` (`renderWithProviders`): fresh QueryClient per test (retries off) + nuqs testing adapter (`hasMemory`), returns `user` and `lastUrl()`.
- Async Server Components → cover via E2E (they're thin).
- Rich-text editing → Playwright or Vitest browser mode (jsdom handles contenteditable poorly).
- E2E against the real backend in a test env (Docker Compose + seed); reuse saved auth state.
- Coverage focus: `lib/`, `components/shared/`, auth/middleware.
- Optional: Storybook + visual regression in both themes.

## 5. Error monitoring — Sentry

- `@sentry/nextjs`: `instrumentation.ts` (server + edge, request-error hook), `instrumentation-client.ts`. `error.tsx`/`global-error.tsx` report with digest tag.
- Source maps uploaded at build, never served publicly.
- Filter noise: handled 4xx, aborted queries, offline errors, ResizeObserver/extension errors. QueryCache/MutationCache report only 5xx/unknown.
- Context: internal user id + merchant id (never email/name), release = git SHA, environment = `APP_ENV`, route/feature tags.
- PII: default PII off; `beforeSend` scrubs bodies, cookie/authorization headers, sensitive query params; no form values in events/breadcrumbs. Session Replay: mask all text/inputs and exclude payment pages.
- Tracing: low prod sample rate; Sentry on the backend too; propagate trace headers only to own origin/backend.
- Tunnel route (e.g. `/monitoring`) to bypass ad blockers — exclude it from the auth matcher and account for it in CSRF.
- Alerts: new issue + spike, by environment; watch release health. Track web vitals on checkout/payment pages.

## 6. Security headers

- Static headers in `next.config` `headers()`; CSP with per-request nonce in `proxy.ts`.
- CSP: `default-src 'self'`; `script-src 'self' 'nonce-…' 'strict-dynamic'`; `style-src 'self' 'unsafe-inline'` (Radix inline styles); `img-src 'self' data: blob:` + CDN; `font-src 'self'`; `connect-src 'self'`; `frame-src` payment provider domains; `frame-ancestors 'none'`; `object-src 'none'`; `base-uri 'self'`; `form-action 'self'`.
- Dev-only `'unsafe-eval'`, gated by env. Roll out report-only first, reporting to Sentry, then enforce.
- Also: HSTS (long max-age, includeSubDomains; preload later), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin` (stricter on payment pages), `X-Frame-Options: DENY`, `Permissions-Policy` (camera/mic/geolocation off; `payment=(self)` only if used), COOP `same-origin` or `same-origin-allow-popups` if payment/3DS uses popups, `poweredByHeader: false`.
- `Cache-Control: no-store` on `/api/*` and all authenticated responses.
- Verify with Mozilla Observatory; Playwright test asserts key headers.

## 7. CI pipeline

Shipped: `assets/templates/.github/workflows/ci.yml` (job `checks`: typecheck → lint → tests → build; job `e2e`: Playwright with mocks, report uploaded on failure). Make both required checks on `main`. The full pipeline below adds format check, generated-types diff, and preview deploys when needed.

format check → lint → typecheck → generated types diff → unit/component tests → build (env validation) → E2E (PR preview or nightly).
