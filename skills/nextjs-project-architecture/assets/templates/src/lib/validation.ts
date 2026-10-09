// Standard. Reusable Zod helpers for form schemas (Zod v4).
import { z } from 'zod'

/** Optional text input: '' becomes undefined so the API receives no empty strings. */
export const optionalText = () =>
  z
    .string()
    .trim()
    .transform((v) => (v === '' ? undefined : v))

/** Required text input with a friendly message. */
export const requiredText = (message = 'Required') => z.string().trim().min(1, message)

/**
 * Money typed by the user, kept as a STRING (never a float).
 * Accepts "1,234.50", strips grouping, checks max decimals for the currency (PHP/USD 2, JPY 0).
 * Output is a plain decimal string like "1234.50".
 */
export const moneyString = ({ maxDecimals = 2, min = 0 }: { maxDecimals?: number; min?: number } = {}) => {
  // Built once per schema. {1,0} is an invalid quantifier, so 0-decimal currencies get their own pattern.
  const pattern = maxDecimals === 0 ? /^\d+$/ : new RegExp(`^\\d+(\\.\\d{1,${maxDecimals}})?$`)
  return z
    .string()
    .trim()
    .min(1, 'Required')
    .transform((v) => v.replace(/,/g, ''))
    .refine((v) => pattern.test(v), {
      message: maxDecimals === 0 ? 'Enter a whole amount' : `Enter an amount with up to ${maxDecimals} decimals`,
    })
    .refine((v) => Number(v) >= min, { message: `Must be at least ${min}` })
}

/** Whole number typed into a text input (inputMode="numeric"), output as number. */
export const intFromText = ({ min, max }: { min?: number; max?: number } = {}) =>
  z
    .string()
    .trim()
    .regex(/^-?\d+$/, 'Enter a whole number')
    .transform(Number)
    .pipe(
      z
        .number()
        .min(min ?? Number.MIN_SAFE_INTEGER, `Must be at least ${min}`)
        .max(max ?? Number.MAX_SAFE_INTEGER, `Must be at most ${max}`),
    )
