// Standard (Mode A). Catch-all proxy: browser -> /api/* -> backend with Bearer token attached server-side.
// Never forwards browser cookies to the backend. Dedicated route handlers are only for special cases (auth, aggregation).
import { NextResponse, type NextRequest } from 'next/server'
import { env } from '@/env'
import { getAccessToken } from '@/lib/auth'

async function handler(req: NextRequest, ctx: { params: Promise<{ path: string[] }> }) {
  const { path } = await ctx.params
  const token = await getAccessToken()

  const url = new URL(`${env.BACKEND_URL}/${path.join('/')}`)
  url.search = req.nextUrl.search

  const headers = new Headers({ Accept: 'application/json' })
  const contentType = req.headers.get('content-type')
  if (contentType) headers.set('Content-Type', contentType)
  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (env.BACKEND_SERVICE_SECRET) headers.set('X-Service-Secret', env.BACKEND_SERVICE_SECRET)

  const hasBody = req.method !== 'GET' && req.method !== 'HEAD'
  const upstream = await fetch(url, {
    method: req.method,
    headers,
    body: hasBody ? await req.text() : undefined,
    cache: 'no-store',
    signal: AbortSignal.timeout(15_000),
  })

  const body = upstream.status === 204 ? null : await upstream.text()
  return new NextResponse(body, {
    status: upstream.status,
    headers: {
      'Content-Type': upstream.headers.get('content-type') ?? 'application/json',
      'Cache-Control': 'no-store',
    },
  })
}

export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE }
