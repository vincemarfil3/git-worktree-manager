// Starter (Mode A). Forward credentials to the backend, set httpOnly cookies, return { user } only (never tokens).
// ADAPT: backend login path and response shape.
import { NextResponse, type NextRequest } from 'next/server'
import { env } from '@/env'
import { setAuthCookies } from '@/lib/auth'
import type { TokenResponse } from '@/lib/auth-constants'

export async function POST(req: NextRequest) {
  const res = await fetch(`${env.BACKEND_URL}/auth/login`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(env.BACKEND_SERVICE_SECRET ? { 'X-Service-Secret': env.BACKEND_SERVICE_SECRET } : {}),
    },
    body: await req.text(),
    cache: 'no-store',
    signal: AbortSignal.timeout(10_000),
  })
  const data = (await res.json().catch(() => null)) as (TokenResponse & { user?: unknown }) | null

  if (!res.ok || !data) {
    // pass the backend's status/body through so the form can show field or root errors
    return NextResponse.json(data ?? { message: 'Login failed' }, { status: res.ok ? 502 : res.status })
  }
  await setAuthCookies(data)
  return NextResponse.json({ user: data.user ?? null }, { headers: { 'Cache-Control': 'no-store' } })
}
