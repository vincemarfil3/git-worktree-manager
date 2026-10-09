// Starter. One normalized error shape for server-api and api-client.
export type FieldErrors = Record<string, string>

export class ApiError extends Error {
  // plain fields (no constructor parameter properties) so this works with `erasableSyntaxOnly` / Node type stripping
  readonly status: number
  readonly body: unknown
  readonly fieldErrors: FieldErrors | undefined

  constructor(status: number, message: string, body?: unknown, fieldErrors?: FieldErrors) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.body = body
    this.fieldErrors = fieldErrors
  }
}

export const isApiError = (e: unknown): e is ApiError => e instanceof ApiError
export const isClientError = (e: unknown) => isApiError(e) && e.status >= 400 && e.status < 500

/**
 * ADAPT PER BACKEND. Default handles FastAPI-style 422:
 * { detail: [{ loc: ["body","items",0,"qty"], msg: "..." }] }  ->  { "items.0.qty": "..." }
 * Also accepts { errors: [{ path: "email", message: "..." }] } (common Node shape).
 */
export function extractFieldErrors(body: unknown): FieldErrors | undefined {
  if (!body || typeof body !== 'object') return undefined
  const b = body as Record<string, unknown>
  const out: FieldErrors = {}

  if (Array.isArray(b.detail)) {
    for (const item of b.detail as Array<{ loc?: unknown[]; msg?: string }>) {
      const loc = Array.isArray(item.loc) ? item.loc : []
      const path = loc.filter((p, i) => !(i === 0 && p === 'body')).join('.')
      if (path && item.msg && !(path in out)) out[path] = item.msg
    }
  }
  if (Array.isArray(b.errors)) {
    for (const item of b.errors as Array<{ path?: string; message?: string }>) {
      if (item.path && item.message && !(item.path in out)) out[item.path] = item.message
    }
  }
  return Object.keys(out).length ? out : undefined
}

export function messageFromBody(body: unknown, fallback: string): string {
  if (body && typeof body === 'object') {
    const b = body as Record<string, unknown>
    if (typeof b.message === 'string') return b.message
    if (typeof b.detail === 'string') return b.detail
  }
  return fallback
}

export function toApiError(status: number, body: unknown, fallback = 'Request failed'): ApiError {
  return new ApiError(status, messageFromBody(body, fallback), body, extractFieldErrors(body))
}
