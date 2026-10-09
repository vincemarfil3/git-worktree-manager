# Auth and BFF (Mode A)

Applies to Mode A (separate backend). In Mode B use Auth.js or Better Auth (see `backends.md`).

**By profile:** Starter = sections 1-5 and 6, with a proxy that only checks cookie presence (no refresh). Standard = adds section 7 refresh and section 4 catch-all. Hardened = adds section 8 CSRF, `__Host-` cookies, and `auth-checklist.md`. Templates for all of this are in `assets/templates/`.

## Contents
1. Flows
2. Cookies — `lib/auth.ts`
3. Login / logout route handlers
4. Catch-all proxy
5. `lib/server-api.ts`
6. `lib/api-client.ts`
7. `proxy.ts`: guard + silent refresh
8. CSRF

## 1. Flows

```
Page load:   Browser → proxy.ts (guard, refresh) → page.tsx prefetch via server-api → backend
Client call: axios → /api/* → proxy.ts (refresh) → route handler → server-api → backend
Login:       axios → /api/auth/login → backend → set httpOnly cookies (return user only, never tokens)
Logout:      axios → /api/auth/logout → revoke (best effort) → clear cookies → queryClient.clear()
Dead session: axios receives 401 → queryClient.clear() → /login?from=<path>
```

Server Components call the backend directly through `server-api.ts` — never through the app's own `/api`.

## 2. Cookies — `lib/auth.ts`

- Options: `httpOnly`, `secure` in production, `sameSite: 'lax'`, `path: '/'`.
- Names: `__Host-access_token` / `__Host-refresh_token` in production (prevents subdomain cookie overwriting; requires HTTPS, so plain names in local dev).
- Access cookie `maxAge` = backend `expires_in`; refresh cookie `maxAge` = backend refresh TTL.
- Keep refresh cookie `lax`, not `strict` (strict breaks refresh when arriving from an external link).
- Helpers: `setAuthCookies`, `clearAuthCookies`, `getAccessToken`, `getRefreshToken`. `cookies()` is async in Next.js 15+.

## 3. Login / logout

- Login: forward credentials to the backend, on success `setAuthCookies`, respond with `{ user }` only. Pass through backend error status/body on failure.
- Logout: best-effort backend revoke with the refresh token (swallow failures), ALWAYS clear cookies.
- Client hooks in `features/auth/mutations.ts`: `useLogin` (redirect to `from` or dashboard), `useLogout` (`queryClient.clear()` then `/login`, in `onSettled`).
- Validate `from` is an internal path (starts with `/`, not `//`) to prevent open redirects.

## 4. Catch-all proxy — `app/api/[...path]/route.ts`

- Forwards method, path, query, and JSON body to `BACKEND_URL`, attaching `Authorization: Bearer <access cookie>` and the BFF service secret header.
- Returns backend status and body; sets `Cache-Control: no-store`.
- Strips hop-by-hop and cookie headers; never forwards browser cookies to the backend.
- Dedicated handlers only for special cases (auth, aggregation, reshaping).

## 5. `lib/server-api.ts` (server-only)

- `import 'server-only'` at the top.
- Native `fetch`, base `env.BACKEND_URL` (private, not NEXT_PUBLIC).
- Reads access token from cookies, attaches Bearer + service secret.
- `cache: 'no-store'` for authenticated requests (no cross-user cache).
- Timeout via `AbortSignal.timeout`.
- Non-2xx → throw normalized `ApiError { status, message, body, fieldErrors? }` from `lib/errors.ts`.
- **Never refreshes** (Server Components can't set cookies). 401 → throw; pages redirect to login.
- Typed methods `get/post/patch/delete<T>`.

## 6. `lib/api-client.ts` (client-only)

- `axios.create({ baseURL: '/api', timeout: 15_000, headers: { 'X-Requested-With': 'XMLHttpRequest' } })`.
- No Authorization interceptor, no refresh queue.
- Response interceptor: 401 → `getQueryClient().clear()` + `window.location.href = '/login?from=...'`, EXCEPT for `/auth/*` requests and when already on `/login` (avoids loops, preserves login error messages).
- Convert `AxiosError` to the same `ApiError` shape as server-api.
- Optional `import 'client-only'`.

## 7. `proxy.ts`: guard + silent refresh

File: `src/proxy.ts` on Next.js 16+ (export `proxy`; Node.js runtime only). On Next.js 15 and earlier the file is `src/middleware.ts` (export `middleware`, Edge runtime by default). Also hosts the CSRF check and CSP nonce.

Per request:
1. Matcher excludes `_next/static`, `_next/image`, favicon, static files, and the Sentry tunnel path. `/api/auth/*` is NOT excluded from the matcher (it needs the CSRF check); inside the function it skips the guard and refresh logic.
2. Mutating `/api/*` request → CSRF origin check (section 8).
3. Access token missing or expiring within ~60s (decode JWT `exp`, no verification; the backend verifies)?
   - Refresh cookie present → call the backend refresh → set new cookies on the response AND on the forwarded request.
   - Refresh fails with 401/invalid → clear cookies; protected route → redirect `/login?from=`; public → continue.
   - Refresh fails from network/5xx → do NOT treat as logout; continue or show error state.
4. No token at all on a protected route → redirect to login. Logged in and visiting `/login` → redirect to dashboard.

**The critical gotcha:** cookies set only on the response are invisible to the current request's Server Components, so the page prefetch would still use the expired token. Forward them on the request too:

```ts
// after a successful refresh
request.cookies.set(ACCESS_COOKIE, tokens.access_token)
request.cookies.set(REFRESH_COOKIE, tokens.refresh_token)
const response = NextResponse.next({ request })   // forwards updated cookie header
response.cookies.set(ACCESS_COOKIE, tokens.access_token, accessOptions)
response.cookies.set(REFRESH_COOKIE, tokens.refresh_token, refreshOptions)
return response
```

Other rules:
- Keep it light regardless of runtime: `fetch` + a tiny JWT decode, no DB calls or heavy validation. On Next.js 16 it runs on Node.js (Node APIs such as `Buffer` are available); on Next.js 15 with `middleware.ts` it is Edge by default, so avoid Node-only libs there.
- Unauthenticated `/api/*` requests get a `401` JSON response, not a redirect to the login page.
- Refresh token rotation races (parallel requests, multiple tabs): backend should keep the old refresh token valid for a short grace window after rotation.
- Route guarding lives here (one auth checkpoint), plus the backend re-validates every token.

## 8. CSRF

`sameSite: 'lax'` blocks most CSRF but not same-site subdomains or GET side effects. Add:
1. Origin check in `proxy.ts` for POST/PUT/PATCH/DELETE on `/api/*` including `/api/auth/*`: Origin must match `env.APP_ORIGIN`; fall back to Referer; reject if both missing.
2. Require the custom `X-Requested-With` header on mutations.
3. Require `Content-Type: application/json` on JSON endpoints.
4. No CORS headers on `/api` ever.
5. GET handlers never mutate.
6. `__Host-` cookie prefix.
7. The backend accepts requests only from the BFF (private network or service secret).

Server Actions have built-in origin checks; keep `allowedOrigins` tight if used. Double-submit CSRF tokens are only needed if `/api` is ever called cross-origin.
