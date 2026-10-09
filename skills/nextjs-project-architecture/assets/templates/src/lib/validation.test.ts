import { describe, expect, it } from 'vitest'
import { intFromText, moneyString, optionalText, requiredText } from './validation'

describe('moneyString', () => {
  const money = moneyString()

  it.each([
    ['1,234.50', '1234.50'],
    ['12', '12'],
    [' 0.5 ', '0.5'],
  ])('accepts %j as %j (a string, never a float)', (input, expected) => {
    expect(money.parse(input)).toBe(expected)
  })

  it.each(['12.345', 'abc', '-5', '1.2.3', ''])('rejects %j', (input) => {
    expect(money.safeParse(input).success).toBe(false)
  })

  it('enforces the minimum and whole amounts for 0-decimal currencies', () => {
    expect(moneyString({ min: 1 }).safeParse('0.50').success).toBe(false)
    expect(moneyString({ maxDecimals: 0 }).parse('1500')).toBe('1500')
    expect(moneyString({ maxDecimals: 0 }).safeParse('15.5').success).toBe(false)
  })
})

describe('text helpers', () => {
  it('optionalText turns blank input into undefined', () => {
    expect(optionalText().parse('   ')).toBeUndefined()
    expect(optionalText().parse(' hi ')).toBe('hi')
  })

  it('requiredText trims and uses the custom message', () => {
    const r = requiredText('Enter a name').safeParse('   ')
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.message).toBe('Enter a name')
  })

  it('intFromText parses whole numbers within bounds', () => {
    expect(intFromText().parse('42')).toBe(42)
    expect(intFromText({ max: 10 }).safeParse('11').success).toBe(false)
    expect(intFromText().safeParse('4.2').success).toBe(false)
  })
})
