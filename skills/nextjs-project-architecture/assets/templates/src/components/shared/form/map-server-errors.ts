// Starter. Maps a normalized ApiError onto the form: field errors -> fields, the rest -> root error.
import type { FieldPath, FieldValues, UseFormReturn } from 'react-hook-form'
import { isApiError } from '@/lib/errors'

export const ROOT_ERROR = 'root.serverError' as const

export type ServerErrorOptions<T extends FieldValues> = {
  /** API field path -> form field path, when names differ, e.g. { customer_name: 'customerName' } */
  fieldMap?: Record<string, FieldPath<T>>
  /** Business error codes -> field, e.g. { DUPLICATE_SKU: 'items.0.sku' } */
  codeToField?: Record<string, FieldPath<T>>
  /** Message for 5xx/unknown errors */
  fallbackMessage?: string
}

export function mapServerErrors<T extends FieldValues, TOut>(
  form: UseFormReturn<T, unknown, TOut>,
  error: unknown,
  { fieldMap = {}, codeToField = {}, fallbackMessage = 'Something went wrong. Please try again.' }: ServerErrorOptions<T> = {},
) {
  if (!isApiError(error) || error.status === 0 || error.status >= 500) {
    form.setError(ROOT_ERROR, { type: 'server', message: fallbackMessage })
    return
  }

  const known = new Set(Object.keys(form.formState.defaultValues ?? {}))
  const unmatched: string[] = []
  let focused = false

  // 422-style field errors
  for (const [apiPath, message] of Object.entries(error.fieldErrors ?? {})) {
    const path: string = fieldMap[apiPath] ?? apiPath
    const top = path.split('.')[0] ?? ''
    if (known.has(top)) {
      form.setError(path as FieldPath<T>, { type: 'server', message }, { shouldFocus: !focused })
      focused = true
    } else {
      unmatched.push(message)
    }
  }

  // Business error codes (409 etc.)
  const body = error.body as { code?: unknown } | undefined
  const code = typeof body?.code === 'string' ? body.code : undefined
  const codeField = code ? codeToField[code] : undefined
  if (codeField) {
    form.setError(codeField, { type: 'server', message: error.message }, { shouldFocus: !focused })
    focused = true
  }

  // Anything not attached to a field is shown at the top of the form. Never silently dropped.
  if (!focused || unmatched.length) {
    form.setError(ROOT_ERROR, { type: 'server', message: unmatched[0] ?? error.message })
  }
}
