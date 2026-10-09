// Standard (Mode A). Next.js 16+: proxy.ts, export `proxy`, Node.js runtime only.
// Next.js 15 and earlier: rename to middleware.ts and export `middleware` (Edge by default: no Buffer, so swap the JWT decode for atob).
//
// Job: (1) route guard, (2) silent token refresh, (3) CSRF Origin check [Hardened, section marked below].
// Keep it thin: fetch + tiny JWT decode. No DB calls, no heavy validation. The backend verifies every token.
import { NextResponse, type NextRequest } from 'next/server'
import { env } from '@/env'
import {
  ACCESS_COOKIE,
  REFRESH_COOKIE,
  DEFAULT_REFRESH_TTL_SECONDS,
  baseCookieOptions,
  type TokenResponse,
} from '@/lib/auth-constants'

const PUBLIC_PATHS = ['/login']
const REFRESH_BUFFER_SECONDS = 60

const isPublic = (pathname: string) => PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(`${p}/`))

function decodeExp(token: string): number | null {
  try {
    const payload = token.split('.')[1]
    if (!payload) return null
    const json = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as { exp?: unknown }
    return typeof json.exp === 'number' ? json.exp : null
  } catch {
    return null
  }
}

// ---- HARDENED: CSRF (Origin check + custom header). Applies to mutating /api/* INCLUDING /api/auth/*.
function csrfOk(req: NextRequest): boolean {
  if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return true
  let origin = req.headers.get('origin')
  if (!origin) {
    const referer = req.headers.get('referer')
    try {
      origin = referer ? new URL(referer).origin : null
    } catch {
      origin = null
    }
  }
  if (!origin || origin !== env.APP_ORIGIN) return false // reject if both missing or mismatched
  return req.headers.get('x-requested-with') === 'XMLHttpRequest'
}

type RefreshResult =
  | { kind: 'ok'; tokens: TokenResponse }
  | { kind: 'invalid' } // backend says the refresh token is dead -> logout
  | { kind: 'error' } // network/5xx -> NOT a logout

async function refreshTokens(refreshToken: string): Promise<RefreshResult> {
  try {
    const res = await fetch(`${env.BACKEND_URL}/auth/refresh`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(env.BACKEND_SERVICE_SECRET ? { 'X-Service-Secret': env.BACKEND_SERVICE_SECRET } : {}),
      },
      body: JSON.stringify({ refresh_token: refreshToken }), // ADAPT to your backend
      cache: 'no-store',
      signal: AbortSignal.timeout(5_000),
    })
    if (res.ok) return { kind: 'ok', tokens: (await res.json()) as TokenResponse }
    if ([400, 401, 403].includes(res.status)) return { kind: 'invalid' }
    return { kind: 'error' }
  } catch {
    return { kind: 'error' }
  }
}

function clearCookies(res: NextResponse) {
  res.cookies.set(ACCESS_COOKIE, '', { ...baseCookieOptions, maxAge: 0 })
  res.cookies.set(REFRESH_COOKIE, '', { ...baseCookieOptions, maxAge: 0 })
}

function deny(req: NextRequest) {
  // API callers get JSON 401, pages get a redirect to login
  if (req.nextUrl.pathname.startsWith('/api/')) {
    return NextResponse.json({ message: 'Unauthorized' }, { status: 401 })
  }
  const url = new URL('/login', req.url)
  url.searchParams.set('from', req.nextUrl.pathname + req.nextUrl.search)
  return NextResponse.redirect(url)
}

export async function proxy(req: NextRequest) {
  const { pathname } = req.nextUrl

  // 1. CSRF (Hardened) on every mutating /api call, auth routes included
  if (pathname.startsWith('/api/') && !csrfOk(req)) {
    return NextResponse.json({ message: 'Forbidden' }, { status: 403 })
  }

  // /api/auth/* handle their own cookies: no guard, no refresh
  if (pathname.startsWith('/api/auth/')) return NextResponse.next()

  const access = req.cookies.get(ACCESS_COOKIE)?.value
  const refresh = req.cookies.get(REFRESH_COOKIE)?.value
  const exp = access ? decodeExp(access) : null
  const now = Math.floor(Date.now() / 1000)
  const needsRefresh = !access || exp === null || exp - now < REFRESH_BUFFER_SECONDS

  // 2. Silent refresh
  if (needsRefresh && refresh) {
    const result = await refreshTokens(refresh)

    if (result.kind === 'ok') {
      const t = result.tokens
      // THE GOTCHA: cookies set only on the response are invisible to this request's Server Components.
      // Set them on the forwarded request too, or the page prefetch still uses the expired token.
      req.cookies.set(ACCESS_COOKIE, t.access_token)
      req.cookies.set(REFRESH_COOKIE, t.refresh_token)
      const res = NextResponse.next({ request: req })
      res.cookies.set(ACCESS_COOKIE, t.access_token, { ...baseCookieOptions, maxAge: t.expires_in })
      res.cookies.set(REFRESH_COOKIE, t.refresh_token, {
        ...baseCookieOptions,
        maxAge: t.refresh_expires_in ?? DEFAULT_REFRESH_TTL_SECONDS,
      })
      return res
    }

    if (result.kind === 'invalid') {
      const res = isPublic(pathname) ? NextResponse.next() : deny(req)
      clearCookies(res)
      return res
    }
    // kind === 'error': backend hiccup, do not log the user out
    return NextResponse.next()
  }

  // 3. Guard
  if (!access && !refresh && !isPublic(pathname)) return deny(req)
  if (access && pathname === '/login') return NextResponse.redirect(new URL('/', req.url))

  return NextResponse.next()
}

export const config = {
  // Exclude static assets only. /api/auth/* stays in the matcher so the CSRF check covers it.
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)'],
}
