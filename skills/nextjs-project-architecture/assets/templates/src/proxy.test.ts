// @vitest-environment node
// proxy.ts is a plain async function: build a NextRequest, call it, inspect the NextResponse.
// The backend refresh endpoint is faked by MSW (src/mocks/auth.ts, overridden per test).
import { http, HttpResponse } from 'msw'
import { NextRequest } from 'next/server'
import { describe, expect, it } from 'vitest'
import { ACCESS_COOKIE, REFRESH_COOKIE } from '@/lib/auth-constants'
import { server, TEST_BACKEND, TEST_ORIGIN } from '@/test/msw-server'
import { proxy } from './proxy'

function jwt(expInSeconds: number) {
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url')
  return `${enc({ alg: 'none' })}.${enc({ exp: Math.floor(Date.now() / 1000) + expInSeconds })}.sig`
}

function request(path: string, { cookies = {}, method = 'GET', headers = {} }: { cookies?: Record<string, string>; method?: string; headers?: Record<string, string> } = {}) {
  const cookie = Object.entries(cookies).map(([k, v]) => `${k}=${v}`).join('; ')
  return new NextRequest(`${TEST_ORIGIN}${path}`, { method, headers: { ...(cookie && { cookie }), ...headers } })
}

const sameOrigin = { origin: TEST_ORIGIN, 'x-requested-with': 'XMLHttpRequest' }
const isPassThrough = (res: Response) => res.headers.get('x-middleware-next') === '1'

describe('proxy: route guard', () => {
  it('redirects signed-out page requests to /login with a return path', async () => {
    const res = await proxy(request('/orders?page=2'))
    expect(res.status).toBe(307)
    expect(res.headers.get('location')).toBe(`${TEST_ORIGIN}/login?from=%2Forders%3Fpage%3D2`)
  })

  it('answers signed-out /api requests with 401 JSON, not a redirect', async () => {
    const res = await proxy(request('/api/orders'))
    expect(res.status).toBe(401)
    await expect(res.json()).resolves.toEqual({ message: 'Unauthorized' })
  })

  it('lets a valid session through and sends signed-in users away from /login', async () => {
    const cookies = { [ACCESS_COOKIE]: jwt(600), [REFRESH_COOKIE]: jwt(86_400) }
    expect(isPassThrough(await proxy(request('/orders', { cookies })))).toBe(true)
    expect((await proxy(request('/login', { cookies }))).headers.get('location')).toBe(`${TEST_ORIGIN}/`)
  })
})

describe('proxy: CSRF', () => {
  it('rejects mutations without a matching Origin or the custom header, including auth routes', async () => {
    const attempts: Record<string, string>[] = [
      {}, // no Origin, no header
      { origin: 'https://evil.example', 'x-requested-with': 'XMLHttpRequest' }, // wrong Origin
      { origin: TEST_ORIGIN }, // right Origin, missing custom header
    ]
    for (const headers of attempts) {
      const res = await proxy(request('/api/auth/login', { method: 'POST', headers }))
      expect(res.status).toBe(403)
    }
  })

  it('allows same-origin mutations and all GETs', async () => {
    expect(isPassThrough(await proxy(request('/api/auth/login', { method: 'POST', headers: sameOrigin })))).toBe(true)
    expect((await proxy(request('/api/orders', { cookies: { [ACCESS_COOKIE]: jwt(600) } }))).status).not.toBe(403)
  })
})

describe('proxy: silent refresh', () => {
  it('refreshes an expired token and forwards the new cookie to THIS request (Server Components see it)', async () => {
    let sentRefreshToken: unknown
    server.use(
      http.post(`${TEST_BACKEND}/auth/refresh`, async ({ request }) => {
        sentRefreshToken = ((await request.json()) as { refresh_token: string }).refresh_token
        return HttpResponse.json({ access_token: 'new-access', refresh_token: 'new-refresh', expires_in: 900 })
      }),
    )

    const res = await proxy(request('/orders', { cookies: { [ACCESS_COOKIE]: jwt(-60), [REFRESH_COOKIE]: 'old-refresh' } }))

    expect(sentRefreshToken).toBe('old-refresh')
    expect(isPassThrough(res)).toBe(true)
    // 1. browser gets the new cookies
    expect(res.headers.getSetCookie().join('\n')).toMatch(new RegExp(`${ACCESS_COOKIE}=new-access.*HttpOnly`, 'is'))
    // 2. the forwarded request carries them too (the gotcha: otherwise the page prefetch uses the dead token)
    expect(res.headers.get('x-middleware-request-cookie')).toContain(`${ACCESS_COOKIE}=new-access`)
  })

  it('refreshes when only the refresh cookie is left (access cookie expired out of the browser)', async () => {
    server.use(http.post(`${TEST_BACKEND}/auth/refresh`, () => HttpResponse.json({ access_token: 'a2', refresh_token: 'r2', expires_in: 900 })))
    const res = await proxy(request('/api/orders', { cookies: { [REFRESH_COOKIE]: 'r1' } }))
    expect(isPassThrough(res)).toBe(true)
    expect(res.headers.get('x-middleware-request-cookie')).toContain(`${ACCESS_COOKIE}=a2`)
  })

  it('logs out when the backend rejects the refresh token', async () => {
    server.use(http.post(`${TEST_BACKEND}/auth/refresh`, () => HttpResponse.json({ detail: 'revoked' }, { status: 401 })))
    const res = await proxy(request('/orders', { cookies: { [REFRESH_COOKIE]: 'revoked' } }))

    expect(res.status).toBe(307)
    expect(res.headers.get('location')).toContain('/login')
    expect(res.headers.getSetCookie().filter((c) => /Max-Age=0/i.test(c))).toHaveLength(2)
  })

  it('does NOT log out when the backend is down (5xx or network error)', async () => {
    server.use(http.post(`${TEST_BACKEND}/auth/refresh`, () => HttpResponse.json({ detail: 'oops' }, { status: 503 })))
    const res = await proxy(request('/orders', { cookies: { [ACCESS_COOKIE]: jwt(-60), [REFRESH_COOKIE]: 'r' } }))

    expect(isPassThrough(res)).toBe(true)
    expect(res.headers.getSetCookie()).toHaveLength(0)
  })
})
