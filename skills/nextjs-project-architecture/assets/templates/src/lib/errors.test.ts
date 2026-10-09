import { describe, expect, it } from 'vitest'
import { ApiError, extractFieldErrors, isClientError, toApiError } from './errors'

describe('extractFieldErrors', () => {
  it('maps FastAPI 422 loc paths to dotted form paths, dropping "body"', () => {
    const body = {
      detail: [
        { loc: ['body', 'customer_name'], msg: 'Required' },
        { loc: ['body', 'items', 0, 'qty'], msg: 'Too many' },
      ],
    }
    expect(extractFieldErrors(body)).toEqual({ customer_name: 'Required', 'items.0.qty': 'Too many' })
  })

  it('maps the { errors: [{ path, message }] } shape', () => {
    expect(extractFieldErrors({ errors: [{ path: 'email', message: 'Taken' }] })).toEqual({ email: 'Taken' })
  })

  it('keeps the first message per field', () => {
    const body = { detail: [{ loc: ['body', 'x'], msg: 'first' }, { loc: ['body', 'x'], msg: 'second' }] }
    expect(extractFieldErrors(body)).toEqual({ x: 'first' })
  })

  it('returns undefined when there are no field errors', () => {
    expect(extractFieldErrors({ detail: 'Not found' })).toBeUndefined()
    expect(extractFieldErrors(null)).toBeUndefined()
  })
})

describe('toApiError', () => {
  it('uses message, then string detail, then the fallback', () => {
    expect(toApiError(409, { message: 'Duplicate' }).message).toBe('Duplicate')
    expect(toApiError(404, { detail: 'Order not found' }).message).toBe('Order not found')
    expect(toApiError(500, null, 'Network down').message).toBe('Network down')
  })

  it('keeps status, body, and field errors', () => {
    const e = toApiError(422, { detail: [{ loc: ['body', 'amount'], msg: 'Invalid' }] })
    expect(e).toBeInstanceOf(ApiError)
    expect(e.status).toBe(422)
    expect(e.fieldErrors).toEqual({ amount: 'Invalid' })
  })
})

describe('isClientError', () => {
  it('is true only for 4xx ApiErrors (used to skip retries)', () => {
    expect(isClientError(toApiError(404, null))).toBe(true)
    expect(isClientError(toApiError(503, null))).toBe(false)
    expect(isClientError(new Error('x'))).toBe(false)
  })
})
