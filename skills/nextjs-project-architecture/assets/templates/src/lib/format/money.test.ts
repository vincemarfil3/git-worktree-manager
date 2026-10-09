import { describe, expect, it } from 'vitest'
import { formatMoney, parseMoney } from './money'

describe('formatMoney', () => {
  it('formats decimal strings with the currency rules', () => {
    expect(formatMoney('1234.5', 'PHP')).toBe('₱1,234.50')
    expect(formatMoney('1234.5', 'PHP', 'code')).toMatch(/PHP\s?1,234\.50/)
  })

  it('does not lose precision on large amounts (string input, no float math)', () => {
    expect(formatMoney('12345678901234.56', 'USD', 'code')).toMatch(/12,345,678,901,234\.56/)
  })

  it('lets Intl decide decimals per currency', () => {
    expect(formatMoney('1500', 'JPY', 'code')).toMatch(/JPY\s?1,500$/)
  })
})

describe('parseMoney', () => {
  it('normalizes user input or returns null', () => {
    expect(parseMoney('1,000.25')).toBe('1000.25')
    expect(parseMoney('1.234')).toBeNull()
    expect(parseMoney('abc')).toBeNull()
  })
})
