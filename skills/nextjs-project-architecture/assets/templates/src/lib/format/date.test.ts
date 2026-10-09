import { describe, expect, it } from 'vitest'
import { formatDate, formatDateOnly, formatDateTime } from './date'

describe('date formatting (explicit Asia/Manila time zone)', () => {
  it('converts UTC instants to the display time zone', () => {
    // 2026-09-30T20:00Z is already Oct 1 in Manila (UTC+8)
    expect(formatDate('2026-09-30T20:00:00Z')).toBe('Oct 1, 2026')
    expect(formatDateTime('2026-09-30T04:15:00Z')).toMatch(/Sep 30, 2026.*12:15/)
  })

  it('never shifts date-only values', () => {
    expect(formatDateOnly('2026-09-30')).toBe('Sep 30, 2026')
  })
})
