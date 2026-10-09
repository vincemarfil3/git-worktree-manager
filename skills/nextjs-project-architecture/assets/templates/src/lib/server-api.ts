// Starter (Mode A). Server-only fetch wrapper: Server Components + route handlers call the backend directly.
// NEVER refreshes tokens (Server Components cannot set cookies). 401 -> throws; pages redirect to login.
import 'server-only'
import { env } from '@/env'
import { getAccessToken } from '@/lib/auth'
import { toApiError } from '@/lib/errors'

type Query = Record<string, string | number | boolean | undefined>
type Options = { body?: unknown; query?: Query; signal?: AbortSignal }

function buildUrl(path: string, query?: Query) {
  const qs = new URLSearchParams()
  for (const [k, v] of Object.entries(query ?? {})) if (v !== undefined) qs.set(k, String(v))
  const q = qs.toString()
  return `${env.BACKEND_URL}${path}${q ? `?${q}` : ''}`
}

async function request<T>(method: string, path: string, opts: Options = {}): Promise<T> {
  const token = await getAccessToken()
  const headers = new Headers({ Accept: 'application/json' })
  if (opts.body !== undefined) headers.set('Content-Type', 'application/json')
  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (env.BACKEND_SERVICE_SECRET) headers.set('X-Service-Secret', env.BACKEND_SERVICE_SECRET)

  const res = await fetch(buildUrl(path, opts.query), {
    method,
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    cache: 'no-store', // authenticated: never cache across users
    signal: opts.signal ?? AbortSignal.timeout(10_000),
  })

  if (!res.ok) {
    const body = await res.json().catch(() => undefined)
    throw toApiError(res.status, body)
  }
  if (res.status === 204) return undefined as T
  return (await res.json()) as T
}

export const serverApi = {
  get: <T>(path: string, opts?: Omit<Options, 'body'>) => request<T>('GET', path, opts),
  post: <T>(path: string, body?: unknown, opts?: Options) => request<T>('POST', path, { ...opts, body }),
  put: <T>(path: string, body?: unknown, opts?: Options) => request<T>('PUT', path, { ...opts, body }),
  patch: <T>(path: string, body?: unknown, opts?: Options) => request<T>('PATCH', path, { ...opts, body }),
  delete: <T>(path: string, opts?: Options) => request<T>('DELETE', path, opts),
}
