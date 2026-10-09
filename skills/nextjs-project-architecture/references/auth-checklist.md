# Auth edge-case checklist (Hardened profile; use a trimmed version for Standard)

Scenario → expected behavior. Automate most as proxy/handler tests or Playwright; the rest are pre-launch manual checks.

## Token expiry and refresh
- [ ] Access expired, refresh valid → silent refresh; page renders; prefetch gets no 401 (same-request cookie forwarding works).
- [ ] Access within expiry buffer → refreshed before any request fails.
- [ ] Both expired, protected route → `/login?from=…`; returns to original page after login.
- [ ] Both expired, public route → cookies cleared, page renders.
- [ ] Refresh token revoked on backend → cookies cleared, redirect to login.
- [ ] Expiry during client refetch → `proxy.ts` refreshes on `/api` request; invisible to user.
- [ ] Expiry while a form is open → submit still succeeds; input not lost.

## Parallel requests and tabs
- [ ] Simultaneous refreshes → nobody logged out (backend grace window).
- [ ] Two tabs expire → both keep working.
- [ ] Logout in one tab → other tab's next request 401s, redirects, clears query cache.
- [ ] Different user logs in another tab → old tab shows no previous-user data after next request.

## Redirects
- [ ] `from` accepts internal paths only (`?from=https://evil.com` → dashboard).
- [ ] Visiting `/login` while logged in → dashboard.
- [ ] No loops between `proxy.ts`, `/login`, `/api/auth/*`.
- [ ] Failed login shows its error, doesn't trigger the 401 redirect.

## Logout
- [ ] Backend revoke fails → still logged out, cookies cleared.
- [ ] Back button after logout shows no cached authenticated pages (`no-store`).
- [ ] Query cache cleared on shared devices.

## Cookies and CSRF
- [ ] Cookies: httpOnly, Secure, SameSite=Lax, `__Host-` prefix in production.
- [ ] Tokens never in JS, localStorage, URLs, API responses, or Sentry events.
- [ ] Mutation with wrong/missing Origin rejected; same-origin accepted.
- [ ] Cross-site login form rejected (login CSRF).

## Network and failures
- [ ] Backend down during refresh → error state, NOT logout.
- [ ] Slow refresh → requests wait; no duplicate refresh per request.
- [ ] Clock skew → buffer tolerates small differences.
- [ ] Offline then online → queries recover; session intact if tokens valid.

## Backend protection
- [ ] Backend rejects requests lacking the service secret / outside the private network.
- [ ] Backend validates every token itself.

## Data isolation
- [ ] No shared server-side QueryClient or fetch cache across users.
- [ ] Two users loading the same page concurrently see only their own data.
