import { describe, expect, it } from 'vitest'
import { safeRedirect } from './redirect'

describe('safeRedirect', () => {
  it('keeps same-site paths', () => {
    expect(safeRedirect('/orders?page=2')).toBe('/orders?page=2')
  })

  it.each(['https://evil.com', '//evil.com', 'javascript:alert(1)', undefined, ['/a', '/b']])('falls back to / for %j', (from) => {
    expect(safeRedirect(from)).toBe('/')
  })
})
