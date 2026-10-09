# Backend modes

## Contents
1. Mode A: separate HTTP API
2. FastAPI specifics
3. Node/Express (or other) specifics
4. Mode B: Next.js is the backend
5. Choosing

## 1. Mode A: separate HTTP API

The frontend talks to "an HTTP API" only through two adapter files, so the backend is swappable:

- `lib/server-api.ts` (server-only): Server Components, route handlers, and `proxy.ts` call the backend directly.
- `lib/api-client.ts` (client-only): axios to same-origin `/api`; the catch-all route handler forwards to the backend with the token attached.

Everything else (features, forms, tables, keys) is backend-agnostic. What varies per backend, and where it lives:

| Concern | Where to adapt |
|---|---|
| Token shape (`access_token`, `refresh_token`, `expires_in`) | `lib/auth.ts`, login route, `proxy.ts` refresh call |
| Auth endpoints (`/auth/login`, `/auth/refresh`, `/auth/logout`) | login/logout route handlers, `proxy.ts` |
| Error body format and field errors | `lib/errors.ts` `extractFieldErrors` |
| Pagination envelope | `features/<n>/types.ts` and `data-table` `rowCount` mapping |
| Types | generated (OpenAPI) or hand-written aliases in `features/<n>/types.ts` |

Confirm the contract before Phase 1: login/refresh/logout endpoints, a consistent pagination envelope, typed responses, and either a service secret header or a private network so the backend accepts traffic only from the Next.js server.

## 2. FastAPI specifics

- Types: `openapi-typescript` against `/openapi.json`. Requires Pydantic `response_model` on every endpoint (untyped dicts become `unknown`), clean model names and `operation_id`s, and `Decimal` for money (serializes as a string).
- Pagination: a generic `Page[T]` -> `{ items, total, page, page_size }` on every list endpoint. One sort format (`sort=created_at:desc`).
- Validation errors are HTTP 422 with `detail[]`; each item's `loc` (e.g. `["body","items",0,"qty"]`) maps to a form path by dropping `"body"` (`items.0.qty`). This is what `extractFieldErrors` in the errors template implements.
- Refresh-token rotation: ask the backend to keep the old refresh token valid for a short grace window after rotation (parallel requests, multiple tabs).

## 3. Node/Express (or other) specifics

- Types: share a Zod schema package or generate from OpenAPI if the API has one (tsoa, zod-to-openapi, fastify swagger). Without either, hand-write `features/<n>/types.ts` and validate responses with Zod at the adapter boundary in `api.server.ts` / `api.client.ts`.
- Return the same error shape everywhere (`{ message, code?, errors?: { path, message }[] }`) and adapt `extractFieldErrors` to it.
- Same pagination envelope rule as above.
- Same auth contract; if the API uses server sessions instead of JWTs, the BFF forwards the session cookie instead of a Bearer token and `proxy.ts` refresh is unnecessary.

## 4. Mode B: Next.js is the backend

There is no separate API. Database and business logic live in the same repository.

Structure:
```
src/server/
├── db/            # client, schema, migrations (Drizzle/Prisma); import 'server-only'
├── repositories/  # queries, no business rules
└── services/      # business rules; the only layer features call
```

Rules:
- Every file under `src/server/` starts with `import 'server-only'`. Client files can never import it.
- Server Components call `services/` directly (no HTTP hop). `features/<n>/api.server.ts` is a thin wrapper around a service call.
- **Mutations** default to Server Actions (`features/<n>/actions.ts`): authenticate, validate with Zod, call a service, return a result object. See `references/decisions.md` section 3.
- **Client reads** (when the client needs `useQuery`, e.g. refetch, pagination, polling) go through Route Handlers under `app/api/<n>/route.ts` that call the same service. Hydration prefetch on the server calls the service directly; the key factory stays shared.
- Auth: use Auth.js or Better Auth (sessions in the DB or signed cookies). The BFF token-cookie flow in `references/auth-and-bff.md` is not needed. Check the session in a data-access helper (`requireUser()`) called by every service entry point, not only in `proxy.ts`; `proxy.ts` only does the cheap cookie-presence redirect.
- Types: derive from the DB schema and Zod (`z.infer`). One Zod schema per input, reused by the form and the server-side validation.
- Redis (or similar) lives behind a service (`server/cache/`) and is for shared, non-user-specific data or rate limiting. It does not replace TanStack Query in the browser.
- `lib/server-api.ts`, `lib/api-client.ts`, the catch-all proxy, and service secrets are not created in Mode B.

## 5. Choosing

- Existing or separately-owned backend, or several clients (web + mobile) sharing one API -> **Mode A**.
- One deployable, one team, web is the only client -> **Mode B** is simpler.
- Unsure -> Mode B for personal/learning projects; Mode A when a backend already exists. Moving from B to A later is feasible because features only touch `api.server.ts`/`api.client.ts`.
