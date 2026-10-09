// Starter (Mode A). Cookie names/options. Import-safe from proxy.ts (no next/headers here).
// NODE_ENV is the one allowed process.env read outside env.ts.
const isProd = process.env.NODE_ENV === 'production'

// __Host- prefix (Hardened): needs HTTPS + Secure + Path=/ + no Domain, so plain names in local dev.
export const ACCESS_COOKIE = isProd ? '__Host-access_token' : 'access_token'
export const REFRESH_COOKIE = isProd ? '__Host-refresh_token' : 'refresh_token'

export const baseCookieOptions = {
  httpOnly: true,
  secure: isProd,
  sameSite: 'lax' as const, // not 'strict': strict breaks refresh when arriving from an external link
  path: '/',
}

export type TokenResponse = {
  access_token: string
  refresh_token: string
  expires_in: number // seconds; ADAPT to your backend's token shape
  refresh_expires_in?: number
}

export const DEFAULT_REFRESH_TTL_SECONDS = 60 * 60 * 24 * 30
