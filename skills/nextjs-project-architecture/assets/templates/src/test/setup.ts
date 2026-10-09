import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterAll, afterEach, beforeAll } from 'vitest'
import { server } from './msw-server'

// 'error': a request with no handler fails the test, so a typo'd URL never passes silently
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  cleanup()
  server.resetHandlers() // drop per-test server.use() overrides
})
afterAll(() => server.close())

// jsdom gaps that Radix UI (shadcn Select, DropdownMenu, AlertDialog) needs
if (typeof window !== 'undefined') {
  window.HTMLElement.prototype.scrollIntoView ??= function scrollIntoView() {}
  window.HTMLElement.prototype.hasPointerCapture ??= () => false
  window.HTMLElement.prototype.releasePointerCapture ??= () => {}
  window.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  window.matchMedia ??= (query: string) =>
    ({ matches: false, media: query, onchange: null, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, dispatchEvent: () => false }) as MediaQueryList
}
