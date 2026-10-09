// Starter (Mode A). Best-effort backend revoke, ALWAYS clear cookies.
import { NextResponse } from 'next/server'
import { env } from '@/env'
import { clearAuthCookies, getRefreshToken } from '@/lib/auth'

export async function POST() {
  const refreshToken = await getRefreshToken()
  if (refreshToken) {
    try {
      await fetch(`${env.BACKEND_URL}/auth/logout`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: refreshToken }),
        signal: AbortSignal.timeout(5_000),
      })
    } catch {
      // swallow: user is logged out locally regardless
    }
  }
  await clearAuthCookies()
  return NextResponse.json({ ok: true }, { headers: { 'Cache-Control': 'no-store' } })
}
