// Standard. Mock auth endpoints: any email + password "password" logs in. Tokens are fake JWTs with a real `exp`,
// so proxy.ts refresh logic runs exactly as it will against the real API (short TTL to see refresh happen).
import { http, HttpResponse } from 'msw'

const ACCESS_TTL = 120 // seconds: short on purpose, so you can watch silent refresh work

function fakeJwt(sub: string, ttlSeconds: number) {
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64url')
  return `${enc({ alg: 'none', typ: 'JWT' })}.${enc({ sub, exp: Math.floor(Date.now() / 1000) + ttlSeconds })}.mock`
}

function tokens(sub: string) {
  return {
    access_token: fakeJwt(sub, ACCESS_TTL),
    refresh_token: fakeJwt(sub, 60 * 60 * 24),
    expires_in: ACCESS_TTL,
    user: { id: sub, email: sub },
  }
}

export function createAuthHandlers(base: string) {
  return [
    http.post(`${base}/auth/login`, async ({ request }) => {
      const { email, password } = (await request.json()) as { email?: string; password?: string }
      if (password !== 'password') {
        return HttpResponse.json({ detail: 'Invalid email or password' }, { status: 401 })
      }
      return HttpResponse.json(tokens(email ?? 'user@example.com'))
    }),
    http.post(`${base}/auth/refresh`, () => HttpResponse.json(tokens('user@example.com'))),
    http.post(`${base}/auth/logout`, () => new HttpResponse(null, { status: 204 })),
  ]
}
