// Standard. Money formatting. Amounts are decimal STRINGS from the API ("1234.50"), never floats.
// Intl decides decimals per currency (PHP 2, JPY 0). Never hardcode /100.
const LOCALE = 'en-PH' // ADAPT: app or merchant locale
const cache = new Map<string, Intl.NumberFormat>()

function formatter(currency: string, display: 'symbol' | 'code') {
  const key = `${currency}:${display}`
  let f = cache.get(key)
  if (!f) {
    f = new Intl.NumberFormat(LOCALE, { style: 'currency', currency, currencyDisplay: display })
    cache.set(key, f)
  }
  return f
}

/** formatMoney("1234.5", "PHP") -> "₱1,234.50". Use display "code" where several currencies appear. */
export function formatMoney(amount: string, currency: string, display: 'symbol' | 'code' = 'symbol') {
  // Passing the string keeps full precision in modern engines (Intl "StringNumericLiteral")
  return formatter(currency, display).format(amount as Intl.StringNumericLiteral)
}

/** parseMoney("1,234.50") -> "1234.50" or null. For display/inputs only; the backend does the math. */
export function parseMoney(input: string, maxDecimals = 2): string | null {
  const v = input.trim().replace(/,/g, '')
  const re = maxDecimals === 0 ? /^\d+$/ : new RegExp(`^\\d+(\\.\\d{1,${maxDecimals}})?$`)
  return re.test(v) ? v : null
}
