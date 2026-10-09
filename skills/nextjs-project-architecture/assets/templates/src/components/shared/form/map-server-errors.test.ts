import { describe, expect, it, vi } from 'vitest'
import type { UseFormReturn } from 'react-hook-form'
import { toApiError } from '@/lib/errors'
import { mapServerErrors, ROOT_ERROR } from './map-server-errors'

type Values = { customerName: string; amount: string }

// Only the two members mapServerErrors uses
function fakeForm() {
  const setError = vi.fn()
  const form = { setError, formState: { defaultValues: { customerName: '', amount: '' } } }
  return { form: form as unknown as UseFormReturn<Values, unknown, Values>, setError }
}

describe('mapServerErrors', () => {
  it('puts 422 errors on fields (with fieldMap) and focuses the first', () => {
    const { form, setError } = fakeForm()
    const error = toApiError(422, { detail: [{ loc: ['body', 'customer_name'], msg: 'Blocked' }, { loc: ['body', 'amount'], msg: 'Too low' }] })

    mapServerErrors(form, error, { fieldMap: { customer_name: 'customerName' } })

    expect(setError).toHaveBeenNthCalledWith(1, 'customerName', { type: 'server', message: 'Blocked' }, { shouldFocus: true })
    expect(setError).toHaveBeenNthCalledWith(2, 'amount', { type: 'server', message: 'Too low' }, { shouldFocus: false })
    expect(setError).toHaveBeenCalledTimes(2) // nothing left over for the root
  })

  it('sends errors for unknown fields to the root instead of dropping them', () => {
    const { form, setError } = fakeForm()
    mapServerErrors(form, toApiError(422, { detail: [{ loc: ['body', 'customer_name'], msg: 'Blocked' }] })) // no fieldMap
    expect(setError).toHaveBeenCalledWith(ROOT_ERROR, { type: 'server', message: 'Blocked' })
  })

  it('maps business error codes to a field', () => {
    const { form, setError } = fakeForm()
    mapServerErrors(form, toApiError(409, { code: 'DUPLICATE', message: 'Already exists' }), { codeToField: { DUPLICATE: 'customerName' } })
    expect(setError).toHaveBeenCalledWith('customerName', { type: 'server', message: 'Already exists' }, { shouldFocus: true })
  })

  it('shows a generic message for 5xx, network, and unknown errors', () => {
    for (const error of [toApiError(500, { detail: 'stack trace...' }), toApiError(0, null), new Error('boom')]) {
      const { form, setError } = fakeForm()
      mapServerErrors(form, error)
      expect(setError).toHaveBeenCalledWith(ROOT_ERROR, { type: 'server', message: 'Something went wrong. Please try again.' })
    }
  })
})
