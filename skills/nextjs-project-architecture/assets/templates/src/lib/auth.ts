// Starter (Mode A). Server-only cookie helpers. cookies() is async in Next.js 15+.
import 'server-only'
import { cookies } from 'next/headers'
import {
  ACCESS_COOKIE,
  REFRESH_COOKIE,
  DEFAULT_REFRESH_TTL_SECONDS,
  baseCookieOptions,
  type TokenResponse,
} from '@/lib/auth-constants'

export async function setAuthCookies(t: TokenResponse) {
  const jar = await cookies()
  jar.set(ACCESS_COOKIE, t.access_token, { ...baseCookieOptions, maxAge: t.expires_in })
  jar.set(REFRESH_COOKIE, t.refresh_token, {
    ...baseCookieOptions,
    maxAge: t.refresh_expires_in ?? DEFAULT_REFRESH_TTL_SECONDS,
  })
}

export async function clearAuthCookies() {
  const jar = await cookies()
  jar.set(ACCESS_COOKIE, '', { ...baseCookieOptions, maxAge: 0 })
  jar.set(REFRESH_COOKIE, '', { ...baseCookieOptions, maxAge: 0 })
}

export async function getAccessToken() {
  return (await cookies()).get(ACCESS_COOKIE)?.value
}

export async function getRefreshToken() {
  return (await cookies()).get(REFRESH_COOKIE)?.value
}
